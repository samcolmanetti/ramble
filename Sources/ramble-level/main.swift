import AVFoundation
import Foundation
import RambleCore

// ramble-level — answer the one question the whole approach rests on: does a
// whisper, at the volume you'd actually use in an office, register at a usable
// level through the Instamic's 16 kHz HFP path?
//
// A bare level meter isn't enough to answer that. What matters is the *margin*
// between your whisper and the room, so this measures the noise floor first,
// then the whisper, and reports the difference.

setvbuf(stdout, nil, _IONBF, 0)

var deviceQuery: String? = nil
var floorSeconds = 4.0
var speechSeconds = 6.0
var listOnly = false

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "-h", "--help":
        print("""
        usage: ramble-level [options]

          -d, --device <substring>   input device to meter (default: system default input)
          -l, --list                 list input devices and exit
              --floor <seconds>      silence measurement, default 4
              --speech <seconds>     whisper measurement, default 6
          -h, --help                 this
        """)
        exit(0)
    case "-d", "--device": deviceQuery = argIterator.next()
    case "-l", "--list": listOnly = true
    case "--floor": floorSeconds = Double(argIterator.next() ?? "") ?? floorSeconds
    case "--speech": speechSeconds = Double(argIterator.next() ?? "") ?? speechSeconds
    default: print("unknown argument: \(arg)"); exit(2)
    }
}

let inputs = AudioDevices.inputs()
let defaultInput = AudioDevices.defaultInput()

if listOnly || inputs.isEmpty {
    print("input devices:")
    for d in inputs {
        let marker = d.id == defaultInput?.id ? " ← system default" : ""
        print(String(format: "  %-28s %2d ch  %6.0f Hz%@", (d.name as NSString).utf8String!,
                     d.inputChannels, d.sampleRate, marker))
    }
    exit(inputs.isEmpty ? 1 : 0)
}

let device: AudioDevice
if let query = deviceQuery {
    guard let match = inputs.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) else {
        print("no input device matching \"\(query)\". Available:")
        for d in inputs { print("  \(d.name)") }
        exit(1)
    }
    device = match
} else {
    guard let d = defaultInput else { print("no default input device"); exit(1) }
    device = d
}

// Microphone access is a separate TCC grant from Bluetooth, and fails the same
// silent way for a CLI with no bundle identity.
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .denied, .restricted:
    print("""
    Microphone permission is denied for this process.
    System Settings → Privacy & Security → Microphone → enable your terminal.
    """)
    exit(1)
case .notDetermined:
    print("Requesting microphone access — approve the prompt…")
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in sem.signal() }
    if sem.wait(timeout: .now() + 30) == .timedOut {
        print("""

        No response to the microphone prompt after 30s. macOS attributes it to
        the app that launched this process, so run ramble-level directly from
        Terminal, Ghostty, or iTerm rather than from an editor or agent.
        """)
        exit(1)
    }
default: break
}

final class Meter {
    private let lock = NSLock()
    private var stats = LevelStats()
    private var live: Float = -100

    func add(rms: Float, peak: Float) {
        lock.lock(); defer { lock.unlock() }
        stats.add(rms: rms, peak: peak)
        live = rms
    }

    func snapshot() -> (LevelStats, Float) {
        lock.lock(); defer { lock.unlock() }
        return (stats, live)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        stats = LevelStats()
    }
}

let engine = AVAudioEngine()
let meter = Meter()

do {
    try AudioDevices.setInput(device, on: engine)
} catch {
    print("could not select \(device.name): \(error)")
    exit(1)
}

let format = engine.inputNode.inputFormat(forBus: 0)
guard format.sampleRate > 0, format.channelCount > 0 else {
    print("""
    \(device.name) reports a zero format — the device is present but not
    streaming. If this is the Instamic over Bluetooth, the HFP audio link may
    not be established; try selecting it as the system input first.
    """)
    exit(1)
}

print("""
device      \(device.name)
format      \(Int(format.sampleRate)) Hz, \(format.channelCount) ch
""")
if abs(format.sampleRate - 16000) < 1 {
    print("            16 kHz is Whisper's native input rate — not a limitation here")
}
print("")

engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
    guard let channels = buffer.floatChannelData else { return }
    let count = Int(buffer.frameLength)
    guard count > 0 else { return }
    // Mono-sum so a stereo device is measured the same way as a mono one.
    var rmsAccum: Float = 0
    var peakAccum: Float = -100
    for ch in 0 ..< Int(buffer.format.channelCount) {
        let (rms, peak) = LevelStats.measure(channels[ch], count: count)
        rmsAccum += powf(10, rms / 20)
        peakAccum = max(peakAccum, peak)
    }
    let combined = LevelStats.dbfs(rmsAccum / Float(buffer.format.channelCount))
    meter.add(rms: combined, peak: peakAccum)
}

do {
    try engine.start()
} catch {
    print("could not start audio engine: \(error.localizedDescription)")
    exit(1)
}

// A repainting bar is only meaningful on a terminal; piped into a file or a
// tool, carriage returns just concatenate into one unreadable line.
let interactive = isatty(fileno(stdout)) == 1

/// Run one measurement phase, printing a live bar, and return its stats.
func phase(_ title: String, _ instruction: String, seconds: Double) -> LevelStats {
    print("\(title)  \(instruction)")
    meter.reset()
    let deadline = Date().addingTimeInterval(seconds)
    var lastLogged = Date.distantPast
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.08)
        let (_, live) = meter.snapshot()
        let remaining = max(0, deadline.timeIntervalSinceNow)
        if interactive {
            print(String(format: "\r  %@ %6.1f dBFS   %.0fs ",
                         LevelStats.bar(live), live, remaining), terminator: "")
        } else if Date().timeIntervalSince(lastLogged) >= 1 {
            print(String(format: "  %@ %6.1f dBFS", LevelStats.bar(live), live))
            lastLogged = Date()
        }
    }
    let (stats, _) = meter.snapshot()
    print(String(format: "%@  done  peak %.1f  mean %.1f dBFS      ",
                 interactive ? "\r" : "", stats.peak, stats.mean))
    return stats
}

// Let the HFP link settle before measuring. Observed: the level decays from
// about -39 to -55 dBFS over the first ~1.5 s as the SCO link and whatever
// noise suppression macOS applies converge. Measuring through that transient
// inflates the noise floor and wrecks the SNR figure.
print("settling HFP link…")
Thread.sleep(forTimeInterval: 2.0)

let noise = phase("[1/2]", "Stay silent — measuring the room…", seconds: floorSeconds)
print("")
let speech = phase("[2/2]", "Whisper now, at the volume you'd use in the office…", seconds: speechSeconds)

engine.stop()
engine.inputNode.removeTap(onBus: 0)

let floorLevel = noise.p95      // the loud end of "silence" is the real floor
let speechLevel = speech.p95    // the sustained level of the whisper
let snr = speechLevel - floorLevel

print("""

── result ───────────────────────────────────
device            \(device.name) @ \(Int(format.sampleRate)) Hz
room noise floor  \(String(format: "%6.1f dBFS", floorLevel))
whisper level     \(String(format: "%6.1f dBFS", speechLevel))  (peak \(String(format: "%.1f", speech.peak)))
signal-to-noise   \(String(format: "%6.1f dB", snr))
""")

// Thresholds: speech recognition degrades sharply below ~15 dB SNR, is
// comfortable above ~20 dB, and clipping starts to matter above about -3 dBFS.
var verdict: [String] = []
if snr >= 20 {
    verdict.append("✓ SNR \(String(format: "%.0f", snr)) dB — comfortable margin for transcription.")
} else if snr >= 12 {
    verdict.append("~ SNR \(String(format: "%.0f", snr)) dB — workable, but marginal in a louder room.")
    verdict.append("  Try moving the mic closer to your mouth and re-running.")
} else {
    verdict.append("✗ SNR \(String(format: "%.0f", snr)) dB — too little margin; transcription will suffer.")
    verdict.append("  Check mic placement and that the Instamic really is the selected input.")
}
if speech.peak > -3 {
    verdict.append("⚠ Peaks near full scale — clipping risk. Lower the gain.")
}
if speechLevel < -45 {
    verdict.append("⚠ Whisper is very quiet in absolute terms; gain may need raising.")
}
print(verdict.joined(separator: "\n"))
