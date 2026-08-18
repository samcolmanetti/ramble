import CoreBluetooth
import Foundation
import RambleCore

// ramble-sniff — connect to the Instamic in Remote Control Mode and print every
// decoded frame. This is the protocol verification instrument (PLAN.md §5,
// Phase 1); it uses the exact parser the app will ship, so a parser bug shows up
// here rather than masquerading as a protocol mystery later.

let args = Set(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") {
    print("""
    usage: ramble-sniff [options]

      -v, --verbose   log every BLE advertisement seen, not just the Instamic
          --fire      actually send the configured hotkeys (needs Accessibility)
          --config <path>  config file, default ~/.config/ramble/config.json
          --poll <s>  also poll the FCC1 config service every <s> seconds and
                      log any value that changes -- used to locate the battery
                      field and chart real drain
          --scan-only scan and list advertisements, never connect
          --narrow    filter on service FF10 in the scan call itself
                      (faster, but invisible if FF10 isn't in the advert)
      -h, --help      this

    Press the Instamic's record button. Each press should produce
    op 0x03 payload 35 (start) then op 0x03 payload 36 (stop), with the
    gap between them tracking how long you held the take.
    """)
    exit(0)
}

let verbose = args.contains("-v") || args.contains("--verbose")

// --poll <seconds>
var pollInterval: TimeInterval? = nil
do {
    let all = Array(CommandLine.arguments)
    if let i = all.firstIndex(of: "--poll") {
        guard i + 1 < all.count, let v = Double(all[i + 1]), v >= 1 else {
            print("--poll needs an interval in seconds (minimum 1)")
            exit(2)
        }
        pollInterval = v
    }
}
let scanOnly = args.contains("--scan-only")
let narrow = args.contains("--narrow")

// Live monitoring tool: never let stdout block-buffer, or piping into `tee`
// swallows everything until exit.
setvbuf(stdout, nil, _IONBF, 0)

// --fire, --config
let shouldFire = args.contains("--fire")
var configPath = Config.path
do {
    let all = Array(CommandLine.arguments)
    if let i = all.firstIndex(of: "--config"), i + 1 < all.count {
        configPath = URL(fileURLWithPath: (all[i + 1] as NSString).expandingTildeInPath)
    }
}

var machine: TriggerMachine? = nil

let started = Date()
func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

final class Sniffer: BLEClientDelegate {
    /// When the current take started, for measuring 0x35 → 0x36 gaps. The whole
    /// point of the verification run is confirming these track real durations.
    private var takeStart: Date?
    private var takeCount = 0
    private var frameCount = 0

    // A mode that streams audio over GATT would emit hundreds of notifications
    // per second and bury the button events. Above a threshold, roll everything
    // except 0x03 up into a once-per-second summary.
    private var window: [UInt8: (count: Int, bytes: Int)] = [:]
    private var windowStart = Date()
    private var rolledUp = false
    private static let rollupThreshold = 12

    // When scanning began, so a stall can be reported instead of looking like
    // an idle device with nothing to say.
    private(set) var scanningSince: Date?
    private var stallWarningsGiven = 0

    func checkForStall() {
        guard let since = scanningSince,
              Date().timeIntervalSince(since) >= 15 else { return }
        guard stallWarningsGiven < 3 else { return }
        stallWarningsGiven += 1
        print("""

        ⚠️  Still scanning after \(Int(Date().timeIntervalSince(since)))s — nothing matched.
            Most likely causes, in order:
              1. Another BLE central holds the connection. The Instamic allows
                 exactly one — quit the Instamic Remote app, and check for a
                 stray ramble-sniff:  pgrep -fl ramble-sniff
              2. The mic is asleep. Press its button once to wake it.
              3. The mic is off, out of range, or charging-only.
        """)
    }

