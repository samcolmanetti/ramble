import Foundation
import RambleCore

// ramble-check — the test suite.
//
// XCTest and swift-testing both ship with Xcode, not with the Command Line
// Tools, so `swift test` cannot run on a CLT-only machine (PLAN.md §2). Rather
// than make a 3 GB Xcode install a prerequisite for running tests, the suite is
// a plain executable with a ~20-line harness. `swift run ramble-check` exits
// non-zero on failure, so CI works the same way.

var failures = 0
var checks = 0
var currentGroup = ""

func group(_ name: String) {
    currentGroup = name
    print("\n\(name)")
}

func expect(_ condition: Bool, _ description: @autoclosure () -> String) {
    checks += 1
    if condition {
        print("  ✓ \(description())")
    } else {
        failures += 1
        print("  ✗ \(description())")
    }
}

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ description: String) {
    checks += 1
    if got == want {
        print("  ✓ \(description)")
    } else {
        failures += 1
        print("  ✗ \(description)\n      got:  \(got)\n      want: \(want)")
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
    var successValue: Success? {
        if case .success(let v) = self { return v }
        return nil
    }
}

// The seven distinct (opcode, payload) pairs seen in the capture (handoff §4).
//
// The handoff records each frame's opcode and payload but *not* its checksum
// byte, so these cases are reconstructed from the documented rule rather than
// replayed from the capture. They prove the parser is self-consistent and
// rejects malformed input; only a live `ramble-sniff` run proves the checksum
// rule itself is right. That is what Phase 1 is for.
let captured: [(UInt8, [UInt8])] = [
    (0x03, [0x35]),
    (0x03, [0x36]),
    (0x04, [0x44, 0xFF]),
    (0x02, [0x3A, 0x03, 0x4C]),
    (0x02, [0x44, 0x02]),
    (0x07, [0x4F, 0xAA, 0x58, 0xB9, 0x03, 0x1E, 0x02]),
    (0x09, [0x49, 0xC0, 0x8F, 0xE9, 0xC0, 0x38, 0x9F, 0x01, 0x02]),
]

group("frame round-trip over captured frames")
for (opcode, payload) in captured {
    let chk = Frame.checksum(opcode: opcode, payload: payload)
    let wire = Frame(opcode: opcode, payload: payload, checksum: chk).encoded()
    let label = String(format: "op %02X [%@]", opcode, payload.hex)

    expectEqual(wire.count, payload.count + 5, "\(label): total size is len + 5")
    expectEqual(Array(wire.prefix(3)), [0x00, 0x02, UInt8(payload.count)],
                "\(label): preamble and length byte")

    if let parsed = Frame.parse(wire).successValue {
        expectEqual(parsed.opcode, opcode, "\(label): opcode survives round-trip")
        expectEqual(parsed.payload, payload, "\(label): payload survives round-trip")
    } else {
        expect(false, "\(label): parses back")
    }
}

group("checksum formula: (1 - opcode - sum(payload)) & 0xFF")
expectEqual(Frame.checksum(opcode: 0x03, payload: [0x35]), 0xC9, "record-start checksum is C9")
expectEqual(Frame.checksum(opcode: 0x03, payload: [0x36]), 0xC8, "record-stop checksum is C8")
expectEqual(Frame.checksum(opcode: 0x00, payload: []), 0x01, "empty payload checksum is 01")

group("malformed frames are rejected")
expectEqual(Frame.parse([0x00, 0x02, 0x01]).failureValue, .tooShort(3),
            "frame under 6 bytes")
expectEqual(Frame.parse([0x01, 0x02, 0x01, 0x03, 0x35, 0xC9]).failureValue,
            .badPreamble([0x01, 0x02]), "wrong preamble")
expectEqual(Frame.parse([0x00, 0x02, 0x03, 0x03, 0x35, 0xC9]).failureValue,
            .lengthMismatch(declared: 3, frameSize: 6), "truncated notification")
expectEqual(Frame.parse([0x00, 0x02, 0x01, 0x03, 0x35, 0x00]).failureValue,
            .badChecksum(got: 0x00, expected: 0xC9), "corrupt checksum")

group("checksum catches every single-bit flip")
var survivors: [String] = []
for (opcode, payload) in captured {
    let chk = Frame.checksum(opcode: opcode, payload: payload)
    let wire = Frame(opcode: opcode, payload: payload, checksum: chk).encoded()
    for index in 3 ..< (wire.count - 1) {
        for bit in 0 ..< 8 {
            var corrupted = wire
            corrupted[index] ^= (1 << bit)
            if Frame.parse(corrupted).failureValue == nil {
                survivors.append(String(format: "op %02X byte %d bit %d", opcode, index, bit))
            }
        }
    }
}
expect(survivors.isEmpty,
       "no bit flip in opcode or payload survives (\(survivors.count) survivors)")
for s in survivors.prefix(5) { print("      survived: \(s)") }

group("record event interpretation")
func event(_ opcode: UInt8, _ payload: [UInt8]) -> RecordEvent {
    RecordEvent(frame: Frame(opcode: opcode, payload: payload,
                             checksum: Frame.checksum(opcode: opcode, payload: payload)))
}
expectEqual(event(0x03, [0x35]), .recordStarted, "0x03 [35] is record start")
expectEqual(event(0x03, [0x36]), .recordStopped, "0x03 [36] is record stop")
// A third value on 0x03 would mean the two-state hypothesis is incomplete, so it
// must be distinguishable from ordinary traffic rather than lumped into .other.
expectEqual(event(0x03, [0x37]), .unknownRecordState(0x37), "0x03 [37] is flagged, not ignored")
expectEqual(event(0x04, [0x44, 0xFF]), .other(opcode: 0x04, payload: [0x44, 0xFF]),
            "0x04 is not a trigger")
expectEqual(event(0x02, [0x3A, 0x03, 0x4C]), .other(opcode: 0x02, payload: [0x3A, 0x03, 0x4C]),
            "0x02 is not a trigger")
// 0x03 is only a trigger with a one-byte payload; a longer one means something
// else is going on and must not fire the hotkey.
expectEqual(event(0x03, [0x35, 0x00]), .other(opcode: 0x03, payload: [0x35, 0x00]),
            "0x03 with a 2-byte payload is not a trigger")

print("""

────────────────────────────────────────────
\(failures == 0 ? "PASS" : "FAIL")  \(checks - failures)/\(checks) checks
""")
exit(failures == 0 ? 0 : 1)
