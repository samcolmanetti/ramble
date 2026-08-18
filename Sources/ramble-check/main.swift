import CoreAudio
import Foundation
import RambleCore

// ramble-check — the test suite.
//
// XCTest and swift-testing both ship with Xcode, not with the Command Line
// Tools, so `swift test` cannot run on a CLT-only machine (PLAN.md §2). Rather
// than make a 3 GB Xcode install a prerequisite for running tests, the suite is
// a plain executable with a ~20-line harness. `swift run ramble-check` exits
// non-zero on failure, so CI works the same way.

var failures = 0
var checks = 0
var currentGroup = ""

func group(_ name: String) {
    currentGroup = name
    print("\n\(name)")
}

func expect(_ condition: Bool, _ description: @autoclosure () -> String) {
    checks += 1
    if condition {
        print("  ✓ \(description())")
    } else {
        failures += 1
        print("  ✗ \(description())")
    }
}

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ description: String) {
    checks += 1
    if got == want {
        print("  ✓ \(description)")
    } else {
        failures += 1
        print("  ✗ \(description)\n      got:  \(got)\n      want: \(want)")
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
    var successValue: Success? {
        if case .success(let v) = self { return v }
        return nil
    }
}

// The seven distinct (opcode, payload) pairs seen in the capture (handoff §4).
//
// The handoff records each frame's opcode and payload but *not* its checksum
// byte, so these cases are reconstructed from the documented rule rather than
// replayed from the capture. They prove the parser is self-consistent and
// rejects malformed input; only a live `ramble-sniff` run proves the checksum
// rule itself is right. That is what Phase 1 is for.
let captured: [(UInt8, [UInt8])] = [
    (0x03, [0x35]),
    (0x03, [0x36]),
    (0x04, [0x44, 0xFF]),
    (0x02, [0x3A, 0x03, 0x4C]),
    (0x02, [0x44, 0x02]),
    (0x07, [0x4F, 0xAA, 0x58, 0xB9, 0x03, 0x1E, 0x02]),
    (0x09, [0x49, 0xC0, 0x8F, 0xE9, 0xC0, 0x38, 0x9F, 0x01, 0x02]),
]

group("frame round-trip over captured frames")
for (opcode, payload) in captured {
    let chk = Frame.checksum(opcode: opcode, payload: payload)
    let wire = Frame(opcode: opcode, payload: payload, checksum: chk).encoded()
    let label = String(format: "op %02X [%@]", opcode, payload.hex)

    expectEqual(wire.count, payload.count + 5, "\(label): total size is len + 5")
    expectEqual(Array(wire.prefix(3)), [0x00, 0x02, UInt8(payload.count)],
                "\(label): preamble and length byte")

    if let parsed = Frame.parse(wire).successValue {
        expectEqual(parsed.opcode, opcode, "\(label): opcode survives round-trip")
        expectEqual(parsed.payload, payload, "\(label): payload survives round-trip")
    } else {
        expect(false, "\(label): parses back")
    }
}

group("checksum formula: (1 - opcode - sum(payload)) & 0xFF")
expectEqual(Frame.checksum(opcode: 0x03, payload: [0x35]), 0xC9, "record-start checksum is C9")
expectEqual(Frame.checksum(opcode: 0x03, payload: [0x36]), 0xC8, "record-stop checksum is C8")
expectEqual(Frame.checksum(opcode: 0x00, payload: []), 0x01, "empty payload checksum is 01")

group("malformed frames are rejected")
expectEqual(Frame.parse([0x00, 0x02, 0x01]).failureValue, .tooShort(3),
            "frame under 6 bytes")
expectEqual(Frame.parse([0x01, 0x02, 0x01, 0x03, 0x35, 0xC9]).failureValue,
            .badPreamble([0x01, 0x02]), "wrong preamble")
expectEqual(Frame.parse([0x00, 0x02, 0x03, 0x03, 0x35, 0xC9]).failureValue,
            .lengthMismatch(declared: 3, frameSize: 6), "truncated notification")
expectEqual(Frame.parse([0x00, 0x02, 0x01, 0x03, 0x35, 0x00]).failureValue,
            .badChecksum(got: 0x00, expected: 0xC9), "corrupt checksum")

group("checksum catches every single-bit flip")
var survivors: [String] = []
for (opcode, payload) in captured {
    let chk = Frame.checksum(opcode: opcode, payload: payload)
    let wire = Frame(opcode: opcode, payload: payload, checksum: chk).encoded()
    for index in 3 ..< (wire.count - 1) {
        for bit in 0 ..< 8 {
            var corrupted = wire
            corrupted[index] ^= (1 << bit)
            if Frame.parse(corrupted).failureValue == nil {
                survivors.append(String(format: "op %02X byte %d bit %d", opcode, index, bit))
            }
        }
    }
}
expect(survivors.isEmpty,
       "no bit flip in opcode or payload survives (\(survivors.count) survivors)")
for s in survivors.prefix(5) { print("      survived: \(s)") }

group("record event interpretation")
func event(_ opcode: UInt8, _ payload: [UInt8]) -> RecordEvent {
    RecordEvent(frame: Frame(opcode: opcode, payload: payload,
                             checksum: Frame.checksum(opcode: opcode, payload: payload)))
}
expectEqual(event(0x03, [0x35]), .recordStarted, "0x03 [35] is record start")
expectEqual(event(0x03, [0x36]), .recordStopped, "0x03 [36] is record stop")
// A third value on 0x03 would mean the two-state hypothesis is incomplete, so it
// must be distinguishable from ordinary traffic rather than lumped into .other.
expectEqual(event(0x03, [0x37]), .unknownRecordState(0x37), "0x03 [37] is flagged, not ignored")
expectEqual(event(0x04, [0x44, 0xFF]), .other(opcode: 0x04, payload: [0x44, 0xFF]),
            "0x04 is not a trigger")
expectEqual(event(0x02, [0x3A, 0x03, 0x4C]), .other(opcode: 0x02, payload: [0x3A, 0x03, 0x4C]),
            "0x02 is not a trigger")
// 0x03 is only a trigger with a one-byte payload; a longer one means something
// else is going on and must not fire the hotkey.
expectEqual(event(0x03, [0x35, 0x00]), .other(opcode: 0x03, payload: [0x35, 0x00]),
            "0x03 with a 2-byte payload is not a trigger")

// ── trigger machine ───────────────────────────────────────────────────────

func frame(_ opcode: UInt8, _ payload: [UInt8]) -> RecordEvent {
    RecordEvent(frame: Frame(opcode: opcode, payload: payload,
                             checksum: Frame.checksum(opcode: opcode, payload: payload)))
}
let START = frame(0x03, [0x35])
let STOP_PRESS = frame(0x02, [0x44, 0x02])
let STOP_STATE = frame(0x03, [0x36])
let START_PRESS = frame(0x02, [0x48, 0x02])

/// Records what would have been typed, so the state machine can be tested
/// without an Accessibility grant.
final class FakeKeystroke: KeystrokeEmitting {
    enum Op { case tap, press, release }
    struct Denied: Error, CustomStringConvertible {
        var description: String { "accessibility denied" }
    }

    var taps: [String] = []
    var pressed: [String] = []
    var released: [String] = []
    /// Set to make that operation throw, standing in for Accessibility being
    /// revoked mid-session — the real failure `Keystroke.isTrusted` reports.
    var failOn: Op?

    func tap(_ chord: KeyChord) throws {
        if failOn == .tap { throw Denied() }
        taps.append(chord.description)
    }
    func press(_ chord: KeyChord) throws {
        if failOn == .press { throw Denied() }
        pressed.append(chord.description)
    }
    func release(_ chord: KeyChord) throws {
        if failOn == .release { throw Denied() }
        released.append(chord.description)
    }
}

func machine(frontmost: String?, mode: TriggerMode = .toggle)
    -> (TriggerMachine, () -> [String], FakeKeystroke) {
    var shellCalls: [String] = []
    let config = Config(
        mode: mode,
        targets: [Rule(name: "default", bundleIDs: [],
                       onStart: Action(key: "d", mods: ["cmd"]),
                       onStop: Action(key: "d", mods: ["cmd"]))],
        activeTarget: "default",
        rules: [
            Rule(name: "terminal", bundleIDs: ["com.mitchellh.ghostty"],
                 onStart: Action(key: "space"), onStop: Action(key: "space")),
            Rule(name: "muted", bundleIDs: ["com.example.secret"],
                 onStart: nil, onStop: nil),
            Rule(name: "shelly", bundleIDs: ["com.example.shell"],
                 onStart: Action(shell: "echo hi"), onStop: nil),
        ]
    )
    let keys = FakeKeystroke()
    let current = frontmost
    let m = TriggerMachine(config: config,
                           frontmostBundleID: { current },
                           runShell: { shellCalls.append($0) },
                           keystroke: keys)
    return (m, { shellCalls }, keys)
}

func ruleName(_ o: TriggerOutcome) -> String? {
    switch o {
    case .fired(_, let r, _), .nothingConfigured(_, let r): return r
    default: return nil
    }
}
func actionOf(_ o: TriggerOutcome) -> String? {
    if case .fired(_, _, let a) = o { return a }
    return nil
}
func isIgnored(_ o: TriggerOutcome) -> Bool {
    if case .ignored = o { return true }
    return false
}

group("keycode and chord parsing")
expectEqual(Keys.code(for: "space"), 49, "space is keycode 49")
expectEqual(Keys.code(for: "D"), 2, "key lookup is case-insensitive")
expect(Keys.code(for: "nope") == nil, "unknown key returns nil")
switch KeyChord.parse(key: "d", mods: ["ctrl", "opt", "cmd"]) {
case .success(let c): expectEqual(c.description, "⌃⌥⌘D", "chord renders as ⌃⌥⌘D")
case .failure(let e): expect(false, "chord parse failed: \(e)")
}
expectEqual(KeyChord.parse(key: "d", mods: ["hyper"]).failureValue,
            .unknownModifier("hyper"), "unknown modifier rejected")
expectEqual(KeyChord.parse(key: "nope", mods: []).failureValue,
            .unknownKey("nope"), "unknown key rejected")

group("rule selection by frontmost app")
let cfg = machine(frontmost: nil).0.config
expectEqual(cfg.rule(for: "com.mitchellh.ghostty").name, "terminal", "matching bundle ID wins")
expectEqual(cfg.rule(for: "COM.MITCHELLH.GHOSTTY").name, "terminal", "bundle match is case-insensitive")
expectEqual(cfg.rule(for: "com.unknown.app").name, "default", "unmatched app falls back to default")
expectEqual(cfg.rule(for: nil).name, "default", "nil frontmost falls back to default")

group("stop fires on 0x36 only — 02 [44 02] is a 15s timer, not the button")
do {
    let (m, _, _) = machine(frontmost: "com.mitchellh.ghostty")
    let started = m.handle(START)
    expectEqual(actionOf(started), "SPACE", "start fires the terminal rule")
    expect(m.isRecording, "machine is recording after start")

    // The bug this guards: 02 [44 02] arrives at exactly 15.00s regardless of
    // when the button is pressed. Acting on it truncated every dictation at 15s.
    expect(isIgnored(m.handle(STOP_PRESS)), "02 [44 02] does not stop the take")
    expect(m.isRecording, "still recording after the 15s timer frame")
    // It can arrive more than once in a long take; none of them may fire.
    expect(isIgnored(m.handle(STOP_PRESS)), "a second 02 [44 02] also does nothing")
    expect(m.isRecording, "still recording")

    let stopped = m.handle(STOP_STATE)
    expectEqual(actionOf(stopped), "SPACE", "0x36 is what actually stops")
    expect(!m.isRecording, "machine is idle after 0x36")
    expect(isIgnored(m.handle(STOP_STATE)), "a repeated 0x36 does not double-fire")
}

group("rule is latched at start, not re-resolved at stop")
do {
    var frontmost: String? = "com.mitchellh.ghostty"
    let config = machine(frontmost: nil).0.config
    let keys = FakeKeystroke()
    let m = TriggerMachine(config: config, frontmostBundleID: { frontmost },
                           runShell: { _ in }, keystroke: keys)
    expectEqual(actionOf(m.handle(START)), "SPACE", "started in the terminal")
    // User switches to another app mid-dictation.
    frontmost = "com.unknown.app"
    expectEqual(actionOf(m.handle(STOP_STATE)), "SPACE",
                "stop replays the terminal rule, not the new app's")
    expectEqual(keys.taps, ["SPACE", "SPACE"], "both keystrokes went to the terminal chord")
}

group("Fn/Globe as a key, for Wispr Flow push-to-talk")
expectEqual(Keys.code(for: "fn"), 63, "fn maps to kVK_Function (63)")
expectEqual(Keys.code(for: "globe"), 63, "globe is an alias for fn")
switch KeyChord.parse(key: "fn", mods: []) {
case .success(let c):
    expectEqual(c.keyCode, 63, "chord carries keycode 63")
    expect(c.flags.contains(.maskSecondaryFn),
           "fn sets maskSecondaryFn — listeners watch the flag, not just the keycode")
    expectEqual(c.description, "🌐fn", "fn renders legibly")
case .failure(let e):
    expect(false, "fn should parse: \(e)")
}

group("per-rule mode overrides the global mode")
do {
    // Wispr Flow needs a held Fn; Claude Code needs a discrete tap. One global
    // mode cannot serve both, so the rule must be able to override it.
    let config = Config(
        mode: .toggle,
        targets: [Rule(name: "wispr", bundleIDs: [],
                       onStart: Action(key: "fn"), onStop: Action(key: "fn"),
                       mode: .hold)],
        activeTarget: "wispr",
        rules: [Rule(name: "claude", bundleIDs: ["com.mitchellh.ghostty"],
                     onStart: Action(key: "space", mods: ["shift"]),
                     onStop: Action(key: "space", mods: ["shift"]),
                     mode: .toggle)]
    )
    let wisprKeys = FakeKeystroke()
    let w = TriggerMachine(config: config, frontmostBundleID: { "com.other.app" },
                           runShell: { _ in }, keystroke: wisprKeys)
    _ = w.handle(START)
    _ = w.handle(STOP_STATE)
    expectEqual(wisprKeys.pressed, ["🌐fn"], "default rule holds Fn down on start")
    expectEqual(wisprKeys.released, ["🌐fn"], "default rule releases Fn on stop")
    expectEqual(wisprKeys.taps, [], "default rule never taps despite global mode being toggle")

    let claudeKeys = FakeKeystroke()
    let c = TriggerMachine(config: config, frontmostBundleID: { "com.mitchellh.ghostty" },
                           runShell: { _ in }, keystroke: claudeKeys)
    _ = c.handle(START)
    _ = c.handle(STOP_STATE)
    expectEqual(claudeKeys.taps, ["⇧SPACE", "⇧SPACE"], "terminal rule taps twice")
    expectEqual(claudeKeys.pressed, [], "terminal rule never holds")
}

group("push-to-talk mode holds the key across the take")
do {
    let (m, _, keys) = machine(frontmost: "com.mitchellh.ghostty", mode: .hold)
    _ = m.handle(START)
    expectEqual(keys.pressed, ["SPACE"], "hold mode presses on start")
    expectEqual(keys.released, [], "hold mode has not released yet")
    _ = m.handle(STOP_STATE)
    expectEqual(keys.released, ["SPACE"], "hold mode releases on stop")
    expectEqual(keys.taps, [], "hold mode never taps")
}

// The stuck-key class. Hold mode used to release a chord re-derived from
// `onStop`, so anything that made that chord absent or different stranded the
// key that was actually down — with state already .idle, nothing could recover
// it. What is held is now what gets released, whatever onStop says.
group("hold mode releases the key it actually pressed")
do {
    // No onStop at all. The old code returned .nothingConfigured before
    // reaching any release, and Fn stayed down forever.
    let keys = FakeKeystroke()
    let config = Config(
        mode: .hold,
        targets: [Rule(name: "ptt", bundleIDs: [],
                       onStart: Action(key: "fn"), onStop: nil)],
        activeTarget: "ptt", rules: [])
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in }, keystroke: keys)
    _ = m.handle(START)
    expectEqual(keys.pressed, ["🌐fn"], "hold rule with no onStop still presses")
    let out = m.handle(STOP_STATE)
    expectEqual(keys.released, ["🌐fn"], "and still releases what it held")
    expectEqual(m.isRecording, false, "the take is over")
    var didFire = false
    if case .fired = out { didFire = true }
    expect(didFire, "a released hold reports .fired, got \(out)")
}
do {
    // onStop names a different key. Releasing that one would leave Fn down.
    let keys = FakeKeystroke()
    let config = Config(
        mode: .hold,
        targets: [Rule(name: "ptt", bundleIDs: [],
                       onStart: Action(key: "fn"), onStop: Action(key: "space"))],
        activeTarget: "ptt", rules: [])
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in }, keystroke: keys)
    _ = m.handle(START)
    _ = m.handle(STOP_STATE)
    expectEqual(keys.released, ["🌐fn"], "a mismatched onStop cannot strand the held key")
    expectEqual(keys.taps, [], "and does not tap the onStop key either")
}
do {
    // The press never landed, so there is nothing to lift. Reporting .fired
    // here would claim a release that did not happen.
    let keys = FakeKeystroke()
    keys.failOn = .press
    let config = Config(
        mode: .hold,
        targets: [Rule(name: "ptt", bundleIDs: [],
                       onStart: Action(key: "fn"), onStop: Action(key: "fn"))],
        activeTarget: "ptt", rules: [])
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in }, keystroke: keys)
    _ = m.handle(START)
    keys.failOn = nil
    let out = m.handle(STOP_STATE)
    expectEqual(keys.released, [], "nothing was held, so nothing is released")
    var reportedNothing = false
    if case .nothingConfigured = out { reportedNothing = true }
    expect(reportedNothing,
           "a hold stop with nothing held reports nothing to release, got \(out)")
}

