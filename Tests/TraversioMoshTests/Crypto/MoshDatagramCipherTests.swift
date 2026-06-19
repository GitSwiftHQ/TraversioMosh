// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCrypto
import TraversioMoshWire

struct MoshDatagramCipherTests {
    @Test
    func sealPrependsNonceSuffixAndOpensPlaintext() throws {
        let cipher = try MoshDatagramCipher(rawKey: Array(UInt8(0)..<UInt8(16)))
        let nonce = try MoshPacketNonce(sequence: 0x0102030405060708, direction: .toServer)
        let plaintext = MoshPacketPlaintext(
            timestamp: 0x1234,
            timestampReply: 0xffff,
            payload: [0xaa, 0xbb]
        ).serializedBytes()

        let datagram = try cipher.seal(plaintext: plaintext, nonce: nonce)
        let opened = try cipher.open(datagram: datagram)

        #expect(Array(datagram.prefix(8)) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(datagram.count == 8 + plaintext.count + MoshAES128OCB.tagSize)
        #expect(opened == MoshOpenedDatagram(nonce: nonce, plaintext: plaintext))
        #expect(try MoshPacketPlaintext(serializedBytes: opened.plaintext).payload == [0xaa, 0xbb])
    }

    @Test
    func sealCanConstructClientBoundNonce() throws {
        let cipher = try MoshDatagramCipher(rawKey: Array(UInt8(0)..<UInt8(16)))

        let datagram = try cipher.seal(
            plaintext: [0, 1, 2, 3],
            sequence: 0x0102030405060708,
            direction: .toClient
        )
        let opened = try cipher.open(datagram: datagram)

        #expect(Array(datagram.prefix(8)) == [0x81, 2, 3, 4, 5, 6, 7, 8])
        #expect(opened.nonce.sequence == 0x0102030405060708)
        #expect(opened.nonce.direction == .toClient)
        #expect(opened.plaintext == [0, 1, 2, 3])
    }

    @Test
    func rejectsDatagramShorterThanNonceAndTag() throws {
        let cipher = try MoshDatagramCipher(rawKey: Array(UInt8(0)..<UInt8(16)))

        #expect(throws: MoshDatagramCipherError.datagramTooShort(23)) {
            _ = try cipher.open(datagram: [UInt8](repeating: 0, count: 23))
        }
    }

    @Test
    func rejectsTamperedAuthenticatedPayload() throws {
        let cipher = try MoshDatagramCipher(rawKey: Array(UInt8(0)..<UInt8(16)))
        var datagram = try cipher.seal(
            plaintext: [0x12, 0x34, 0xff, 0xff, 0xaa],
            sequence: 7,
            direction: .toServer
        )
        datagram[datagram.count - 1] ^= 0x01

        #expect(throws: MoshAES128OCBError.authenticationFailed) {
            _ = try cipher.open(datagram: datagram)
        }
    }
}
