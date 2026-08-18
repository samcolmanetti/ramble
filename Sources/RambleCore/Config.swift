import Foundation

/// What to do when a trigger fires. All fields optional: an action with none of
/// them set means "do nothing in this app", which is how you blacklist a
/// password manager or a terminal you don't dictate into.
public struct Action: Codable, Equatable {
    public var key: String?
    public var mods: [String]?
    public var shell: String?

    public init(key: String? = nil, mods: [String]? = nil, shell: String? = nil) {
        self.key = key
        self.mods = mods
        self.shell = shell
    }

    public var isEmpty: Bool { key == nil && shell == nil }

    public func chord() -> Result<KeyChord, KeystrokeError>? {
        guard let key else { return nil }
        return KeyChord.parse(key: key, mods: mods ?? [])
    }

    public var summary: String {
        if let shell { return "shell: \(shell)" }
        guard let key else { return "nothing" }
        switch KeyChord.parse(key: key, mods: mods ?? []) {
        case .success(let c): return c.description
        case .failure(let e): return "invalid (\(e))"
        }
    }
}

public struct Rule: Codable, Equatable {
    public var name: String?
    public var bundleIDs: [String]
    public var onStart: Action?
    public var onStop: Action?
    /// Overrides the global mode for this rule. Necessary because different
    /// targets want opposite semantics: Wispr Flow's push-to-talk is a held Fn,
    /// while Claude Code's voice key is a discrete tap. A single global mode
    /// cannot serve both.
    public var mode: TriggerMode?

    public init(name: String? = nil, bundleIDs: [String] = [],
                onStart: Action? = nil, onStop: Action? = nil,
                mode: TriggerMode? = nil) {
        self.name = name
        self.bundleIDs = bundleIDs
        self.onStart = onStart
        self.onStop = onStop
        self.mode = mode
    }

    public func matches(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// `bundleIDs` is meaningless for a named target, so let it be omitted.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        onStart = try c.decodeIfPresent(Action.self, forKey: .onStart)
        onStop = try c.decodeIfPresent(Action.self, forKey: .onStop)
        mode = try c.decodeIfPresent(TriggerMode.self, forKey: .mode)
    }
}

public enum TriggerMode: String, Codable {
    /// Fire a full key tap on both start and stop. The Instamic's button is
    /// itself a toggle, so this is the natural fit and the default.
    case toggle
    /// Hold the key down between start and stop. Riskier: some apps ignore
    /// multi-second synthetic holds, and a crash mid-hold leaves a stuck key.
    case hold
}

public struct Config: Codable, Equatable {
    public var mode: TriggerMode
    public var autoReconnect: Bool
    /// Show the status item. Ramble keeps working when this is false — the icon
    /// is a window onto it, not the thing itself. Set it back to true here (the
    /// file is watched) to bring the icon back.
    public var showMenuBarIcon: Bool
    /// Named dictation services, switchable from the menu bar. Whichever one is
    /// active handles any app without a specific rule.
    public var targets: [Rule]
    /// Name of the active entry in `targets`.
    public var activeTarget: String?
    /// Per-app overrides. These beat the active target, so "Claude Code voice in
    /// the terminal, whatever I picked everywhere else" works without switching.
    public var rules: [Rule]
    /// Fallback for configs written before `targets` existed.
    public var defaultRule: Rule?

    public init(mode: TriggerMode = .toggle,
                autoReconnect: Bool = true,
                showMenuBarIcon: Bool = true,
                targets: [Rule] = [],
                activeTarget: String? = nil,
                rules: [Rule] = [],
                defaultRule: Rule? = nil) {
        self.mode = mode
        self.autoReconnect = autoReconnect
        self.showMenuBarIcon = showMenuBarIcon
        self.targets = targets
        self.activeTarget = activeTarget
        self.rules = rules
        self.defaultRule = defaultRule
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(TriggerMode.self, forKey: .mode) ?? .toggle
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        targets = try c.decodeIfPresent([Rule].self, forKey: .targets) ?? []
        activeTarget = try c.decodeIfPresent(String.self, forKey: .activeTarget)
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        defaultRule = try c.decodeIfPresent(Rule.self, forKey: .defaultRule)
    }

    /// The target currently handling apps without a specific rule.
    public var activeRule: Rule {
        if let activeTarget, let match = targets.first(where: { $0.name == activeTarget }) {
            return match
        }
        return targets.first ?? defaultRule ?? Rule(name: "none", bundleIDs: [])
    }

    /// First matching per-app rule wins; otherwise the active target.
    public func rule(for bundleID: String?) -> Rule {
        rules.first { $0.matches(bundleID: bundleID) } ?? activeRule
    }

    public mutating func selectTarget(named name: String) {
        guard targets.contains(where: { $0.name == name }) else { return }
        activeTarget = name
    }

    public static var path: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ramble", isDirectory: true)
        return base.appendingPathComponent("config.json")
    }

    /// Bundle IDs below were read off this machine. Anything with a `nil` action
    /// does nothing until the user fills in the real hotkey — better than
    /// shipping a guess that silently types the wrong thing.
    public static func starter() -> Config {
        Config(
            mode: .toggle,
            autoReconnect: true,
            targets: [
                // Wispr Flow's push-to-talk is a bare Fn/Globe hold — read out
                // of its own config.json, where prefs.user.shortcuts maps "63"
                // to "ptt" and 63 is kVK_Function. Hold mode presses Fn on the
                // button press and releases it on the next one.
                Rule(name: "Wispr Flow",
                     bundleIDs: [],
                     onStart: Action(key: "fn"),
                     onStop: Action(key: "fn"),
                     mode: .hold),
                // Placeholders: no action until you set the real hotkey, which
                // beats guessing and silently typing something wrong.
                Rule(name: "MacWhisper", bundleIDs: [], onStart: nil, onStop: nil),
                Rule(name: "superwhisper", bundleIDs: [], onStart: nil, onStop: nil),
                Rule(name: "Off", bundleIDs: [], onStart: nil, onStop: nil),
            ],
            activeTarget: "Wispr Flow",
            rules: [
                // Claude Code's voice:pushToTalk default, in tap mode: one tap
                // starts, the next sends.
                //
                // Deliberately a *bare* space. Terminals send 0x20 for both
                // Space and Shift+Space unless the Kitty keyboard protocol's
                // disambiguation mode is active, which it is not in every
                // state — a Shift+Space binding here fired only intermittently.
                // Modifiers are unreliable through a terminal generally: Ghostty
                // was observed stripping Cmd entirely on the way to the TUI.
                Rule(name: "Claude Code voice (tap Space)",
                     bundleIDs: ["com.mitchellh.ghostty", "com.googlecode.iterm2"],
                     onStart: Action(key: "space"),
                     onStop: Action(key: "space"),
                     mode: .toggle),
                Rule(name: "Codex voice — set the key you use",
                     bundleIDs: ["com.openai.codex"],
                     onStart: nil, onStop: nil),
                Rule(name: "Editors — MacWhisper or Wispr Flow, set the key",
                     bundleIDs: ["dev.zed.Zed", "com.microsoft.VSCode"],
                     onStart: nil, onStop: nil),
            ]
        )
    }

    public static func load(from url: URL = Config.path) throws -> Config {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    public func save(to url: URL = Config.path) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Load, or write and return the starter config if none exists yet.
    public static func loadOrCreate(at url: URL = Config.path) throws -> (Config, Bool) {
        if FileManager.default.fileExists(atPath: url.path) {
            return (try load(from: url), false)
        }
        let config = starter()
        try config.save(to: url)
        return (config, true)
    }
}