group("the mode in force is latched when the take starts")
do {
    // Editing config.json mid-take used to pair a hold press with a tap stop.
    let keys = FakeKeystroke()
    let config = Config(
        mode: .hold,
        targets: [Rule(name: "t", bundleIDs: [],
                       onStart: Action(key: "fn"), onStop: Action(key: "fn"))],
        activeTarget: "t", rules: [])
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in }, keystroke: keys)
    _ = m.handle(START)
    expectEqual(keys.pressed, ["🌐fn"], "started as a hold")
    var edited = config
    edited.mode = .toggle
    m.config = edited                       // the hot-reload lands mid-take
    _ = m.handle(STOP_STATE)
    expectEqual(keys.released, ["🌐fn"], "the take still ends as the hold it began as")
    expectEqual(keys.taps, [], "and does not tap instead")
}
do {
    let keys = FakeKeystroke()
    let config = Config(
        mode: .toggle,
        targets: [Rule(name: "t", bundleIDs: [],
                       onStart: Action(key: "fn"), onStop: Action(key: "fn"))],
        activeTarget: "t", rules: [])
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in }, keystroke: keys)
    _ = m.handle(START)
    var edited = config
    edited.mode = .hold
    m.config = edited
    _ = m.handle(STOP_STATE)
    expectEqual(keys.taps, ["🌐fn", "🌐fn"], "a toggle take stays a toggle take")
    expectEqual(keys.pressed, [], "nothing is ever held")
}
do {
    // Toggle is the default for any rule that does not ask for hold.
    let (m, _, keys) = machine(frontmost: "com.mitchellh.ghostty")
    _ = m.handle(START)
    _ = m.handle(STOP_STATE)
    expectEqual(keys.pressed, [], "a rule with no mode never holds")
    expectEqual(keys.taps, ["SPACE", "SPACE"], "it taps on both edges")
}

