// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCrypto

struct MoshPacketNonceTests {
    @Test
    func encodesServerBoundSequenceWithoutDirectionBit() throws {
        let nonce = try MoshPacketNonce(sequence: 0x0102030405060708, direction: .toServer)

        #expect(nonce.rawBytes == [0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(nonce.datagramBytes == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(nonce.sequence == 0x0102030405060708)
        #expect(nonce.direction == .toServer)
    }

    @Test
    func encodesClientBoundSequenceWithDirectionBit() throws {
        let nonce = try MoshPacketNonce(sequence: 0x0102030405060708, direction: .toClient)

        #expect(nonce.rawBytes == [0, 0, 0, 0, 0x81, 2, 3, 4, 5, 6, 7, 8])

        let decoded = try MoshPacketNonce(rawBytes: nonce.rawBytes)
        #expect(decoded.sequence == 0x0102030405060708)
        #expect(decoded.direction == .toClient)
    }

    @Test
    func decodesDatagramNonceSuffix() throws {
        let nonce = try MoshPacketNonce(datagramBytes: [0x81, 2, 3, 4, 5, 6, 7, 8])

        #expect(nonce.rawBytes == [0, 0, 0, 0, 0x81, 2, 3, 4, 5, 6, 7, 8])
        #expect(nonce.sequence == 0x0102030405060708)
        #expect(nonce.direction == .toClient)
    }

    @Test
    func acceptsMaximumSequenceWithoutDirectionBit() throws {
        let nonce = try MoshPacketNonce(sequence: MoshPacketNonce.sequenceMask, direction: .toServer)

        #expect(nonce.sequence == MoshPacketNonce.sequenceMask)
        #expect(nonce.direction == .toServer)
    }

    @Test
    func rejectsSequenceThatWouldOverwriteDirectionBit() {
        #expect(throws: MoshPacketNonceError.sequenceOutOfRange(MoshPacketNonce.directionMask)) {
            _ = try MoshPacketNonce(sequence: MoshPacketNonce.directionMask, direction: .toServer)
        }
    }

    @Test
    func rejectsInvalidRawByteCount() {
        #expect(throws: MoshPacketNonceError.invalidRawByteCount(11)) {
            _ = try MoshPacketNonce(rawBytes: [UInt8](repeating: 0, count: 11))
        }
    }

    @Test
    func rejectsInvalidDatagramByteCount() {
        #expect(throws: MoshPacketNonceError.invalidDatagramByteCount(7)) {
            _ = try MoshPacketNonce(datagramBytes: [UInt8](repeating: 0, count: 7))
        }
    }

    @Test
    func rejectsNonZeroPrefix() {
        #expect(throws: MoshPacketNonceError.invalidPrefix([0, 0, 0, 1])) {
            _ = try MoshPacketNonce(rawBytes: [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        }
    }

    @Test
    func packetNonceCanDriveOCBRoundTrip() throws {
        let key = try MoshSessionKey(rawBytes: Array(UInt8(0)..<UInt8(16)))
        let ocb = try MoshAES128OCB(sessionKey: key)
        let nonce = try MoshPacketNonce(sequence: 7, direction: .toServer)
        let plaintext = Array("payload".utf8)

        let ciphertext = try ocb.seal(plaintext: plaintext, nonce: nonce.rawBytes)
        let opened = try ocb.open(ciphertext: ciphertext, nonce: nonce.rawBytes)

        #expect(opened == plaintext)
    }
}
