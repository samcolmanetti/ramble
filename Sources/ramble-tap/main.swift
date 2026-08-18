import CoreGraphics
import Foundation
import RambleCore

// ramble-tap — watch what the system actually receives.
//
// When a synthesized keystroke "does nothing", there are three candidate
// failures and no way to tell them apart from the sending side: the event was
// never posted, the event was posted but in a form nobody listens for, or the
// event arrived correctly and the target app ignored it. This taps the event
// stream and prints what really shows up, which separates the first two from
// the third.
//
//   ramble-tap                 watch every key and modifier event
//   ramble-tap --self-test fn  post a chord, then report whether it was observed

setvbuf(stdout, nil, _IONBF, 0)

var selfTestKey: String? = nil
var selfTestMods: [String] = []
let argv = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < argv.count {
    switch argv[i] {
    case "-h", "--help":
        print("""
        usage: ramble-tap [--self-test <key> [mods...]]

          --self-test <key> [mods...]   post the chord and report what the tap saw
                                        e.g. --self-test fn
                                             --self-test space shift

        With no arguments, prints every keyDown, keyUp and flagsChanged event
        until interrupted. Requires Accessibility permission.
        """)
        exit(0)
    case "--self-test":
        i += 1
        guard i < argv.count else { print("--self-test needs a key"); exit(2) }
        selfTestKey = argv[i]
        i += 1
        while i < argv.count, !argv[i].hasPrefix("-") {
            selfTestMods.append(argv[i]); i += 1
        }
        continue
    default:
        print("unknown argument: \(argv[i])"); exit(2)
    }
}

guard Keystroke.isTrusted else {
    print("""
    Accessibility permission is required to tap the event stream.
    System Settings → Privacy & Security → Accessibility → enable your terminal.
    """)
    Keystroke.requestTrust()
    exit(1)
}

final class Observed {
    let lock = NSLock()
    var events: [(type: String, keyCode: Int64, flags: UInt64)] = []

    func record(type: String, keyCode: Int64, flags: UInt64) {
        lock.lock(); defer { lock.unlock() }
        events.append((type, keyCode, flags))
    }

    func snapshot() -> [(type: String, keyCode: Int64, flags: UInt64)] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

let observed = Observed()

func describe(flags: CGEventFlags) -> String {
    var parts: [String] = []
    if flags.contains(.maskSecondaryFn) { parts.append("fn") }
    if flags.contains(.maskControl) { parts.append("ctrl") }
    if flags.contains(.maskAlternate) { parts.append("opt") }
    if flags.contains(.maskShift) { parts.append("shift") }
    if flags.contains(.maskCommand) { parts.append("cmd") }
    if flags.contains(.maskAlphaShift) { parts.append("caps") }
    return parts.isEmpty ? "—" : parts.joined(separator: "+")
}

func keyName(_ code: Int64) -> String {
    Keys.table.first { $0.value == CGKeyCode(code) }?.key ?? "kc\(code)"
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let label: String
    switch type {
    case .keyDown: label = "keyDown"
    case .keyUp: label = "keyUp"
    case .flagsChanged: label = "flagsChanged"
    default: label = "other(\(type.rawValue))"
    }
    observed.record(type: label, keyCode: keyCode, flags: event.flags.rawValue)
    return Unmanaged.passUnretained(event)
}

let mask = (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.keyUp.rawValue)
    | (1 << CGEventType.flagsChanged.rawValue)

guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                  place: .headInsertEventTap,
                                  options: .listenOnly,
                                  eventsOfInterest: CGEventMask(mask),
                                  callback: callback,
                                  userInfo: nil) else {
    print("could not create event tap — Accessibility permission is likely missing")
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

if let key = selfTestKey {
    // Post the chord the same way TriggerMachine would, then report what the
    // tap observed. This is the check that distinguishes "we posted it wrong"
    // from "the target app ignored it".
    guard case .success(let chord) = KeyChord.parse(key: key, mods: selfTestMods) else {
        print("could not parse \(key) \(selfTestMods)")
        exit(1)
    }
    let isModifier = Keys.isModifier(chord.keyCode)
    print("""
    self-test    \(chord.description)
    keycode      \(chord.keyCode)\(isModifier ? "  (a modifier — expect flagsChanged)" : "")
    """)

    let keystroke = Keystroke()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        do {
            try keystroke.press(chord)
            Thread.sleep(forTimeInterval: 0.15)
            try keystroke.release(chord)
        } catch {
            print("post failed: \(error)")
            exit(1)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        let events = observed.snapshot().filter { $0.keyCode == Int64(chord.keyCode) }
        print("\nobserved \(events.count) event(s) for keycode \(chord.keyCode):")
        for e in events {
            print(String(format: "  %-14s flags: %@", (e.type as NSString).utf8String!,
                         describe(flags: CGEventFlags(rawValue: e.flags))))
        }
        print("")
        if events.isEmpty {
            print("✗ nothing observed — the event never reached the system event stream.")
        } else if isModifier {
            let changed = events.filter { $0.type == "flagsChanged" }
            if changed.count >= 2 {
                print("✓ posted as flagsChanged, both directions — this is what a")
                print("  push-to-talk listener watches for.")
            } else {
                print("~ observed, but not as a matched pair of flagsChanged events.")
                print("  A listener expecting a hold may not recognize it.")
            }
        } else {
            print("✓ observed. If the target app still ignores it, the app is")
            print("  filtering synthetic events or listening for a different key.")
        }
        exit(0)
    }
} else {
    print("watching key events — press keys, ctrl-C to stop\n")
    var lastCount = 0
    let printer = DispatchSource.makeTimerSource(queue: .main)
    printer.schedule(deadline: .now(), repeating: 0.05)
    printer.setEventHandler {
        let events = observed.snapshot()
        guard events.count > lastCount else { return }
        for e in events[lastCount...] {
            print(String(format: "  %-14s %-10s flags: %@",
                         (e.type as NSString).utf8String!,
                         (keyName(e.keyCode) as NSString).utf8String!,
                         describe(flags: CGEventFlags(rawValue: e.flags))))
        }
        lastCount = events.count
    }
    printer.resume()
}

CFRunLoopRun()
