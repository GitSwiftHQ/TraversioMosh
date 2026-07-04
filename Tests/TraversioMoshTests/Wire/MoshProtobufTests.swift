// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshWire

struct MoshProtobufTests {
    @Test
    func transportInstructionMatchesExpectedFieldBytes() throws {
        let instruction = MoshTransportInstruction(
            protocolVersion: 2,
            oldNumber: 0,
            newNumber: 1,
            acknowledgementNumber: 2,
            throwawayNumber: 3,
            diff: [0xaa, 0xbb],
            chaff: [0xcc]
        )

        let bytes = instruction.serializedBytes()

        #expect(bytes == hex("080210001801200228033202AABB3A01CC"))
        #expect(try MoshTransportInstruction(serializedBytes: bytes) == instruction)
    }

    @Test
    func clientMessageEncodesKeystrokeAndResizeExtensions() throws {
        let message = MoshClientMessage(instructions: [
            MoshClientInstruction(
                keystrokes: Array("a".utf8),
                resize: MoshTerminalSize(columns: 80, rows: 24)
            ),
        ])

        let bytes = message.serializedBytes()

        #expect(bytes == hex("0A0B12032201611A0428503018"))
        #expect(try MoshClientMessage(serializedBytes: bytes) == message)
    }

    @Test
    func hostMessageEncodesHostBytesResizeAndEchoAckExtensions() throws {
        let message = MoshHostMessage(instructions: [
            MoshHostInstruction(
                hostBytes: Array("ok".utf8),
                resize: MoshTerminalSize(columns: 100, rows: 40),
                echoAcknowledgementNumber: 300
            ),
        ])

        let bytes = message.serializedBytes()

        #expect(bytes == hex("0A11120422026F6B1A04286430283A0340AC02"))
        #expect(try MoshHostMessage(serializedBytes: bytes) == message)
    }

    @Test
    func skipsUnknownVarintAndLengthDelimitedFields() throws {
        let bytes = hex("0802C00601CA0602AABB1807")
        let instruction = try MoshTransportInstruction(serializedBytes: bytes)

        #expect(instruction.protocolVersion == 2)
        #expect(instruction.newNumber == 7)
    }

    @Test
    func rejectsTruncatedLengthDelimitedField() {
        #expect(throws: MoshProtobufError.truncated) {
            _ = try MoshTransportInstruction(serializedBytes: hex("3202AA"))
        }
    }

    @Test
    func rejectsMalformedVarint() {
        #expect(throws: MoshProtobufError.malformedVarint) {
            _ = try MoshTransportInstruction(serializedBytes: [UInt8](repeating: 0x80, count: 10))
        }
    }

    @Test
    func skipsUnknownGroupEncodedField() throws {
        // Field 100 start-group, a nested varint field, matching end-group,
        // then the known field 3 (newNumber = 7). The group must be skipped and
        // parsing must continue to the trailing known field.
        let bytes = hex("A3060805A4061807")
        let instruction = try MoshTransportInstruction(serializedBytes: bytes)

        #expect(instruction.newNumber == 7)
    }

    @Test
    func rejectsUnmatchedEndGroupTag() {
        // Field 100 end-group (wire type 4) with no enclosing start-group.
        #expect(throws: MoshProtobufError.unsupportedWireType(4)) {
            _ = try MoshTransportInstruction(serializedBytes: hex("A406"))
        }
    }

    @Test
    func rejectsUnterminatedGroup() {
        // Start-group with no matching end-group must fail (not crash / not
        // silently accept).
        #expect(throws: MoshProtobufError.truncated) {
            _ = try MoshTransportInstruction(serializedBytes: hex("A306"))
        }
    }

    @Test
    func rejectsLengthVarintExceedingIntMax() {
        // Field 6 (diff, wire type 2) with a length varint of 2^63 (Int.max + 1).
        // A trapping Int(UInt64) narrowing would crash the process here; the
        // bounds guard must instead throw before any Int conversion.
        #expect(throws: MoshProtobufError.truncated) {
            _ = try MoshTransportInstruction(serializedBytes: hex("3280808080808080808001"))
        }
    }

    @Test
    func rejectsOverlongNonCanonicalVarint() {
        // Field 2 (oldNumber, wire type 0) with a 10-byte varint whose final
        // byte sets payload bits beyond bit 63 (0x02 -> bit 1). Those bits
        // cannot fit a UInt64 and were previously dropped silently.
        #expect(throws: MoshProtobufError.malformedVarint) {
            _ = try MoshTransportInstruction(serializedBytes: hex("1080808080808080808002"))
        }
    }

    @Test
    func resizeRoundTripsNegativeInt32Dimensions() throws {
        // proto2 int32 resize dimensions must survive the sign-extended 10-byte
        // varint form a conformant peer sends for negative values.
        let message = MoshClientMessage(instructions: [
            MoshClientInstruction(resize: MoshTerminalSize(columns: -1, rows: -2)),
        ])

        let bytes = message.serializedBytes()
        let decoded = try MoshClientMessage(serializedBytes: bytes)

        #expect(decoded == message)
        #expect(decoded.instructions.first?.resize == MoshTerminalSize(columns: -1, rows: -2))
        // width -1 must serialize as the canonical sign-extended 10-byte varint.
        #expect(bytes.contains(where: { $0 == 0x28 }))
        #expect(bytes.filter { $0 == 0xff }.count >= 9)
    }

    @Test
    func rejectsUnexpectedWireTypeForKnownField() {
        #expect(throws: MoshProtobufError.unexpectedWireType(fieldNumber: 1, expected: 0, actual: 2)) {
            _ = try MoshTransportInstruction(serializedBytes: hex("0A00"))
        }
    }

    @Test
    func rejectsUInt32OverflowForProtocolVersion() {
        #expect(throws: MoshProtobufError.varintOutOfRange(fieldNumber: 1, value: 4_294_967_296)) {
            _ = try MoshTransportInstruction(serializedBytes: hex("088080808010"))
        }
    }
}

private func hex(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = string.startIndex

    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }

    return bytes
}
