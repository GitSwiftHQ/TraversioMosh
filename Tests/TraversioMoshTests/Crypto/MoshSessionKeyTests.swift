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

    // MARK: - Zeroization

    @Test
    func wipeZeroesTheKeyBytes() throws {
        let key = try MoshSessionKey(rawBytes: Array(UInt8(1)..<UInt8(17)))

        key.wipe()

        #expect(key.rawBytes == [UInt8](repeating: 0, count: MoshSessionKey.byteCount))
    }

    @Test
    func wipeAffectsAllValuesSharingReferenceBackedStorage() throws {
        let key = try MoshSessionKey(rawBytes: Array(UInt8(1)..<UInt8(17)))
        // A struct copy shares the same wipeable buffer.
        let alias = key

        alias.wipe()

        // Wiping through one value zeroes the other: the storage is shared.
        #expect(key.rawBytes == [UInt8](repeating: 0, count: MoshSessionKey.byteCount))
        #expect(alias.rawBytes == [UInt8](repeating: 0, count: MoshSessionKey.byteCount))
    }

    @Test
    func independentlyConstructedKeysDoNotShareStorage() throws {
        let bytes = Array(UInt8(1)..<UInt8(17))
        let first = try MoshSessionKey(rawBytes: bytes)
        let second = try MoshSessionKey(rawBytes: bytes)

        first.wipe()

        // A separately constructed key keeps its own material.
        #expect(second.rawBytes == bytes)
    }

    // MARK: - Redaction (never leak key bytes into logs)

    @Test
    func descriptionAndDebugDescriptionAreRedacted() throws {
        let rawBytes = Array(UInt8(0x41)..<UInt8(0x51))
        let key = try MoshSessionKey(rawBytes: rawBytes)

        let described = "\(key)"
        let reflected = String(reflecting: key)

        #expect(described == "MoshSessionKey(<redacted>)")
        #expect(reflected == "MoshSessionKey(<redacted>)")

        // The raw bytes and their canonical encoding must never appear.
        let rawHex = rawBytes.map { String(format: "%02x", $0) }.joined()
        #expect(described.contains(rawHex) == false)
        #expect(reflected.contains(rawHex) == false)
        #expect(described.contains(key.encodedRepresentation) == false)
        #expect(reflected.contains(key.encodedRepresentation) == false)
    }

    @Test
    func redactionPropagatesThroughAContainingType() throws {
        struct Carrier {
            let label: String
            let key: MoshSessionKey
        }
        let key = try MoshSessionKey(rawBytes: Array(UInt8(0x41)..<UInt8(0x51)))
        let carrier = Carrier(label: "session", key: key)

        let reflected = String(reflecting: carrier)

        #expect(reflected.contains("<redacted>"))
        #expect(reflected.contains(key.encodedRepresentation) == false)
    }
}
