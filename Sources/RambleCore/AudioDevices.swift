import AVFoundation
import CoreAudio
import Foundation

/// A CoreAudio input device.
public struct AudioDevice {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let inputChannels: Int
    public let sampleRate: Double

    public var isInput: Bool { inputChannels > 0 }
}

public enum AudioDevices {
    private static func property<T>(_ objectID: AudioObjectID,
                                    _ selector: AudioObjectPropertySelector,
                                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                    default fallback: T) -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        var value = fallback
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : fallback
    }

    private static func stringProperty(_ objectID: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return "" }
        return value as String
    }

    private static func inputChannelCount(_ objectID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Every device the system knows about, inputs and outputs alike.
    public static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.map { id in
            AudioDevice(
                id: id,
                name: stringProperty(id, kAudioObjectPropertyName),
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID),
                inputChannels: inputChannelCount(id),
                sampleRate: property(id, kAudioDevicePropertyNominalSampleRate, default: 0.0)
            )
        }
    }

    public static func inputs() -> [AudioDevice] { all().filter(\.isInput) }

    public static func defaultInput() -> AudioDevice? {
        let id: AudioDeviceID = property(AudioObjectID(kAudioObjectSystemObject),
                                         kAudioHardwarePropertyDefaultInputDevice,
                                         default: 0)
        return inputs().first { $0.id == id }
    }

    /// Point an engine's input node at a specific device.
    ///
    /// Must be called before the engine starts and before `inputFormat` is read —
    /// the format is cached from whatever device is current at that moment. With
    /// five input devices on this machine, defaulting silently to the wrong one
    /// would make a level reading meaningless.
    public static func setInput(_ device: AudioDevice, on engine: AVAudioEngine) throws {
        guard let unit = engine.inputNode.audioUnit else {
            throw AudioDeviceError.noAudioUnit
        }
        var id = device.id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw AudioDeviceError.setDeviceFailed(status) }
    }
}

public enum AudioDeviceError: Error, CustomStringConvertible {
    case noAudioUnit
    case setDeviceFailed(OSStatus)
    case noMatch(String)

    public var description: String {
        switch self {
        case .noAudioUnit: return "input node has no audio unit"
        case .setDeviceFailed(let s): return "could not select input device (OSStatus \(s))"
        case .noMatch(let q): return "no input device matching \"\(q)\""
        }
    }
}
