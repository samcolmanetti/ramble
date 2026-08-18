import Foundation

/// Interpretation of a decoded frame.
///
/// Only `0x03` is load-bearing. Everything else is logged during verification
/// and ignored by the app. See handoff §4 for the opcode table and the evidence
/// behind `0x35`/`0x36`.
public enum RecordEvent: Equatable {
    case recordStarted
    case recordStopped
    /// `02 [48 02]` — the button press that begins a take. Arrives ~30 ms before
    /// `0x35`, so it is logged but not used as the trigger.
    case startPress
    /// `02 [44 02]` — the button press that ends a take. Arrives a consistent
    /// 1.0–1.6 s *before* `0x36`, which the device only sends once it has
    /// finished flushing the file to internal storage. This is the stop trigger;
    /// see FINDINGS.md.
    case stopPress
    /// Opcode 0x03 with an unrecognized payload — worth shouting about, since it
    /// would mean the two-state hypothesis is incomplete.
    case unknownRecordState(UInt8)
    case other(opcode: UInt8, payload: [UInt8])

    public init(frame: Frame) {
        if frame.opcode == 0x02 {
            switch frame.payload {
            case [0x48, 0x02]: self = .startPress; return
            case [0x44, 0x02]: self = .stopPress; return
            default: break
            }
        }
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
        case .startPress: return "button press (start)"
        case .stopPress: return "button press (stop)"
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
