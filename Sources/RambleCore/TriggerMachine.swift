import Foundation

/// What the machine decided to do, surfaced for logging and for the menu bar's
/// "last event" line.
public enum TriggerOutcome: Equatable {
    case fired(phase: Phase, rule: String, action: String)
    case nothingConfigured(phase: Phase, rule: String)
    case ignored(reason: String)
    case failed(phase: Phase, reason: String)

    public enum Phase: String, Equatable { case start, stop }
}

/// Turns the device's frame stream into hotkey fires.
///
/// The rules this encodes, all of them earned from measurements in FINDINGS.md:
///
/// - **Stop fires on `03 [36]`, never on `02 [44 02]`.** An earlier version did
///   the opposite, on the evidence of four takes that were all shorter than 15
///   seconds. `02 [44 02]` is emitted by a **15-second timer** as well as at the
///   real button press — measured at 15.00, 15.02, 15.03, 15.00 and 15.00 s
///   across five takes, which no human produces — so triggering on it truncates
///   every dictation at 15 s. It is also not reliably emitted at the real stop
///   at all: one 48.7 s take produced only the 15 s one. `03 [36]` costs about
///   1.1 s of flush delay and is unambiguous. Trailing silence is cheap;
///   losing everything after 15 seconds is not.
/// - **The rule is latched at start.** Whichever app was frontmost when you
///   pressed the button owns the whole take, so switching apps mid-dictation
///   can't send the stop keystroke somewhere else and leave the first app
///   recording forever.
/// - **A stop with no start is ignored.** Connecting while the mic is already
///   recording is the normal case, not an error — the LED goes red as soon as
///   the device enters an app-connected mode — and a bare `0x36` must not fire
///   a keystroke for a dictation that was never started.
public final class TriggerMachine {
    private enum State: Equatable {
        case idle
        /// `held` is the chord currently pressed down in hold mode, remembered
        /// so it can be released however the take ends — including when the
        /// rule's `onStop` is missing or names a different key.
        ///
        /// `mode` is resolved once, at the start of the take. Reading it live at
        /// stop time let a config reload land mid-take and pair a hold press
        /// with a tap stop, which strands the pressed key.
        case recording(rule: Rule, mode: TriggerMode, held: KeyChord?, since: Date)
    }

    private var state: State = .idle
    private let keystroke: KeystrokeEmitting

    public var config: Config
    /// Injected so the machine is testable without a window server.
    public var frontmostBundleID: () -> String?
    /// Injected so tests can observe shell actions instead of running them.
    /// Throwing means the command could not be launched at all.
    public var runShell: (String) throws -> Void

    public init(config: Config,
                frontmostBundleID: @escaping () -> String? = TriggerMachine.systemFrontmostBundleID,
                runShell: @escaping (String) throws -> Void = TriggerMachine.systemRunShell,
                keystroke: KeystrokeEmitting = Keystroke()) {
        self.config = config
        self.frontmostBundleID = frontmostBundleID
        self.runShell = runShell
        self.keystroke = keystroke
    }

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Genuine duplicate notifications arrive within milliseconds of each other
    /// (handoff §6). A second 0x35 later than this is not a duplicate — it means
    /// the device started a new recording while we still believed the previous
    /// take was running, i.e. our state is stale.
    public var duplicateWindow: TimeInterval = 0.5

    /// Starts seen recently, for the runaway guard.
    private var recentStarts: [Date] = []
    /// More starts than this within `runawayWindow` means something is wrong —
    /// a device malfunctioning as its battery dies, or a frame storm. Firing
    /// pauses rather than machine-gunning hotkeys into whatever is focused.
    public var runawayLimit = 12
    public var runawayWindow: TimeInterval = 60
    /// Set when the guard trips. Clear it by re-enabling firing.
    public private(set) var runawayTripped = false

    /// A take is abandoned after this long. Guards against a stop frame that
    /// never arrives — without it, a missed stop in hold mode leaves a modifier
    /// pressed indefinitely.
    public var maxTakeDuration: TimeInterval = 300

    /// How long the current take has been running, if any.
    public var takeDuration: TimeInterval? {
        guard case .recording(_, _, _, let since) = state else { return nil }
        return Date().timeIntervalSince(since)
    }