group("connecting mid-recording does not fire a stray keystroke")
do {
    let (m, _, _) = machine(frontmost: nil)
    // Exactly what the probe saw: a bare 0x36 with no preceding start.
    expect(isIgnored(m.handle(STOP_STATE)), "bare 0x36 while idle is ignored")
    expect(isIgnored(m.handle(STOP_PRESS)), "bare 02 [44 02] while idle is ignored")
}

group("a stale take recovers instead of swallowing every start")
do {
    // The failure this prevents: a stop frame is lost to a dropped link, the
    // machine stays .recording forever, and every later press is ignored -- the
    // LED turns red but nothing ever fires again.
    let config = Config(mode: .hold,
                        targets: [Rule(name: "wispr", bundleIDs: [],
                                       onStart: Action(key: "fn"),
                                       onStop: Action(key: "fn"))],
                        activeTarget: "wispr")
    let keys = FakeKeystroke()
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in }, keystroke: keys)
    m.duplicateWindow = 0.1
    _ = m.handle(START)
    expectEqual(keys.pressed, ["🌐fn"], "first take holds fn")
    // Stop frame never arrives. Next press starts a new recording.
    Thread.sleep(forTimeInterval: 0.15)
    let recovered = m.handle(START)
    expectEqual(actionOf(recovered), "🌐fn", "a later start fires instead of being ignored")
    expectEqual(keys.released, ["🌐fn"], "the stale hold was released first")
    expectEqual(keys.pressed, ["🌐fn", "🌐fn"], "and the new take holds again")
    expect(m.isRecording, "machine is tracking the new take")
}

