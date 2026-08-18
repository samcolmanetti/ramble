import AppKit
import RambleCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
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

        applyMenuBarVisibility()
        watchConfigFile()
    }

    /// Create or tear down the status item to match the config.
    ///
    /// The icon is a window onto Ramble, not Ramble itself — the BLE client and
    /// the trigger machine run identically either way.
    private func applyMenuBarVisibility() {
        if config.showMenuBarIcon {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
            rebuildMenu()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
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
            self.applyMenuBarVisibility()
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
        guard let statusItem else { return }
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

        // Pick which dictation service handles apps without a specific rule.
        menu.addItem(.separator())
        let targetItem = NSMenuItem(title: "Dictation app", action: nil, keyEquivalent: "")
        let targetMenu = NSMenu()
        for target in config.targets {
            guard let name = target.name else { continue }
            let item = NSMenuItem(title: name, action: #selector(selectTarget(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = (name == config.activeRule.name) ? .on : .off
            // Show what it will actually send, so an unconfigured target is
            // obvious before you switch to it and wonder why nothing happens.
            let summary = target.onStart?.summary ?? "not configured"
            item.toolTip = "start \(summary) · \((target.mode ?? config.mode).rawValue)"
            if target.onStart == nil { item.title = "\(name)  (not configured)" }
            targetMenu.addItem(item)
        }
        targetItem.submenu = targetMenu
        menu.addItem(targetItem)
        menu.addItem(disabledItem("   \(config.activeRule.name ?? "none"): "
            + "\(config.activeRule.onStart?.summary ?? "nothing")"))

        // Which rule the *current* frontmost app would use. Answers "why didn't
        // it do what I expected" without opening the config file. A per-app rule
        // overrides the chosen target, so this can differ from the line above.
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
        if machine.runawayTripped {
            menu.addItem(.separator())
            menu.addItem(disabledItem("⚠️ Runaway guard tripped — too many starts"))
            menu.addItem(disabledItem("   check the mic's battery and button"))
        }

        let toggle = NSMenuItem(title: firingEnabled ? "Firing enabled" : "Firing paused",
                                action: #selector(toggleFiring), keyEquivalent: "")
        toggle.target = self
        toggle.state = firingEnabled ? .on : .off
        menu.addItem(toggle)

        for (title, selector) in [("Open event log…", #selector(openLog)),
                                  ("Edit config…", #selector(openConfig)),
                                  ("Reload config", #selector(reloadConfig)),
                                  ("Reconnect", #selector(reconnect)),
                                  ("Hide menu bar icon…", #selector(hideMenuBarIcon))] {
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
        case .ignored(let reason):
            EventLog.shared.write("  ignored: \(reason)")
        default:
            EventLog.shared.write("  \(outcome)")
        }
        switch outcome {
        case .fired(let phase, let rule, let action):
            lastFire = ("\(phase.rawValue) \(action) [\(rule)]", Date())
        case .nothingConfigured(let phase, let rule):
            lastFire = ("\(phase.rawValue): nothing configured for \(rule)", Date())
        case .failed(let phase, let reason):
            lastFire = ("\(phase.rawValue) FAILED: \(reason)", Date())
            // A tripped runaway guard must be visible, not just logged.
            if machine.runawayTripped { firingEnabled = false }
        case .ignored:
            break
        }
    }

    // MARK: - Actions

    @objc private func toggleFiring() {
        firingEnabled.toggle()
        if firingEnabled { machine.reset() }   // clears a tripped runaway guard
        if !firingEnabled, machine.isRecording {
            record(machine.abort(reason: "firing paused"))
        }
        rebuildMenu()
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        // Switching mid-take would leave a held key stranded under the old rule.
        if machine.isRecording { record(machine.abort(reason: "switched dictation app")) }
        config.selectTarget(named: name)
        machine.config = config
        try? config.save()          // persist, so the choice survives a restart
        EventLog.shared.write("dictation app switched to \(name)")
        note("switched to \(name)")
        rebuildMenu()
    }

    @objc private func hideMenuBarIcon() {
        // Hiding the only visible affordance is a one-way door unless the way
        // back is spelled out first — and it has to be spelled out *before* the
        // icon disappears, not after.
        let alert = NSAlert()
        alert.messageText = "Hide the Ramble icon?"
        alert.informativeText = """
        Ramble keeps running and the mic button keeps working.

        To bring the icon back, set "showMenuBarIcon": true in
        \(Config.path.path)

        The file is watched, so the icon reappears as soon as you save.
        """
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        config.showMenuBarIcon = false
        try? config.save()
        EventLog.shared.write("menu bar icon hidden; set showMenuBarIcon true to restore")
        applyMenuBarVisibility()
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(Config.path)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(EventLog.path)
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
        // Every frame is logged, whether or not it triggers anything. A
        // spurious keystroke and a spurious frame from the device look
        // identical from the outside; only the raw stream separates them.
        EventLog.shared.write(String(format: "frame  op %02X [%@]  %@",
                                     frame.opcode, frame.payload.hex, event.label))
        guard firingEnabled else {
            rebuildMenu()
            return
        }
        record(machine.handle(event))
        rebuildMenu()
    }

    func bleLog(_ message: String) {
        NSLog("[ramble] %@", message)
        EventLog.shared.write(message)
    }
}
