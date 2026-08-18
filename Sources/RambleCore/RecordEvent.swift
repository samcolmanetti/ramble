import Foundation

/// Interpretation of a decoded frame.
///
/// Only `0x03` is load-bearing. Everything else is logged during verification
/// and ignored by the app. See handoff §4 for the opcode table and the evidence
/// behind `0x35`/`0x36`.
public enum RecordEvent: Equatable {
    case recordStarted
    case recordStopped
    /// Opcode 0x03 with an unrecognized payload — worth shouting about, since it
    /// would mean the two-state hypothesis is incomplete.
    case unknownRecordState(UInt8)
    case other(opcode: UInt8, payload: [UInt8])

    public init(frame: Frame) {
        guard frame.opcode == 0x03 else {
            self = .other(opcode: frame.opcode, payload: frame.payload)
            return
        }
        guard frame.payload.count == 1 else {
            self = .other(opcode: frame.opcode, payload: frame.payload)
            return
        }
        switch frame.payload[0] {
        case 0x35: self = .recordStarted
        case 0x36: self = .recordStopped
        case let b: self = .unknownRecordState(b)
        }
    }

    /// Human-readable label for logs and the menu bar's "last event" line.
    public var label: String {
        switch self {
        case .recordStarted: return "RECORD START"
        case .recordStopped: return "RECORD STOP"
        case .unknownRecordState(let b):
            return String(format: "RECORD STATE? (0x%02X)", b)
        case .other(let opcode, _):
            return String(format: "op 0x%02X", opcode)
        }
    }
}

public extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