group("duplicate and non-trigger frames")
do {
    let (m, _, _) = machine(frontmost: nil)
    _ = m.handle(START)
    expect(isIgnored(m.handle(START)), "duplicate start within the window is ignored")
    expect(isIgnored(m.handle(START_PRESS)), "02 [48 02] does not fire (0x35 follows)")
    expect(isIgnored(m.handle(frame(0x04, [0x44, 0xFF]))), "0x04 is not a trigger")
    expect(isIgnored(m.handle(frame(0x02, [0x3A, 0x03, 0x4C]))), "other 0x02 payloads are not triggers")
    expect(isIgnored(m.handle(frame(0x03, [0x37]))), "unknown 0x03 payload does not fire")
}

group("actions: muted apps and shell escape hatch")
do {
    let (m, _, _) = machine(frontmost: "com.example.secret")
    if case .nothingConfigured(_, let rule) = m.handle(START) {
        expectEqual(rule, "muted", "an app with null actions fires nothing")
    } else {
        expect(false, "muted app should report nothingConfigured")
    }
    expect(m.isRecording, "muted app still tracks state so its stop is consumed")
}
do {
    let (m, shellCalls, _) = machine(frontmost: "com.example.shell")
    _ = m.handle(START)
    expectEqual(shellCalls(), ["echo hi"], "shell action runs the command")
}

group("a held key is always released, however the take ends")
do {
    // The dangerous case: hold mode presses Fn, then the link drops. Without
    // abort() the modifier stays physically down system-wide.
    let config = Config(mode: .hold,
                        targets: [Rule(name: "wispr", bundleIDs: [],
                                       onStart: Action(key: "fn"),
                                       onStop: Action(key: "fn"))],
                        activeTarget: "wispr")
    let keys = FakeKeystroke()
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in }, keystroke: keys)
    _ = m.handle(START)
    expectEqual(keys.pressed, ["🌐fn"], "fn is held down")
    expectEqual(keys.released, [], "not released yet")

    let outcome = m.abort(reason: "device disconnected")
    expectEqual(keys.released, ["🌐fn"], "abort releases the held key")
    expect(!m.isRecording, "abort returns to idle")
    if case .fired(_, _, let action) = outcome {
        expect(action.contains("device disconnected"), "abort reports why: \(action)")
    } else {
        expect(false, "abort should report a fired release, got \(outcome)")
    }
}

