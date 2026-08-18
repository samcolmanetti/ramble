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
        /// so it can be released if the take never ends normally.
        case recording(rule: Rule, held: KeyChord?, since: Date)
    }

    private var state: State = .idle
    private let keystroke: KeystrokeEmitting

    public var config: Config
    /// Injected so the machine is testable without a window server.
    public var frontmostBundleID: () -> String?
    /// Injected so tests can observe shell actions instead of running them.
    public var runShell: (String) -> Void

    public init(config: Config,
                frontmostBundleID: @escaping () -> String? = TriggerMachine.systemFrontmostBundleID,
                runShell: @escaping (String) -> Void = TriggerMachine.systemRunShell,
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

    /// A take is abandoned after this long. Guards against a stop frame that
    /// never arrives — without it, a missed stop in hold mode leaves a modifier
    /// pressed indefinitely.
    public var maxTakeDuration: TimeInterval = 300

    /// How long the current take has been running, if any.
    public var takeDuration: TimeInterval? {
        guard case .recording(_, _, let since) = state else { return nil }
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
        guard case .recording(_, let held, _) = state else {
            return .ignored(reason: "nothing to abort")
        }
        state = .idle
        guard let held else {
            return .ignored(reason: "take abandoned: \(reason)")
        }
        do {
            try keystroke.release(held)
            return .fired(phase: .stop, rule: "abort", action: "released \(held.description) — \(reason)")
        } catch {
            return .failed(phase: .stop, reason: "could not release \(held.description): \(error)")
        }
    }

    /// Abort if the current take has outlived `maxTakeDuration`. Drive this from
    /// a timer.
    @discardableResult
    public func checkTimeout() -> TriggerOutcome? {
        guard let duration = takeDuration, duration > maxTakeDuration else { return nil }
        return abort(reason: String(format: "no stop after %.0fs", duration))
    }

    /// Seed the state from the device's own recording flag (FCC1 `f9c13108`
    /// offset 6) rather than inferring it. Only meaningful at connect time.
    ///
    /// Note this deliberately does *not* fire a start action: the device being
    /// mid-recording tells us nothing about whether a dictation session was ever
    /// started on the Mac side.
    public func adoptDeviceState(recording: Bool) {
        abort(reason: "reconnected")
        _ = recording
    }

    public func reset() { abort(reason: "reset") }

    @discardableResult
    public func handle(_ event: RecordEvent) -> TriggerOutcome {
        switch event {
        case .recordStarted:
            if case .recording(_, _, let since) = state {
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
            let rule = config.rule(for: frontmostBundleID())
            state = .recording(rule: rule, held: nil, since: Date())
            return perform(rule.onStart, phase: .start, rule: rule)

        case .stopPress:
            // Ambiguous: fires both on a 15-second timer and at the real press.
            // Logged by the CLI, never acted on. See the note above.
            return .ignored(reason: "02 [44 02] is ambiguous — waiting for 0x36")

        case .recordStopped:
            guard case .recording(let rule, _, _) = state else {
                return .ignored(reason: "stop with no active take")
            }
            state = .idle
            return perform(rule.onStop, phase: .stop, rule: rule)

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
                         rule: Rule) -> TriggerOutcome {
        let name = rule.name ?? rule.bundleIDs.first ?? "default"
        guard let action, !action.isEmpty else {
            return .nothingConfigured(phase: phase, rule: name)
        }

        if let shell = action.shell {
            runShell(shell)
            return .fired(phase: phase, rule: name, action: "shell: \(shell)")
        }

        guard let result = action.chord() else {
            return .nothingConfigured(phase: phase, rule: name)
        }
        switch result {
        case .failure(let error):
            return .failed(phase: phase, reason: error.description)
        case .success(let chord):
            do {
                switch (rule.mode ?? config.mode, phase) {
                case (.hold, .start):
                    try keystroke.press(chord)
                    // Remember what is physically down so abort() can lift it.
                    if case .recording(let r, _, let since) = state {
                        state = .recording(rule: r, held: chord, since: since)
                    }
                case (.hold, .stop):
                    try keystroke.release(chord)
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

    static func systemRunShell(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
    }
}
#else
public extension TriggerMachine {
    static func systemFrontmostBundleID() -> String? { nil }
    static func systemRunShell(_ command: String) {}
}
#endif
