import CoreGraphics
import Foundation

#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// A key plus modifiers, e.g. `⌃⌥⌘D` or a bare `space`.
public struct KeyChord: Equatable {
    public let keyCode: CGKeyCode
    public let flags: CGEventFlags
    public let description: String

    public init(keyCode: CGKeyCode, flags: CGEventFlags, description: String) {
        self.keyCode = keyCode
        self.flags = flags
        self.description = description
    }

    /// Parse a key name and modifier list into a postable chord.
    public static func parse(key: String, mods: [String]) -> Result<KeyChord, KeystrokeError> {
        guard let code = Keys.code(for: key) else {
            return .failure(.unknownKey(key))
        }
        var flags: CGEventFlags = []
        for mod in mods {
            switch mod.lowercased() {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "shift", "⇧": flags.insert(.maskShift)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default: return .failure(.unknownModifier(mod))
            }
        }
        var parts: [String] = []
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if flags.contains(.maskCommand) { parts.append("⌘") }
        return .success(KeyChord(keyCode: code, flags: flags,
                                 description: parts.joined() + key.uppercased()))
    }
}

public enum KeystrokeError: Error, Equatable, CustomStringConvertible {
    case unknownKey(String)
    case unknownModifier(String)
    case notTrusted

    public var description: String {
        switch self {
        case .unknownKey(let k): return "unknown key \"\(k)\""
        case .unknownModifier(let m): return "unknown modifier \"\(m)\""
        case .notTrusted: return "Accessibility permission not granted"
        }
    }
}

/// macOS virtual key codes. These are positional (they follow the physical key,
/// not the character it produces), which is why they're a fixed table rather
/// than anything derived from the current keyboard layout.
public enum Keys {
    static let table: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
        "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
        "backspace": 51, "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79,
        "f19": 80, "f20": 90,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    ]

    public static func code(for name: String) -> CGKeyCode? {
        table[name.lowercased()]
    }

    public static var known: [String] { table.keys.sorted() }
}

/// Anything that can emit key events. Injected into `TriggerMachine` so its
/// logic is testable without an Accessibility grant — the real emitter throws
/// `notTrusted` in any process that lacks one, which would otherwise make every
/// state-machine test fail for reasons unrelated to the state machine.
public protocol KeystrokeEmitting {
    func tap(_ chord: KeyChord) throws
    func press(_ chord: KeyChord) throws
    func release(_ chord: KeyChord) throws
}

/// Posts synthetic keyboard events to the system.
public struct Keystroke: KeystrokeEmitting {
    /// Whether this process may post synthetic events.
    ///
    /// Checked before every fire, not just at launch: the grant can be revoked
    /// while running, and a silently-swallowed keystroke is the single most
    /// confusing failure mode this app has.
    public static var isTrusted: Bool {
        #if canImport(ApplicationServices)
        return AXIsProcessTrusted()
        #else
        return false
        #endif
    }

    /// Ask macOS to show the Accessibility prompt.
    @discardableResult
    public static func requestTrust() -> Bool {
        #if canImport(ApplicationServices)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
        #else
        return false
        #endif
    }

    public init() {}

    private func post(_ chord: KeyChord, down: Bool) {
        // .hidSystemState makes the event look like it came from real hardware,
        // which some apps check for.
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: chord.keyCode,
                                  keyDown: down) else { return }
        event.flags = chord.flags
        event.post(tap: .cghidEventTap)
    }

    /// Full press and release — the normal case.
    public func tap(_ chord: KeyChord) throws {
        guard Keystroke.isTrusted else { throw KeystrokeError.notTrusted }
        post(chord, down: true)
        post(chord, down: false)
    }

    /// Press and hold. Only used in push-to-talk mode; must be paired with
    /// `release`, or the key stays down system-wide.
    public func press(_ chord: KeyChord) throws {
        guard Keystroke.isTrusted else { throw KeystrokeError.notTrusted }
        post(chord, down: true)
    }

    public func release(_ chord: KeyChord) throws {
        guard Keystroke.isTrusted else { throw KeystrokeError.notTrusted }
        post(chord, down: false)
    }
}