group("aborting when nothing is held is harmless")
do {
    let (m, _, keys) = machine(frontmost: nil)
    expect(isIgnored(m.abort(reason: "idle")), "abort while idle is a no-op")
    expectEqual(keys.released, [], "nothing released")

    // Toggle mode taps rather than holds, so there is nothing to lift.
    _ = m.handle(START)
    _ = m.abort(reason: "disconnected")
    expectEqual(keys.released, [], "toggle-mode abort releases nothing")
    expect(!m.isRecording, "but still returns to idle")
}

group("a take that never stops times out")
do {
    let config = Config(mode: .hold,
                        targets: [Rule(name: "wispr", bundleIDs: [],
                                       onStart: Action(key: "fn"),
                                       onStop: Action(key: "fn"))],
                        activeTarget: "wispr")
    let keys = FakeKeystroke()
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in }, keystroke: keys)
    m.maxTakeDuration = 0.2
    _ = m.handle(START)
    expect(m.checkTimeout() == nil, "no timeout before the deadline")
    Thread.sleep(forTimeInterval: 0.3)
    expect(m.checkTimeout() != nil, "timeout fires after the deadline")
    expectEqual(keys.released, ["🌐fn"], "timeout releases the held key")
    expect(!m.isRecording, "timeout returns to idle")
    expect(m.checkTimeout() == nil, "timeout does not fire twice")
}

group("runaway guard pauses firing instead of machine-gunning hotkeys")
do {
    let config = Config(mode: .hold,
                        targets: [Rule(name: "wispr", bundleIDs: [],
                                       onStart: Action(key: "fn"),
                                       onStop: Action(key: "fn"))],
                        activeTarget: "wispr")
    let keys = FakeKeystroke()
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in }, keystroke: keys)
    m.runawayLimit = 3
    m.duplicateWindow = 0
    for _ in 0 ..< 3 {
        _ = m.handle(START)
        _ = m.handle(STOP_STATE)
    }
    expectEqual(keys.pressed.count, 3, "normal starts fire up to the limit")
    expect(!m.runawayTripped, "guard not tripped at the limit")

    let tripped = m.handle(START)
    expect(m.runawayTripped, "exceeding the limit trips the guard")
    if case .failed(_, let reason) = tripped {
        expect(reason.contains("firing paused"), "reports why: \(reason)")
    } else {
        expect(false, "should report a failure, got \(tripped)")
    }
    expectEqual(keys.pressed.count, 3, "no further keystrokes are sent")
    expect(!m.isRecording, "and nothing is left held")

    _ = m.handle(START)
    expectEqual(keys.pressed.count, 3, "still suppressed while tripped")

    m.reset()
    expect(!m.runawayTripped, "reset clears the guard")
    _ = m.handle(START)
    expectEqual(keys.pressed.count, 4, "firing resumes after reset")
}

// The guard used to count every 0x35 the radio delivered, including the
// hardware duplicates `duplicateWindow` exists to absorb. One physical press
// costing two of twelve slots halves the real budget to about six takes a
// minute, which ordinary rapid dictation reaches.
group("the runaway guard counts presses, not duplicate notifications")
do {
    let (m, _, keys) = machine(frontmost: "com.mitchellh.ghostty")
    m.runawayLimit = 3
    // Left at the real default (0.5s), so the second 0x35 of each pair is a
    // genuine duplicate rather than a new take.
    for _ in 0 ..< 3 {
        _ = m.handle(START)
        _ = m.handle(START)          // the duplicate the hardware emits
        _ = m.handle(STOP_STATE)
    }
    expect(!m.runawayTripped, "three presses with a duplicate each does not trip a limit of three")
    expectEqual(keys.taps.count, 6, "three takes tapped start and stop")
}
do {
    let (m, _, _) = machine(frontmost: "com.mitchellh.ghostty")
    m.runawayLimit = 3
    m.duplicateWindow = 0            // every start is its own take
    for _ in 0 ..< 4 {
        _ = m.handle(START)
        _ = m.handle(STOP_STATE)
    }
    expect(m.runawayTripped, "four genuine takes still trip a limit of three")
}

