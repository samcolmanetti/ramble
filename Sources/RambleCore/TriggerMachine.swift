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
/// - **Stop fires on `02 [44 02]`, not `03 [36]`.** The device only sends
///   `0x36` after flushing the file to storage — 1.05 s later in Bluetooth
///   Microphone Mode, 1.64 s in Remote Control Mode. Waiting for it would append
///   over a second of dead air to every dictation. `0x36` remains a fallback for
///   the case where the press frame is missed.
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
        case recording(rule: Rule)
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

    /// Seed the state from the device's own recording flag (FCC1 `f9c13108`
    /// offset 6) rather than inferring it. Only meaningful at connect time.
    ///
    /// Note this deliberately does *not* fire a start action: the device being
    /// mid-recording tells us nothing about whether a dictation session was ever
    /// started on the Mac side.
    public func adoptDeviceState(recording: Bool) {
        state = .idle
        _ = recording
    }

    public func reset() { state = .idle }

    @discardableResult
    public func handle(_ event: RecordEvent) -> TriggerOutcome {
        switch event {
        case .recordStarted:
            guard case .idle = state else {
                return .ignored(reason: "already recording")
            }
            let rule = config.rule(for: frontmostBundleID())
            state = .recording(rule: rule)
            return perform(rule.onStart, phase: .start, rule: rule)

        case .stopPress:
            guard case .recording(let rule) = state else {
                return .ignored(reason: "stop press with no active take")
            }
            state = .idle
            return perform(rule.onStop, phase: .stop, rule: rule)

        case .recordStopped:
            // Normally already idle, because 02 [44 02] arrived ~1.5 s earlier
            // and handled the stop. Reaching here means that frame was missed.
            guard case .recording(let rule) = state else {
                return .ignored(reason: "stop already handled or no active take")
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
                case (.hold, .start): try keystroke.press(chord)
                case (.hold, .stop): try keystroke.release(chord)
                default: try keystroke.tap(chord)
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
