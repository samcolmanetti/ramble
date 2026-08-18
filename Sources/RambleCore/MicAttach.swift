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

    /// Run one pass. Safe to call repeatedly — it is a no-op once things are
    /// right, which is what makes it suitable for a timer.
    @discardableResult
    public static func run(micName: String, preferredOutput: String?) -> Outcome {
        let plan = AudioRouting.plan(devices: AudioDevices.all(),
                                     defaultInput: AudioDevices.defaultInput(),
                                     defaultOutput: AudioDevices.defaultOutput(),
                                     micName: micName,
                                     preferredOutput: preferredOutput)

        if plan.connectBluetooth {
            return connect(micName: micName)
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
            return .failed("\(error)")
        }

        switch (claimed, restored) {
        case (nil, nil):            return .alreadyRight
        case (let i?, nil):         return .claimedInput(i)
        case (nil, let o?):         return .restoredOutput(o)
        case (let i?, let o?):      return .claimedAndRestored(input: i, output: o)
        }
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
