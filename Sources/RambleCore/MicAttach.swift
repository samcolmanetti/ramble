import Foundation
#if canImport(IOBluetooth)
import IOBluetooth
#endif

/// Brings the microphone up and keeps the routing right.
///
/// Applies an `AudioRoutingPlan` and, when the mic is not present to CoreAudio
/// at all, asks Bluetooth to open the link to the paired device first.
public enum MicAttach {
    public enum Outcome: Equatable {
        case alreadyRight
        case claimedInput(String)
        case restoredOutput(String)
        case claimedAndRestored(input: String, output: String)
        case connectingBluetooth(String)
        case noPairedDevice
        case failed(String)

        public var description: String {
            switch self {
            case .alreadyRight: return "audio routing already correct"
            case .claimedInput(let n): return "input set to \(n)"
            case .restoredOutput(let n): return "output handed back to \(n)"
            case .claimedAndRestored(let i, let o):
                return "input set to \(i), output handed back to \(o)"
            case .connectingBluetooth(let n): return "connecting \(n) over Bluetooth"
            case .noPairedDevice: return "no paired device to connect"
            case .failed(let why): return "audio routing failed: \(why)"
            }
        }
    }

    /// The result of one pass, including anything worth persisting.
    public struct Result {
        public var outcome: Outcome
        /// The output observed in honest use this pass. Worth writing to the
        /// config when it differs from what is already stored.
        public var learnedOutput: String?
    }

    /// Run one pass. Safe to call repeatedly — it is a no-op once things are
    /// right, which is what makes it suitable for a timer.
    @discardableResult
    public static func run(micName: String,
                           preferredOutput: String?,
                           rememberedOutput: String?) -> Result {
        let plan = AudioRouting.plan(devices: AudioDevices.all(),
                                     defaultInput: AudioDevices.defaultInput(),
                                     defaultOutput: AudioDevices.defaultOutput(),
                                     micName: micName,
                                     preferredOutput: preferredOutput,
                                     rememberedOutput: rememberedOutput)

        if plan.connectBluetooth {
            return Result(outcome: connect(micName: micName),
                          learnedOutput: plan.rememberOutput)
        }

        var claimed: String?
        var restored: String?
        do {
            if let input = plan.claimInput {
                try AudioDevices.setDefaultInput(input)
                claimed = input.name
            }
            if let output = plan.restoreOutput {
                try AudioDevices.setDefaultOutput(output)
                restored = output.name
            }
        } catch {
            return Result(outcome: .failed("\(error)"), learnedOutput: plan.rememberOutput)
        }

        let outcome: Outcome
        switch (claimed, restored) {
        case (nil, nil):            outcome = .alreadyRight
        case (let i?, nil):         outcome = .claimedInput(i)
        case (nil, let o?):         outcome = .restoredOutput(o)
        case (let i?, let o?):      outcome = .claimedAndRestored(input: i, output: o)
        }
        return Result(outcome: outcome, learnedOutput: plan.rememberOutput)
    }

    /// Open the Classic link to the paired mic.
    ///
    /// This connects the whole HFP profile, speaker included — there is no
    /// mic-only connection to ask for. The next pass hands playback back.
    private static func connect(micName: String) -> Outcome {
        #if canImport(IOBluetooth)
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
              let device = paired.first(where: {
                  ($0.name ?? "").localizedCaseInsensitiveContains(micName)
              })
        else { return .noPairedDevice }

        if device.isConnected() {
            // Connected, but CoreAudio has not published it yet. Let the next
            // pass pick it up rather than reconnecting underneath it.
            return .connectingBluetooth(device.name ?? micName)
        }
        let status = device.openConnection()
        guard status == kIOReturnSuccess else {
            return .failed("could not connect \(device.name ?? micName) (IOReturn \(status))")
        }
        return .connectingBluetooth(device.name ?? micName)
        #else
        return .noPairedDevice
        #endif
    }
}