// A release can fail — Keystroke.isTrusted goes false the moment Accessibility
// is revoked. The chord is the only record that a key is physically down, so
// losing it on the failing path is what makes a stuck key unrecoverable.
group("a failed release is retried, never forgotten")
do {
    let keys = FakeKeystroke()
    let config = Config(
        mode: .hold,
        targets: [Rule(name: "ptt", bundleIDs: [], onStart: Action(key: "fn"))],
        activeTarget: "ptt", rules: [])
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in }, keystroke: keys)
    _ = m.handle(START)
    keys.failOn = .release
    let out = m.handle(STOP_STATE)
    expectEqual(keys.released, [], "the release did not land")
    expectEqual(m.pendingRelease?.description, "🌐fn", "so the chord is kept for a retry")
    var reportedFailure = false
    if case .failed = out { reportedFailure = true }
    expect(reportedFailure, "and the stop reports failure rather than success")

    let stillStuck = m.retryPendingRelease()
    expectEqual(m.pendingRelease?.description, "🌐fn", "a failed retry keeps it pending")
    var retryFailed = false
    if case .failed = stillStuck { retryFailed = true }
    expect(retryFailed, "and says so")

    keys.failOn = nil                // Accessibility granted again
    _ = m.retryPendingRelease()
    expectEqual(keys.released, ["🌐fn"], "the next retry lifts the key")
    expect(m.pendingRelease == nil, "and nothing is pending afterwards")
    expect(m.retryPendingRelease() == nil, "retrying with nothing pending is a no-op")
}
do {
    // Same guarantee on the abort path, which is what a dropped BLE link uses.
    let keys = FakeKeystroke()
    let config = Config(
        mode: .hold,
        targets: [Rule(name: "ptt", bundleIDs: [], onStart: Action(key: "fn"))],
        activeTarget: "ptt", rules: [])
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in }, keystroke: keys)
    _ = m.handle(START)
    keys.failOn = .release
    let out = m.abort(reason: "disconnected")
    expectEqual(m.pendingRelease?.description, "🌐fn", "abort keeps the chord when release fails")
    expect(!m.isRecording, "the take is over even though the key is not up")
    var abortFailed = false
    if case .failed = out { abortFailed = true }
    expect(abortFailed, "and abort reports the failure")
}
do {
    let (m, _, _) = machine(frontmost: "com.mitchellh.ghostty")
    _ = m.handle(START)
    _ = m.abort(reason: "nothing held in toggle mode")
    expect(m.pendingRelease == nil, "aborting a toggle take leaves nothing pending")
}
do {
    // A later take releasing a *different* chord must not erase the record of
    // the first one, which is still physically down.
    let keys = FakeKeystroke()
    var config = Config(
        mode: .hold,
        targets: [Rule(name: "a", bundleIDs: [], onStart: Action(key: "fn"))],
        activeTarget: "a", rules: [])
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in }, keystroke: keys)
    _ = m.handle(START)
    keys.failOn = .release
    _ = m.handle(STOP_STATE)
    expectEqual(m.pendingRelease?.description, "🌐fn", "fn is stuck")

    // Switch to a rule that holds a different key, and let that one succeed.
    keys.failOn = nil
    config.targets = [Rule(name: "b", bundleIDs: [], onStart: Action(key: "space"))]
    config.selectTarget(named: "b")
    m.config = config
    _ = m.handle(START)
    _ = m.handle(STOP_STATE)
    expectEqual(keys.released, ["SPACE"], "the second take released its own key")
    expectEqual(m.pendingRelease?.description, "🌐fn",
                "and fn is still recorded as stuck, not forgotten")

    // Only releasing fn itself clears it.
    _ = m.retryPendingRelease()
    expect(m.pendingRelease == nil, "retrying the stuck chord clears it")
}
do {
    // Same guarantee via abort(), which is the BLE-disconnect path.
    let keys = FakeKeystroke()
    var config = Config(
        mode: .hold,
        targets: [Rule(name: "a", bundleIDs: [], onStart: Action(key: "fn"))],
        activeTarget: "a", rules: [])
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in }, keystroke: keys)
    _ = m.handle(START)
    keys.failOn = .release
    _ = m.handle(STOP_STATE)
    expectEqual(m.pendingRelease?.description, "🌐fn", "fn is stuck")

    keys.failOn = nil
    config.targets = [Rule(name: "b", bundleIDs: [], onStart: Action(key: "space"))]
    config.selectTarget(named: "b")
    m.config = config
    _ = m.handle(START)
    _ = m.abort(reason: "device disconnected")
    expectEqual(keys.released, ["SPACE"], "the aborted take released its own key")
    expectEqual(m.pendingRelease?.description, "🌐fn",
                "and abort does not forget the earlier stuck key either")
}

group("switchable dictation targets")
do {
    var config = Config(
        mode: .toggle,
        targets: [
            Rule(name: "Wispr Flow", onStart: Action(key: "fn"),
                 onStop: Action(key: "fn"), mode: .hold),
            Rule(name: "MacWhisper", onStart: Action(key: "m", mods: ["cmd", "shift"]),
                 onStop: Action(key: "m", mods: ["cmd", "shift"])),
            Rule(name: "Off"),
        ],
        activeTarget: "Wispr Flow",
        rules: [Rule(name: "terminal", bundleIDs: ["com.mitchellh.ghostty"],
                     onStart: Action(key: "space"), onStop: Action(key: "space"))]
    )

    expectEqual(config.activeRule.name, "Wispr Flow", "active target is the selected one")
    expectEqual(config.rule(for: "com.apple.Safari").onStart?.summary, "🌐fn",
                "an app without a rule uses the active target")
    // The point of per-app rules: they survive switching the global target.
    expectEqual(config.rule(for: "com.mitchellh.ghostty").onStart?.summary, "SPACE",
                "a per-app rule beats the active target")

    config.selectTarget(named: "MacWhisper")
    expectEqual(config.activeRule.name, "MacWhisper", "switching changes the active target")
    expectEqual(config.rule(for: "com.apple.Safari").onStart?.summary, "⇧⌘M",
                "and changes what unmatched apps send")
    expectEqual(config.rule(for: "com.mitchellh.ghostty").onStart?.summary, "SPACE",
                "but leaves per-app rules alone")

    config.selectTarget(named: "Off")
    expect(config.rule(for: "com.apple.Safari").onStart == nil,
           "the Off target sends nothing")

    config.selectTarget(named: "Nonexistent")
    expectEqual(config.activeRule.name, "Off", "an unknown target name is ignored")
}

group("menu bar icon can be hidden, and defaults to visible")
do {
    let fresh = Config.starter()
    expect(fresh.showMenuBarIcon, "starter config shows the icon")

    // Absent from an older config file: must default to visible, or upgrading
    // would silently hide the only UI.
    let legacy = try! JSONDecoder().decode(
        Config.self, from: Data("{\"mode\":\"toggle\"}".utf8))
    expect(legacy.showMenuBarIcon, "a config with no showMenuBarIcon key shows the icon")

    let hidden = try! JSONDecoder().decode(
        Config.self, from: Data("{\"showMenuBarIcon\":false}".utf8))
    expect(!hidden.showMenuBarIcon, "explicit false hides it")

    var round = Config.starter()
    round.showMenuBarIcon = false
    let reloaded = try! JSONDecoder().decode(Config.self,
                                             from: try! JSONEncoder().encode(round))
    expect(!reloaded.showMenuBarIcon, "the setting survives a save/load cycle")
}

group("configs written before targets existed still load")
do {
    // defaultRule was the old shape. Dropping support would break anyone who
    // upgraded, so it stays as a fallback.
    let legacy = """
    {"mode":"toggle","autoReconnect":true,
     "defaultRule":{"name":"old","bundleIDs":[],"onStart":{"key":"fn"}},
     "rules":[]}
    """
    let decoded = try! JSONDecoder().decode(Config.self, from: Data(legacy.utf8))
    expectEqual(decoded.activeRule.name, "old", "legacy defaultRule becomes the active rule")
    expectEqual(decoded.rule(for: "com.apple.Safari").onStart?.summary, "🌐fn",
                "and still resolves actions")
}

