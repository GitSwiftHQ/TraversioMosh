// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshWire

struct MoshCompressionTests {
    @Test
    func compressMatchesZlibFixture() throws {
        let compressor = MoshCompressor()
        let input = Array("mosh".utf8)

        let compressed = try compressor.compress(input)

        #expect(compressed == hex("789CCBCD2FCE0000045301B8"))
    }

    @Test
    func compressesEmptyInputWithZlibEnvelope() throws {
        let compressor = MoshCompressor()

        let compressed = try compressor.compress([])
        let decompressed = try compressor.decompress(compressed)

        #expect(compressed == hex("789C030000000001"))
        #expect(decompressed == [])
    }

    @Test
    func decompressesKnownZlibFixture() throws {
        let compressor = MoshCompressor()
        let compressed = hex("789CF3F50FF65028484CCE4E2D5148CECF2D284A2D2ECECCCF5348CBAC28292D4A0500B2650BC9")

        let decompressed = try compressor.decompress(compressed)

        #expect(decompressed == Array("MOSH packet compression fixture".utf8))
    }

    @Test
    func transportInstructionRoundTripsThroughCompression() throws {
        let compressor = MoshCompressor()
        let instruction = MoshTransportInstruction(
            protocolVersion: 2,
            oldNumber: 1,
            newNumber: 2,
            acknowledgementNumber: 3,
            throwawayNumber: 1,
            diff: Array("diff".utf8),
            chaff: [0x00, 0x01]
        )

        let compressed = try compressor.compress(instruction.serializedBytes())
        let decompressed = try compressor.decompress(compressed)

        #expect(try MoshTransportInstruction(serializedBytes: decompressed) == instruction)
    }

    @Test
    func rejectsMalformedCompressedBytes() {
        let compressor = MoshCompressor()

        #expect(throws: MoshCompressionError.decompressionFailed) {
            _ = try compressor.decompress([0, 1, 2, 3])
        }
    }

    @Test
    func rejectsOutputThatExceedsConfiguredLimit() throws {
        let compressor = MoshCompressor()
        let compressed = try compressor.compress(Array("mosh".utf8))

        #expect(throws: MoshCompressionError.outputLimitExceeded) {
            _ = try compressor.decompress(compressed, maximumOutputByteCount: 3)
        }
    }

    @Test
    func rejectsNegativeOutputLimit() {
        let compressor = MoshCompressor()

        #expect(throws: MoshCompressionError.invalidMaximumOutputByteCount(-1)) {
            _ = try compressor.decompress([], maximumOutputByteCount: -1)
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
