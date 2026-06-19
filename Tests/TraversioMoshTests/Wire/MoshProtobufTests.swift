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
    func rejectsUnsupportedWireType() {
        #expect(throws: MoshProtobufError.unsupportedWireType(3)) {
            _ = try MoshTransportInstruction(serializedBytes: hex("A306"))
        }
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