group("targets may omit bundleIDs")
do {
    let json = """
    {"targets":[{"name":"T","onStart":{"key":"space"}}],"activeTarget":"T"}
    """
    let decoded = try! JSONDecoder().decode(Config.self, from: Data(json.utf8))
    expectEqual(decoded.activeRule.name, "T", "a target without bundleIDs decodes")
    expectEqual(decoded.rule(for: "anything").onStart?.summary, "SPACE", "and applies")
}

group("config round-trips through JSON")
do {
    let original = Config.starter()
    let data = try! JSONEncoder().encode(original)
    let decoded = try! JSONDecoder().decode(Config.self, from: data)
    expectEqual(decoded, original, "starter config survives encode/decode")
    expectEqual(decoded.rule(for: "com.mitchellh.ghostty").onStart?.summary, "SPACE",
                "starter config sends a bare Space to terminals — modifiers are"
                    + " unreliable through a terminal")
    expectEqual(decoded.rule(for: "com.apple.Safari").onStart?.summary, "🌐fn",
                "starter active target is Wispr Flow's Fn push-to-talk")
    expectEqual(decoded.rule(for: "com.apple.Safari").mode, .hold,
                "the Wispr Flow rule holds rather than taps")
}

group("a shell action that cannot launch reports failure")
do {
    struct NoSuchThing: Error, CustomStringConvertible {
        var description: String { "no such file" }
    }
    let config = Config(
        mode: .toggle,
        targets: [Rule(name: "sh", bundleIDs: [], onStart: Action(shell: "does-not-exist"))],
        activeTarget: "sh", rules: [])
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { _ in throw NoSuchThing() },
                           keystroke: FakeKeystroke())
    let out = m.handle(START)
    var reported = false
    if case .failed(_, let reason) = out {
        reported = reason.contains("does-not-exist")
    }
    expect(reported, "a failed launch is reported, not swallowed: \(out)")
}
do {
    var ran: [String] = []
    let config = Config(
        mode: .toggle,
        targets: [Rule(name: "sh", bundleIDs: [], onStart: Action(shell: "true"))],
        activeTarget: "sh", rules: [])
    let m = TriggerMachine(config: config, frontmostBundleID: { nil },
                           runShell: { ran.append($0) }, keystroke: FakeKeystroke())
    let out = m.handle(START)
    expectEqual(ran, ["true"], "a launchable command still runs")
    var fired = false
    if case .fired = out { fired = true }
    expect(fired, "and reports success")
}

group("BLE states that strand a take are the ones that abort it")
expectEqual(BLEState.disconnected(nil).abortReason, "device disconnected",
            "a disconnect abandons the take")
expectEqual(BLEState.poweredOff.abortReason, "Bluetooth turned off",
            "so does the radio going off — this used to wait for the 300s timeout")
expectEqual(BLEState.unauthorized.abortReason, "Bluetooth permission revoked",
            "and permission being revoked")
expectEqual(BLEState.unsupported.abortReason, "Bluetooth unavailable",
            "and the radio being unavailable")
expect(BLEState.connected("Instamic").abortReason == nil, "a connected take continues")
expect(BLEState.connecting("Instamic").abortReason == nil, "so does a connecting one")
expect(BLEState.scanning.abortReason == nil, "and scanning never aborts a take")

// ── audio routing ─────────────────────────────────────────────────────────
//
// A Bluetooth mic is an HFP device, and HFP is a headset profile: there is no
// mic-only connection to ask for. Connecting one for its microphone hands macOS
// a speaker too, and macOS takes it — dropping all system audio to 16 kHz mono.
// These rules claim the input and give playback straight back.

func dev(_ id: UInt32, _ name: String, inCh: Int = 0, outCh: Int = 0) -> AudioDevice {
    AudioDevice(id: AudioDeviceID(id), name: name, uid: "uid-\(id)",
                inputChannels: inCh, outputChannels: outCh)
}

let mic      = dev(1, "Instamic", inCh: 1, outCh: 1)   // both halves, as HFP gives it
let speakers = dev(2, "MacBook Pro Speakers", outCh: 2)
let monitor  = dev(3, "DELL U3225QE", outCh: 2)
let builtIn  = dev(4, "MacBook Pro Microphone", inCh: 1)
let all = [mic, speakers, monitor, builtIn]

group("audio routing claims the mic and hands playback back")
do {
    // Exactly what connecting the mic does: it becomes both input and output.
    let plan = AudioRouting.plan(devices: all, defaultInput: builtIn,
                                 defaultOutput: mic, micName: "Instamic",
                                 preferredOutput: "MacBook Pro Speakers")
    expectEqual(plan.claimInput?.name, "Instamic", "the mic is claimed for input")
    expectEqual(plan.restoreOutput?.name, "MacBook Pro Speakers",
                "and playback goes back to the preferred output")
    expect(!plan.connectBluetooth, "no need to connect — it is already present")
}
do {
    // Already correct: this runs every 5s, so it must do nothing.
    let plan = AudioRouting.plan(devices: all, defaultInput: mic,
                                 defaultOutput: speakers, micName: "Instamic",
                                 preferredOutput: "MacBook Pro Speakers")
    expect(plan.isNoOp, "a correct setup is left completely alone")
}
do {
    // No preference set — anything that is not the mic will do.
    let plan = AudioRouting.plan(devices: all, defaultInput: mic,
                                 defaultOutput: mic, micName: "Instamic",
                                 preferredOutput: nil)
    expect(plan.restoreOutput != nil, "playback is still taken off the mic")
    expect(plan.restoreOutput?.name.contains("Instamic") == false,
           "and never handed back to the mic itself")
}
do {
    // The user deliberately picked a different output. Leave it be.
    let plan = AudioRouting.plan(devices: all, defaultInput: mic,
                                 defaultOutput: monitor, micName: "Instamic",
                                 preferredOutput: "MacBook Pro Speakers")
    expect(plan.restoreOutput == nil,
           "an output the mic did not steal is the user's business")
}
do {
    // Mic absent entirely: the Bluetooth link is down.
    let plan = AudioRouting.plan(devices: [speakers, builtIn], defaultInput: builtIn,
                                 defaultOutput: speakers, micName: "Instamic",
                                 preferredOutput: nil)
    expect(plan.connectBluetooth, "an absent mic means connect the link first")
    expect(plan.claimInput == nil, "and nothing to claim yet")
}
do {
    // Present as an output only — no input half yet, so it is not usable.
    let halfUp = dev(9, "Instamic", inCh: 0, outCh: 1)
    let plan = AudioRouting.plan(devices: [halfUp, speakers, builtIn],
                                 defaultInput: builtIn, defaultOutput: speakers,
                                 micName: "Instamic", preferredOutput: nil)
    expect(plan.connectBluetooth, "an output-only mic is not connected for input yet")
}
do {
    // Matching is by substring and case-insensitive.
    let plan = AudioRouting.plan(devices: all, defaultInput: builtIn,
                                 defaultOutput: speakers, micName: "instamic",
                                 preferredOutput: nil)
    expectEqual(plan.claimInput?.name, "Instamic", "device matching ignores case")
}

