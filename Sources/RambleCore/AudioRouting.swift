import Foundation

/// What needs to change to have the mic as the system input and nothing else
/// disturbed.
public struct AudioRoutingPlan: Equatable {
    /// Make this the system input.
    public var claimInput: AudioDevice?
    /// Hand playback back to this. Set only when the mic has taken it.
    public var restoreOutput: AudioDevice?
    /// The mic is not present to CoreAudio at all, so the Bluetooth link has to
    /// come up before any of the above is possible.
    public var connectBluetooth: Bool

    public var isNoOp: Bool {
        claimInput == nil && restoreOutput == nil && !connectBluetooth
    }
}

/// Decides audio routing. Pure, so the rules can be tested without a sound card.
///
/// The problem this solves: a Bluetooth microphone is an HFP device, and HFP is
/// a *headset* profile. There is no way to connect only the microphone half —
/// bringing the link up for the mic unavoidably offers macOS a speaker too, and
/// macOS takes it, dropping all system audio to 16 kHz mono. So the mic is
/// claimed for input and playback is immediately handed back.
public enum AudioRouting {
    public static func plan(devices: [AudioDevice],
                            defaultInput: AudioDevice?,
                            defaultOutput: AudioDevice?,
                            micName: String,
                            preferredOutput: String?) -> AudioRoutingPlan {
        func isMic(_ device: AudioDevice) -> Bool {
            device.name.localizedCaseInsensitiveContains(micName)
        }

        guard let mic = devices.first(where: { isMic($0) && $0.isInput }) else {
            // Nothing to route yet. The link is down, or the mic is off.
            return AudioRoutingPlan(claimInput: nil, restoreOutput: nil,
                                    connectBluetooth: true)
        }

        let claim = (defaultInput?.id == mic.id) ? nil : mic

        // Only act on output when the mic actually holds it. Otherwise leave the
        // user's choice alone — they may well want the Bluetooth speaker.
        var restore: AudioDevice?
        if let out = defaultOutput, isMic(out) {
            let candidates = devices.filter { $0.isOutput && !isMic($0) }
            restore = preferredOutput.flatMap { want in
                candidates.first { $0.name.localizedCaseInsensitiveContains(want) }
            } ?? candidates.first
        }

        return AudioRoutingPlan(claimInput: claim, restoreOutput: restore,
                                connectBluetooth: false)
    }
}
