import Foundation

/// A decoded notification frame from the Instamic's FF11 characteristic.
///
/// Wire format (see instamic-ble-trigger-handoff.md §4):
///
///     00 02 <len> <opcode> <payload[len]> <chk>
///
/// where `chk == (1 - opcode - sum(payload)) & 0xFF` and the total frame size
/// is `len + 5`.
public struct Frame: Equatable {
    public let opcode: UInt8
    public let payload: [UInt8]
    public let checksum: UInt8

    public init(opcode: UInt8, payload: [UInt8], checksum: UInt8) {
        self.opcode = opcode
        self.payload = payload
        self.checksum = checksum
    }

    /// The checksum this frame's opcode and payload should carry.
    public var expectedChecksum: UInt8 {
        Frame.checksum(opcode: opcode, payload: payload)
    }

    public var isChecksumValid: Bool { checksum == expectedChecksum }

    public static func checksum(opcode: UInt8, payload: [UInt8]) -> UInt8 {
        let sum = payload.reduce(0) { $0 + Int($1) }
        return UInt8(truncatingIfNeeded: 1 - Int(opcode) - sum)
    }

    /// Serialize back to wire bytes. Used by tests and by any future writes.
    public func encoded() -> [UInt8] {
        [0x00, 0x02, UInt8(payload.count), opcode] + payload + [checksum]
    }
}

public enum FrameError: Error, Equatable, CustomStringConvertible {
    case tooShort(Int)
    case badPreamble([UInt8])
    /// Declared payload length disagrees with the actual frame size.
    case lengthMismatch(declared: Int, frameSize: Int)
    case badChecksum(got: UInt8, expected: UInt8)

    public var description: String {
        switch self {
        case .tooShort(let n):
            return "frame too short (\(n) bytes, minimum 6)"
        case .badPreamble(let b):
            return "bad preamble \(b.map { String(format: "%02X", $0) }.joined(separator: " ")), expected 00 02"
        case .lengthMismatch(let declared, let size):
            return "length mismatch: declared payload \(declared) implies \(declared + 5) bytes, got \(size)"
        case .badChecksum(let got, let expected):
            return String(format: "bad checksum: got %02X, expected %02X", got, expected)
        }
    }
}

extension Frame {
    /// Parse a raw notification value into a frame, rejecting anything malformed.
    ///
    /// Errors are surfaced rather than swallowed so `ramble-sniff` can display
    /// malformed traffic during protocol verification. The menu bar app drops
    /// them silently.
    public static func parse(_ bytes: [UInt8]) -> Result<Frame, FrameError> {
        guard bytes.count >= 6 else { return .failure(.tooShort(bytes.count)) }
        guard bytes[0] == 0x00, bytes[1] == 0x02 else {
            return .failure(.badPreamble(Array(bytes.prefix(2))))
        }
        let len = Int(bytes[2])
        guard bytes.count == len + 5 else {
            return .failure(.lengthMismatch(declared: len, frameSize: bytes.count))
        }
        let opcode = bytes[3]
        let payload = Array(bytes[4 ..< (4 + len)])
        let checksum = bytes[bytes.count - 1]
        let expected = Frame.checksum(opcode: opcode, payload: payload)
        guard checksum == expected else {
            return .failure(.badChecksum(got: checksum, expected: expected))
        }
        return .success(Frame(opcode: opcode, payload: payload, checksum: checksum))
    }

    public static func parse(_ data: Data) -> Result<Frame, FrameError> {
        parse([UInt8](data))
    }
}
