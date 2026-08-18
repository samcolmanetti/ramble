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
let scanOnly = args.contains("--scan-only")
let narrow = args.contains("--narrow")

// Live monitoring tool: never let stdout block-buffer, or piping into `tee`
// swallows everything until exit.
setvbuf(stdout, nil, _IONBF, 0)

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

    func bleStateChanged(_ state: BLEState) {
        sawBluetoothState = true
        switch state {
        case .scanning:
            print("\(stamp())  scanning\(narrow ? " (FF10 filter)" : "")…")
        case .connecting(let n):
            print("\(stamp())  connecting to \(n)…")
        case .connected(let n):
            print("\(stamp())  ✓ connected to \(n)")
        case .disconnected(let e):
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
        case .unknownRecordState(let b):
            line += String(format: "   ⚠️ opcode 0x03 with unknown payload 0x%02X", b)
        case .other:
            break
        }
        print(line)
    }

    func summary() {
        print("""

        ── summary ──────────────────────────────────
        ran for      \(String(format: "%.0fs", Date().timeIntervalSince(started)))
        frames       \(frameCount)
        takes        \(takeCount)
        """)
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

let sniffer = Sniffer()
let client = BLEClient()
client.delegate = sniffer
client.verbose = verbose || scanOnly
client.scanWide = !narrow
client.autoReconnect = !scanOnly
client.connectOnMatch = !scanOnly

print("ramble-sniff — ctrl-C to stop")
if scanOnly {
    print("scan-only: listing advertisements, will not connect")
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

let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    sniffer.summary()
    exit(0)
}
sigint.resume()
signal(SIGINT, SIG_IGN)

RunLoop.main.run()