group("audio settings decode with safe defaults")
do {
    let json = "{}"
    let c = try! JSONDecoder().decode(Config.self, from: Data(json.utf8))
    expect(!c.audio.autoConnect, "audio routing is off unless asked for")
    expectEqual(c.audio.device, "Instamic", "and defaults to the Instamic")

    let on = """
    {"audio":{"autoConnect":true,"device":"Instamic","preferredOutput":"MacBook Pro Speakers"}}
    """
    let c2 = try! JSONDecoder().decode(Config.self, from: Data(on.utf8))
    expect(c2.audio.autoConnect, "and turns on when asked")
    expectEqual(c2.audio.preferredOutput, "MacBook Pro Speakers", "carrying the output preference")
    let round = try! JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c2))
    expectEqual(round.audio, c2.audio, "audio settings survive a round trip")
}

// ── config on disk ────────────────────────────────────────────────────────
//
// load/save/loadOrCreate had no coverage at all, which is how a save path that
// silently dropped unknown keys and a reload path that could overwrite the
// user's file both shipped.

func tempConfigURL(_ name: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ramble-check-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("config.json")
}

group("config load, save, and create round-trip on disk")
do {
    let url = tempConfigURL("roundtrip")
    try? FileManager.default.removeItem(at: url)

    let (created, wasCreated) = try! Config.loadOrCreate(at: url)
    expect(wasCreated, "loadOrCreate writes a starter config when none exists")
    expectEqual(created, Config.starter(), "and returns exactly what it wrote")

    let (reloaded, wasCreatedAgain) = try! Config.loadOrCreate(at: url)
    expect(!wasCreatedAgain, "a second call reads the existing file")
    expectEqual(reloaded, created, "and the file round-trips unchanged")

    var edited = reloaded
    edited.selectTarget(named: "MacWhisper")
    try! edited.save(to: url)
    expectEqual(try! Config.load(from: url).activeTarget, "MacWhisper",
                "a saved change survives a reload")
    try? FileManager.default.removeItem(at: url)
}

group("saving preserves keys this version does not model")
do {
    let url = tempConfigURL("unknown-keys")
    try? FileManager.default.removeItem(at: url)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    // A hand-added key, or one a newer Ramble wrote.
    let handWritten = """
    {"mode":"toggle","activeTarget":"Wispr Flow","futureSetting":{"keep":true},"targets":[],"rules":[]}
    """
    try! handWritten.write(to: url, atomically: true, encoding: .utf8)

    var loaded = try! Config.load(from: url)
    loaded.selectTarget(named: "Wispr Flow")
    try! loaded.save(to: url)

    let raw = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    expect(raw["futureSetting"] != nil, "an unmodelled key survives a save")
    expectEqual(raw["mode"] as? String, "toggle", "and the modelled keys are still written")

    // A modelled optional cleared in memory must stay cleared. Treating "absent
    // from the fresh encode" as "unknown" would copy the old value back.
    var cleared = try! Config.load(from: url)
    cleared.activeTarget = nil
    try! cleared.save(to: url)
    let after = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    expect(after["activeTarget"] == nil, "a cleared optional is not resurrected from disk")
    expect(after["futureSetting"] != nil, "while the unmodelled key is still preserved")
    try? FileManager.default.removeItem(at: url)
}

group("a broken config names the key at fault")
do {
    let url = tempConfigURL("malformed")
    try? FileManager.default.removeItem(at: url)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)

    try! "{\"mode\": 5}".write(to: url, atomically: true, encoding: .utf8)
    do {
        _ = try Config.load(from: url)
        expect(false, "a wrong-typed value should not decode")
    } catch {
        let described = Config.describe(error)
        expect(described.contains("mode"), "the error names the offending key: \(described)")
        expect(described != error.localizedDescription,
               "and improves on Foundation's generic message")
    }

    try! "not json at all".write(to: url, atomically: true, encoding: .utf8)
    do {
        _ = try Config.load(from: url)
        expect(false, "garbage should not decode")
    } catch {
        expect(Config.describe(error).contains("not valid JSON"),
               "invalid JSON says so plainly")
    }

    try! "".write(to: url, atomically: true, encoding: .utf8)
    do {
        _ = try Config.load(from: url)
        expect(false, "an empty file should not decode")
    } catch {
        expect(Config.describe(error).contains("not valid JSON"),
               "an empty file reads as invalid JSON, distinct from {}")
    }

    try! "{}".write(to: url, atomically: true, encoding: .utf8)
    let empty = try? Config.load(from: url)
    expect(empty != nil, "an empty object decodes to defaults rather than failing")
    expectEqual(empty?.mode, .toggle, "and defaults to toggle, the safe mode")
    try? FileManager.default.removeItem(at: url)
}

print("""

────────────────────────────────────────────
\(failures == 0 ? "PASS" : "FAIL")  \(checks - failures)/\(checks) checks
""")
exit(failures == 0 ? 0 : 1)
