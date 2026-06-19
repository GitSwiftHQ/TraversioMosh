// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCrypto

struct MoshSessionKeyTests {
    @Test
    func encodedKeyRoundTripsThroughRawBytes() throws {
        let bytes = Array(UInt8(0)..<UInt8(16))
        let key = try MoshSessionKey(rawBytes: bytes)

        #expect(key.rawBytes == bytes)
        #expect(key.encodedRepresentation == "AAECAwQFBgcICQoLDA0ODw")

        let decoded = try MoshSessionKey(encodedRepresentation: key.encodedRepresentation)
        #expect(decoded == key)
    }

    @Test
    func acceptsOfficialStylePrintableKey() throws {
        let key = try MoshSessionKey(encodedRepresentation: "UAkFedSsVJs2LfMe2Fkedw")

        #expect(key.rawBytes.count == MoshSessionKey.byteCount)
        #expect(key.encodedRepresentation == "UAkFedSsVJs2LfMe2Fkedw")
    }

    @Test("Rejects invalid encoded key lengths", arguments: [
        "",
        "short",
        "UAkFedSsVJs2LfMe2Fked",
        "UAkFedSsVJs2LfMe2Fkedww",
    ])
    func rejectsInvalidEncodedLengths(encoded: String) {
        #expect(throws: MoshSessionKeyError.invalidEncodedLength(actualUTF8Bytes: encoded.utf8.count)) {
            _ = try MoshSessionKey(encodedRepresentation: encoded)
        }
    }

    @Test
    func rejectsInvalidBase64Characters() {
        #expect(throws: MoshSessionKeyError.invalidBase64) {
            _ = try MoshSessionKey(encodedRepresentation: "UAkFedSsVJs2LfMe2Fked!")
        }
    }

    @Test
    func rejectsNonCanonicalPaddingBits() {
        #expect(throws: MoshSessionKeyError.nonCanonicalEncoding) {
            _ = try MoshSessionKey(encodedRepresentation: "AAECAwQFBgcICQoLDA0ODx")
        }
    }

    @Test("Rejects invalid raw byte counts", arguments: [
        [UInt8](),
        Array(UInt8(0)..<UInt8(15)),
        Array(UInt8(0)..<UInt8(17)),
    ])
    func rejectsInvalidRawByteCounts(bytes: [UInt8]) {
        #expect(throws: MoshSessionKeyError.invalidRawByteCount(bytes.count)) {
            _ = try MoshSessionKey(rawBytes: bytes)
        }
    }
}