    /// End the current take without treating it as a normal stop, releasing any
    /// key being held. Call this on disconnect, on shutdown, and on timeout.
    ///
    /// This is the difference between a dropped connection being an
    /// inconvenience and it wedging the keyboard: in hold mode the modifier is
    /// physically down, and nothing else will ever lift it.
    @discardableResult
    public func abort(reason: String) -> TriggerOutcome {
        guard case .recording(_, _, let held, _) = state else {
            return .ignored(reason: "nothing to abort")
        }
        guard let held else {
            state = .idle
            return .ignored(reason: "take abandoned: \(reason)")
        }
        // Lift first, and only report success if the lift succeeded. The take is
        // over either way, but a failed release keeps the chord in
        // `pendingRelease` so the next tick can try again.
        do {
            try keystroke.release(held)
            state = .idle
            clearPending(held)
            return .fired(phase: .stop, rule: "abort", action: "released \(held.description) — \(reason)")
        } catch {
            state = .idle
            pendingRelease = held
            return .failed(phase: .stop,
                           reason: "could not release \(held.description): \(error)"
                                 + " — still down, will retry")
        }
    }

    /// A chord that is physically down but could not be lifted — Accessibility
    /// revoked mid-take is the realistic cause, since `Keystroke.isTrusted` can
    /// go false while the app is running.
    ///
    /// This is the one piece of state that outlives a take on purpose. It
    /// represents a key on a real keyboard, not a configuration, so it is kept
    /// until a release actually succeeds. Discarding it on the failing path is
    /// exactly how a stuck key becomes unrecoverable.
    package private(set) var pendingRelease: KeyChord?

    /// Retry an outstanding release. Drive this from the same timer as
    /// `checkTimeout()`; it is a no-op when nothing is stuck.
    @discardableResult
    package func retryPendingRelease() -> TriggerOutcome? {
        guard let chord = pendingRelease else { return nil }
        do {
            try keystroke.release(chord)
            pendingRelease = nil
            return .fired(phase: .stop, rule: "recovery",
                          action: "released \(chord.description) after an earlier failure")
        } catch {
            return .failed(phase: .stop,
                           reason: "\(chord.description) is still down: \(error)")
        }
    }

    /// Forget the outstanding stuck key only if this is the key that just came
    /// up. Clearing unconditionally meant a later take releasing a *different*
    /// chord erased the record of the first one, which is still physically down
    /// — the exact thing `pendingRelease` exists to prevent.
    private func clearPending(_ released: KeyChord) {
        if pendingRelease == released { pendingRelease = nil }
    }

    private func releaseHeld(_ chord: KeyChord, rule: String) -> TriggerOutcome {
        do {
            try keystroke.release(chord)
            clearPending(chord)
            return .fired(phase: .stop, rule: rule, action: chord.description)
        } catch {
            pendingRelease = chord
            return .failed(phase: .stop,
                           reason: "could not release \(chord.description): \(error)"
                                 + " — still down, will retry")
        }
    }

    /// Abort if the current take has outlived `maxTakeDuration`. Drive this from
    /// a timer.
    @discardableResult
    public func checkTimeout() -> TriggerOutcome? {
        guard let duration = takeDuration, duration > maxTakeDuration else { return nil }
        return abort(reason: String(format: "no stop after %.0fs", duration))
    }

    public func reset() {
        abort(reason: "reset")
        recentStarts.removeAll()
        runawayTripped = false
    }

