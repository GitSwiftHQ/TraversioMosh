// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshWire

struct MoshPacketWireTests {
    @Test
    func packetPlaintextEncodesBigEndianTimestamps() throws {
        let plaintext = MoshPacketPlaintext(
            timestamp: 0x1234,
            timestampReply: 0xffff,
            payload: [0xaa, 0xbb]
        )

        let bytes = plaintext.serializedBytes()

        #expect(bytes == [0x12, 0x34, 0xff, 0xff, 0xaa, 0xbb])
        #expect(try MoshPacketPlaintext(serializedBytes: bytes) == plaintext)
    }

    @Test
    func rejectsTruncatedPacketPlaintextHeader() {
        #expect(throws: MoshPacketWireError.truncatedPacketHeader(3)) {
            _ = try MoshPacketPlaintext(serializedBytes: [0x12, 0x34, 0xff])
        }
    }

    @Test
    func fragmentEncodesBigEndianHeaderWithFinalBit() throws {
        let fragment = try MoshFragment(
            instructionID: 0x0102030405060708,
            fragmentNumber: 2,
            isFinal: true,
            contents: [0xaa, 0xbb]
        )

        let bytes = fragment.serializedBytes()

        #expect(bytes == [1, 2, 3, 4, 5, 6, 7, 8, 0x80, 0x02, 0xaa, 0xbb])
        #expect(try MoshFragment(serializedBytes: bytes) == fragment)
    }

    @Test
    func fragmentKeepsNonFinalHeaderClear() throws {
        let fragment = try MoshFragment(
            instructionID: 0,
            fragmentNumber: MoshFragment.maxFragmentNumber,
            isFinal: false,
            contents: []
        )

        let bytes = fragment.serializedBytes()

        #expect(bytes == [0, 0, 0, 0, 0, 0, 0, 0, 0x7f, 0xff])
        #expect(try MoshFragment(serializedBytes: bytes).isFinal == false)
        #expect(try MoshFragment(serializedBytes: bytes).fragmentNumber == MoshFragment.maxFragmentNumber)
    }

    @Test
    func rejectsOutOfRangeFragmentNumberOnEncode() {
        #expect(throws: MoshPacketWireError.fragmentNumberOutOfRange(0x8000)) {
            _ = try MoshFragment(
                instructionID: 1,
                fragmentNumber: 0x8000,
                isFinal: false,
                contents: []
            )
        }
    }

    @Test
    func rejectsTruncatedFragmentHeader() {
        #expect(throws: MoshPacketWireError.truncatedFragmentHeader(9)) {
            _ = try MoshFragment(serializedBytes: [UInt8](repeating: 0, count: 9))
        }
    }
}
