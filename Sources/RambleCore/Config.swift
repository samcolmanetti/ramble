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

    public init(name: String? = nil, bundleIDs: [String],
                onStart: Action? = nil, onStop: Action? = nil) {
        self.name = name
        self.bundleIDs = bundleIDs
        self.onStart = onStart
        self.onStop = onStop
    }

    public func matches(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
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
    public var defaultRule: Rule
    public var rules: [Rule]

    public init(mode: TriggerMode = .toggle,
                autoReconnect: Bool = true,
                defaultRule: Rule,
                rules: [Rule] = []) {
        self.mode = mode
        self.autoReconnect = autoReconnect
        self.defaultRule = defaultRule
        self.rules = rules
    }

    /// First matching rule wins; otherwise the default.
    public func rule(for bundleID: String?) -> Rule {
        rules.first { $0.matches(bundleID: bundleID) } ?? defaultRule
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
            defaultRule: Rule(
                name: "Wispr Flow (default)",
                bundleIDs: [],
                onStart: Action(key: "d", mods: ["ctrl", "opt", "cmd"]),
                onStop: Action(key: "d", mods: ["ctrl", "opt", "cmd"])
            ),
            rules: [
                // Matches ~/.claude/keybindings.json, which rebinds
                // voice:pushToTalk off bare Space. Keep the two in sync — if the
                // keybinding moves, this must move with it.
                Rule(name: "Claude Code voice (⇧Space)",
                     bundleIDs: ["com.mitchellh.ghostty", "com.googlecode.iterm2"],
                     onStart: Action(key: "space", mods: ["shift"]),
                     onStop: Action(key: "space", mods: ["shift"])),
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