    @discardableResult
    public func handle(_ event: RecordEvent) -> TriggerOutcome {
        switch event {
        case .recordStarted:
            let now = Date()
            if runawayTripped {
                return .ignored(reason: "firing paused by the runaway guard")
            }
            if case .recording(_, _, _, let since) = state {
                let age = Date().timeIntervalSince(since)
                guard age > duplicateWindow else {
                    return .ignored(reason: "duplicate start")
                }
                // The device just started recording, so whatever we thought was
                // in flight is gone — most likely its stop frame was lost to a
                // dropped link. Recover rather than swallowing every start from
                // here on, which looks to the user like the trigger silently
                // dying and never coming back.
                abort(reason: String(format: "stale take, %.0fs old", age))
            }
            // Count only starts that survive the duplicate check. Counting
            // before it meant one physical press registering twice ate two of
            // the twelve slots, halving the real budget to about six takes a
            // minute — reachable in ordinary rapid dictation.
            recentStarts.append(now)
            recentStarts.removeAll { now.timeIntervalSince($0) > runawayWindow }
            if recentStarts.count > runawayLimit {
                runawayTripped = true
                abort(reason: "runaway guard")
                return .failed(phase: .start,
                               reason: "\(recentStarts.count) starts in "
                                     + "\(Int(runawayWindow))s — firing paused. "
                                     + "Check the mic's battery and button.")
            }
            let rule = config.rule(for: frontmostBundleID())
            // Resolve the mode once, here. Everything the stop path needs is
            // fixed at the moment the take begins.
            let mode = rule.mode ?? config.mode
            state = .recording(rule: rule, mode: mode, held: nil, since: Date())
            return perform(rule.onStart, phase: .start, rule: rule, mode: mode, held: nil)

        case .stopPress:
            // Ambiguous: fires both on a 15-second timer and at the real press.
            // Logged by the CLI, never acted on. See the note above.
            return .ignored(reason: "02 [44 02] is ambiguous — waiting for 0x36")

        case .recordStopped:
            guard case .recording(let rule, let mode, let held, _) = state else {
                return .ignored(reason: "stop with no active take")
            }
            state = .idle
            return perform(rule.onStop, phase: .stop, rule: rule, mode: mode, held: held)

        case .startPress:
            return .ignored(reason: "start press (0x35 follows)")
        case .unknownRecordState(let b):
            return .ignored(reason: String(format: "unknown record state 0x%02X", b))
        case .other:
            return .ignored(reason: "not a trigger")
        }
    }

    private func perform(_ action: Action?,
                         phase: TriggerOutcome.Phase,
                         rule: Rule,
                         mode: TriggerMode,
                         held: KeyChord?) -> TriggerOutcome {
        let name = rule.name ?? rule.bundleIDs.first ?? "default"

        // Ending a hold means lifting whatever is physically down. That is
        // decided by what was pressed, not by what `onStop` says — so this runs
        // before any inspection of the action, which may be absent entirely.
        // Getting this backwards is what used to strand a modifier forever.
        if mode == .hold, phase == .stop {
            guard let held else {
                return .nothingConfigured(phase: phase, rule: name)
            }
            return releaseHeld(held, rule: name)
        }

        guard let action, !action.isEmpty else {
            return .nothingConfigured(phase: phase, rule: name)
        }

        if let shell = action.shell {
            // `try?` here used to swallow a failed launch and still report
            // .fired, so a shell action with a bad path looked like it worked.
            do {
                try runShell(shell)
                return .fired(phase: phase, rule: name, action: "shell: \(shell)")
            } catch {
                return .failed(phase: phase, reason: "shell: \(shell) — \(error)")
            }
        }

        guard let result = action.chord() else {
            return .nothingConfigured(phase: phase, rule: name)
        }
        switch result {
        case .failure(let error):
            return .failed(phase: phase, reason: error.description)
        case .success(let chord):
            do {
                switch (mode, phase) {
                case (.hold, .start):
                    try keystroke.press(chord)
                    // Remember what is physically down so the stop path and
                    // abort() can lift exactly this, whatever onStop says.
                    if case .recording(let r, let m, _, let since) = state {
                        state = .recording(rule: r, mode: m, held: chord, since: since)
                    }
                default:
                    try keystroke.tap(chord)
                }
                return .fired(phase: phase, rule: name, action: chord.description)
            } catch {
                return .failed(phase: phase, reason: "\(error)")
            }
        }
    }
}

#if canImport(AppKit)
import AppKit

public extension TriggerMachine {
    static func systemFrontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static func systemRunShell(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
    }
}
#else
public extension TriggerMachine {
    static func systemFrontmostBundleID() -> String? { nil }
    static func systemRunShell(_ command: String) throws {}
}
#endif