    func bleStateChanged(_ state: BLEState) {
        sawBluetoothState = true
        switch state {
        case .scanning:
            scanningSince = Date()
            stallWarningsGiven = 0
            print("\(stamp())  scanning\(narrow ? " (FF10 filter)" : "")…")
        case .connecting(let n):
            print("\(stamp())  connecting to \(n)…")
        case .connected(let n):
            scanningSince = nil
            print("\(stamp())  ✓ connected to \(n)")
        case .disconnected(let e):
            scanningSince = nil
            print("\(stamp())  ✗ disconnected\(e.map { ": \($0)" } ?? "")")
        case .poweredOff:
            print("\(stamp())  bluetooth is off")
        case .unauthorized:
            print("""
            \(stamp())  ✗ Bluetooth permission denied.
                        Grant it to your terminal app under
                        System Settings → Privacy & Security → Bluetooth.
            """)
        case .unsupported:
            print("\(stamp())  bluetooth unsupported on this machine")
        }
    }

    func bleDidSee(peripheral: CBPeripheral, advertisement: [String: Any], rssi: NSNumber) {
        let name = (advertisement[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "—"
        let uuids = (advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString).joined(separator: ",") ?? ""
        print("\(stamp())  advert  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) "
            + "rssi \(rssi)  \(uuids)")
    }

    func bleLog(_ message: String) {
        sawBluetoothState = true
        print("\(stamp())  \(message)")
    }

    /// Print a trigger outcome on its own line, for events that aren't tied to
    /// an incoming frame (aborts, timeouts).
    func report(_ outcome: TriggerOutcome) {
        switch outcome {
        case .fired(let phase, let rule, let action):
            print("\(stamp())  → \(phase.rawValue) \(action)  [\(rule)]")
        case .failed(let phase, let reason):
            print("\(stamp())  → \(phase.rawValue) FAILED: \(reason)")
        case .nothingConfigured, .ignored:
            break
        }
    }

    func checkTakeTimeout() {
        guard let machine, let outcome = machine.checkTimeout() else { return }
        print("\(stamp())  ⚠️  take exceeded the safety timeout")
        report(outcome)
    }

    func bleDidReceiveMalformed(raw: [UInt8], error: FrameError) {
        frameCount += 1
        print("\(stamp())  ⚠️  MALFORMED  \(raw.hex)  — \(error)")
    }

    func bleDidReceive(frame: Frame, event: RecordEvent, raw: [UInt8]) {
        frameCount += 1

        var entry = window[frame.opcode] ?? (0, 0)
        entry.count += 1
        entry.bytes += raw.count
        window[frame.opcode] = entry

        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1 {
            let total = window.values.reduce(0) { $0 + $1.count }
            if total >= Self.rollupThreshold {
                if !rolledUp {
                    print("\(stamp())  high frame rate — rolling up all but 0x03")
                    rolledUp = true
                }
                let parts = window.sorted { $0.key < $1.key }.map {
                    String(format: "%02X×%d (%dB)", $0.key, $0.value.count, $0.value.bytes)
                }
                let bytes = window.values.reduce(0) { $0 + $1.bytes }
                print(String(format: "%@  %.0f fps  %.1f kbps  %@", stamp(),
                             Double(total) / elapsed, Double(bytes) * 8 / elapsed / 1000,
                             parts.joined(separator: "  ")))
            } else {
                rolledUp = false
            }
            window.removeAll()
            windowStart = Date()
        }

        // 0x03 is the trigger and always prints, however loud the stream is.
        let isTrigger = frame.opcode == 0x03
        guard isTrigger || !rolledUp else { return }

        var line = String(format: "%@  op %02X  [%@]", stamp(), frame.opcode, frame.payload.hex)

        switch event {
        case .recordStarted:
            takeStart = Date()
            takeCount += 1
            line += "   ▶︎ RECORD START  (take \(takeCount))"
        case .recordStopped:
            if let s = takeStart {
                line += String(format: "   ■ RECORD STOP   held %.2fs", Date().timeIntervalSince(s))
                takeStart = nil
            } else {
                line += "   ■ RECORD STOP   ⚠️ no matching start"
            }
        case .stopPress:
            if let s = takeStart {
                line += String(format: "   ⏹ button press (stop)  held %.2fs", Date().timeIntervalSince(s))
            } else {
                line += "   ⏹ button press (stop)"
            }
        case .startPress:
            line += "   ⏺ button press (start)"
        case .unknownRecordState(let b):
            line += String(format: "   ⚠️ opcode 0x03 with unknown payload 0x%02X", b)
        case .other:
            break
        }

        if let machine {
            switch machine.handle(event) {
            case .fired(let phase, let rule, let action):
                line += "\n\(String(repeating: " ", count: 14))→ \(phase.rawValue) fired \(action)  [\(rule)]"
            case .nothingConfigured(let phase, let rule):
                line += "\n\(String(repeating: " ", count: 14))→ \(phase.rawValue): no action configured for [\(rule)]"
            case .failed(let phase, let reason):
                line += "\n\(String(repeating: " ", count: 14))→ \(phase.rawValue) FAILED: \(reason)"
            case .ignored:
                break
            }
        }
        print(line)
    }

    // Per-characteristic history, so a long unattended run logs only what moved.
    private var lastConfig: [String: [UInt8]] = [:]
    private var configReadCount: [String: Int] = [:]
    private static let heartbeatEvery = 20

    func bleDidReadConfig(uuid: String, value: [UInt8], pushed: Bool) {
        let short = String(uuid.prefix(8))
        let count = (configReadCount[uuid] ?? 0) + 1
        configReadCount[uuid] = count

        let previous = lastConfig[uuid]
        lastConfig[uuid] = value

        guard let previous else {
            print("\(stamp())  cfg \(short)  \(value.hex)   (\(value.count) bytes, first read)")
            return
        }
        if previous == value {
            // Unchanged values still get logged occasionally, so a flat battery
            // trace is distinguishable from polling having silently stopped.
            if count % Self.heartbeatEvery == 0 {
                print("\(stamp())  cfg \(short)  \(value.hex)   (unchanged ×\(Self.heartbeatEvery))")
            }
            return
        }

        var deltas: [String] = []
        for i in 0 ..< max(previous.count, value.count) {
            let a = i < previous.count ? previous[i] : nil
            let b = i < value.count ? value[i] : nil
            if a != b {
                deltas.append(String(format: "[%d] %@→%@", i,
                                     a.map { String(format: "%02X", $0) } ?? "--",
                                     b.map { String(format: "%02X", $0) } ?? "--"))
            }
        }
        let tag = pushed ? "push" : "cfg "
        print("\(stamp())  \(tag)\(short)  \(value.hex)   Δ \(deltas.joined(separator: " "))")
    }

    func summary() {
        print("""

        ── summary ──────────────────────────────────
        ran for      \(String(format: "%.0fs", Date().timeIntervalSince(started)))
        frames       \(frameCount)
        takes        \(takeCount)
        """)
        if !lastConfig.isEmpty {
            print("\n        final FCC1 values:")
            for (uuid, value) in lastConfig.sorted(by: { $0.key < $1.key }) {
                print("          \(String(uuid.prefix(8)))  \(value.hex)")
            }
        }
    }
}

// CBManager.authorization is readable before instantiating a central, so we can
// give a useful message instead of an inscrutable silent no-op.
switch CBManager.authorization {
case .denied, .restricted:
    print("Bluetooth permission is denied for this process.")
    print("System Settings → Privacy & Security → Bluetooth → enable your terminal.")
    exit(1)
case .notDetermined:
    print("Bluetooth permission not yet granted — macOS should prompt shortly.")
default:
    break
}

if shouldFire {
    do {
        let (config, created) = try Config.loadOrCreate(at: configPath)
        if created {
            print("wrote a starter config to \(configPath.path) — edit it to set your hotkeys")
        }
        if !Keystroke.isTrusted {
            print("""

            ⚠️  Accessibility permission is not granted, so no keystroke can be
                posted. macOS attributes this to the app that launched the
                process, so grant it to your terminal under
                System Settings → Privacy & Security → Accessibility.
            """)
            Keystroke.requestTrust()
        }
        machine = TriggerMachine(config: config)
        print("firing enabled — mode: \(config.mode.rawValue), \(config.rules.count) app rules")
        print("  default: start \(config.defaultRule.onStart?.summary ?? "nothing")"
            + " / stop \(config.defaultRule.onStop?.summary ?? "nothing")")
        for rule in config.rules {
            print("  \(rule.name ?? rule.bundleIDs.joined(separator: ",")): "
                + "start \(rule.onStart?.summary ?? "nothing")"
                + " / stop \(rule.onStop?.summary ?? "nothing")")
        }
    } catch {
        print("could not load config at \(configPath.path): \(error)")
        exit(1)
    }
}

// The Instamic accepts exactly one BLE central. A second ramble-sniff -- or the
// Instamic Remote app -- holding the connection makes this process scan forever
// while the button presses go to the other one. Catch the self-inflicted case up
// front, since it is by far the most common during development.
do {
    let check = Process()
    check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    check.arguments = ["-f", "ramble-sniff"]
    let pipe = Pipe()
    check.standardOutput = pipe
    try? check.run()
    check.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let others = output.split(separator: "\n").compactMap { Int32($0) }
        .filter { $0 != getpid() && $0 != getppid() }
    if !others.isEmpty {
        print("""

        ⚠️  Another ramble-sniff is already running (pid \(others.map(String.init).joined(separator: ", "))).
            The Instamic allows only one BLE central, so this process will scan
            forever while that one receives the button presses.

            Stop it first:  kill \(others.map(String.init).joined(separator: " "))
        """)
    }
}

let sniffer = Sniffer()
let client = BLEClient()
client.delegate = sniffer
client.verbose = verbose || scanOnly
client.scanWide = !narrow
client.autoReconnect = !scanOnly
client.connectOnMatch = !scanOnly
client.configPollInterval = pollInterval

print("ramble-sniff — ctrl-C to stop")
if scanOnly {
    print("scan-only: listing advertisements, will not connect")
}
if let pollInterval {
    print("polling FCC1 every \(Int(pollInterval))s (f9c13107 excluded — returns GATT error 133)")
}

// CoreBluetooth reports its state within milliseconds when it can talk to the
// daemon. Silence means the TCC prompt never appeared — which is what happens to
// a bare CLI with no bundle identity for macOS to attribute the request to.
// Without this watchdog the tool just sits there printing nothing, which reads
// like "no devices nearby" rather than "not permitted".
var sawBluetoothState = false
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    guard !sawBluetoothState else { return }
    print("""

    ⚠️  No Bluetooth state callback after 3s — CoreBluetooth never started.

        This almost always means the Bluetooth permission prompt never
        appeared. macOS attributes it to the app that launched this process,
        so run ramble-sniff directly from Terminal, Ghostty, or iTerm rather
        than from an editor, script, or agent, and approve the dialog.

        Then check: System Settings → Privacy & Security → Bluetooth.
    """)
}

let stallTimer = DispatchSource.makeTimerSource(queue: .main)
stallTimer.schedule(deadline: .now() + 15, repeating: 15)
stallTimer.setEventHandler {
    sniffer.checkForStall()
    sniffer.checkTakeTimeout()
}
stallTimer.resume()

let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    // Never exit leaving a modifier pressed. Ctrl-C during a hold-mode take
    // would otherwise wedge the keyboard system-wide.
    if let machine, machine.isRecording {
        sniffer.report(machine.abort(reason: "interrupted"))
    }
    sniffer.summary()
    exit(0)
}
sigint.resume()
signal(SIGINT, SIG_IGN)

RunLoop.main.run()
