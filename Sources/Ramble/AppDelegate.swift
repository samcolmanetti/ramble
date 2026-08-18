import AppKit
import RambleCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var client: BLEClient!
    private var machine: TriggerMachine!
    private var config: Config!
    private var housekeeping: Timer?

    private var connectionState: BLEState = .disconnected(nil)
    private var lastEvent: (label: String, at: Date)?
    private var lastFire: (text: String, at: Date)?
    private var firingEnabled = true
    private var configWatcher: DispatchSourceFileSystemObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()

        loadConfig(announce: false)

        client = BLEClient()
        client.delegate = self
        client.autoReconnect = config.autoReconnect

        // The single most common silent failure: everything connects, frames
        // arrive, and nothing types because Accessibility was never granted.
        // Ask on first launch rather than at first press.
        if !Keystroke.isTrusted { Keystroke.requestTrust() }

        housekeeping = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }

        rebuildMenu()
        watchConfigFile()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never quit leaving a modifier pressed.
        if machine.isRecording { machine.abort(reason: "quitting") }
        client.stop()
    }

    // MARK: - Config

    private func loadConfig(announce: Bool) {
        do {
            let (loaded, created) = try Config.loadOrCreate()
            config = loaded
            if machine == nil {
                machine = TriggerMachine(config: loaded)
            } else {
                machine.config = loaded
            }
            if announce {
                note("config reloaded — \(loaded.rules.count) app rules")
            } else if created {
                note("wrote starter config")
            }
        } catch {
            config = Config.starter()
            if machine == nil { machine = TriggerMachine(config: config) }
            note("config error: \(error.localizedDescription)")
        }
    }

    /// Reload when the file changes on disk, so editing the JSON takes effect
    /// without restarting.
    private func watchConfigFile() {
        configWatcher?.cancel()
        let fd = open(Config.path.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.loadConfig(announce: true)
            self.rebuildMenu()
            // Editors replace rather than write in place, so the descriptor has
            // to be re-established after each change.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.watchConfigFile() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    private func tick() {
        if let outcome = machine.checkTimeout() {
            record(outcome)
        }
        rebuildMenu()
    }

    // MARK: - Menu

    private var stateDescription: String {
        switch connectionState {
        case .connected(let name): return machine.isRecording ? "Recording — \(name)" : "Connected — \(name)"
        case .connecting(let name): return "Connecting to \(name)…"
        case .scanning: return "Scanning for Instamic…"
        case .disconnected: return "Disconnected"
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission denied"
        case .unsupported: return "Bluetooth unsupported"
        }
    }

    private var symbolName: String {
        switch connectionState {
        case .connected: return machine.isRecording ? "mic.fill" : "mic"
        case .connecting, .scanning: return "dot.radiowaves.left.and.right"
        default: return "mic.slash"
        }
    }

    private func rebuildMenu() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Ramble")
            button.image?.isTemplate = true
            button.appearsDisabled = !firingEnabled
        }

        let menu = NSMenu()
        menu.addItem(disabledItem(stateDescription))

        if let take = machine.takeDuration {
            menu.addItem(disabledItem(String(format: "   take running %.0fs", take)))
        }

        // Which rule the *current* frontmost app would use. Answers "why didn't
        // it do what I expected" without opening the config file.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let rule = config.rule(for: frontmost?.bundleIdentifier)
        menu.addItem(.separator())
        menu.addItem(disabledItem("Frontmost: \(frontmost?.localizedName ?? "—")"))
        menu.addItem(disabledItem("   rule: \(rule.name ?? "default")"))
        menu.addItem(disabledItem("   start \(rule.onStart?.summary ?? "nothing")"
            + " · stop \(rule.onStop?.summary ?? "nothing")"
            + " · \((rule.mode ?? config.mode).rawValue)"))

        menu.addItem(.separator())
        menu.addItem(disabledItem(lastEvent.map { "Last event: \($0.label) \(ago($0.at))" }
            ?? "Last event: none yet"))
        menu.addItem(disabledItem(lastFire.map { "Last fire: \($0.text) \(ago($0.at))" }
            ?? "Last fire: none yet"))

        if !Keystroke.isTrusted {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: "⚠️ Accessibility not granted — open Settings",
                                  action: #selector(openAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        let toggle = NSMenuItem(title: firingEnabled ? "Firing enabled" : "Firing paused",
                                action: #selector(toggleFiring), keyEquivalent: "")
        toggle.target = self
        toggle.state = firingEnabled ? .on : .off
        menu.addItem(toggle)

        for (title, selector) in [("Edit config…", #selector(openConfig)),
                                  ("Reload config", #selector(reloadConfig)),
                                  ("Reconnect", #selector(reconnect))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ramble", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "(\(seconds)s ago)" }
        if seconds < 3600 { return "(\(seconds / 60)m ago)" }
        return "(\(seconds / 3600)h ago)"
    }

    private func note(_ text: String) {
        lastFire = (text, Date())
    }

    private func record(_ outcome: TriggerOutcome) {
        switch outcome {
        case .fired(let phase, let rule, let action):
            lastFire = ("\(phase.rawValue) \(action) [\(rule)]", Date())
        case .nothingConfigured(let phase, let rule):
            lastFire = ("\(phase.rawValue): nothing configured for \(rule)", Date())
        case .failed(let phase, let reason):
            lastFire = ("\(phase.rawValue) FAILED: \(reason)", Date())
        case .ignored:
            break
        }
    }

    // MARK: - Actions

    @objc private func toggleFiring() {
        firingEnabled.toggle()
        if !firingEnabled, machine.isRecording {
            record(machine.abort(reason: "firing paused"))
        }
        rebuildMenu()
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(Config.path)
    }

    @objc private func reloadConfig() {
        loadConfig(announce: true)
        rebuildMenu()
    }

    @objc private func reconnect() {
        if machine.isRecording { record(machine.abort(reason: "manual reconnect")) }
        client.stop()
        client.start()
        rebuildMenu()
    }

    @objc private func openAccessibility() {
        Keystroke.requestTrust()
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

extension AppDelegate: BLEClientDelegate {
    func bleStateChanged(_ state: BLEState) {
        connectionState = state
        if case .disconnected = state, machine.isRecording {
            // The take is orphaned; in hold mode a modifier is physically down.
            record(machine.abort(reason: "device disconnected"))
        }
        rebuildMenu()
    }

    func bleDidReceive(frame: Frame, event: RecordEvent, raw: [UInt8]) {
        lastEvent = (event.label, Date())
        guard firingEnabled else {
            rebuildMenu()
            return
        }
        record(machine.handle(event))
        rebuildMenu()
    }

    func bleLog(_ message: String) {
        NSLog("[ramble] %@", message)
    }
}
