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

    @Test("Official Mosh packet known-answer vectors", arguments: moshPacketVectors)
    func matchesOfficialMoshPacketVector(vector: MoshPacketVector) throws {
        let cipher = try MoshDatagramCipher(rawKey: hex(vector.key))
        let plaintext = MoshPacketPlaintext(
            timestamp: 0x1234,
            timestampReply: 0xffff,
            payload: hex("AABB")
        )
        let plaintextBytes = plaintext.serializedBytes()

        let datagram = try cipher.seal(
            plaintext: plaintextBytes,
            sequence: vector.sequence,
            direction: vector.direction
        )
        let opened = try cipher.open(datagram: hex(vector.datagram))

        #expect(datagram == hex(vector.datagram))
        #expect(opened.nonce.sequence == vector.sequence)
        #expect(opened.nonce.direction == vector.direction)
        #expect(try MoshPacketPlaintext(serializedBytes: opened.plaintext) == plaintext)
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

struct MoshPacketVector: Sendable {
    let key: String
    let sequence: UInt64
    let direction: MoshPacketDirection
    let datagram: String
}

private let moshPacketVectors = [
    MoshPacketVector(
        key: "000102030405060708090A0B0C0D0E0F",
        sequence: 0x0102030405060708,
        direction: .toServer,
        datagram: "010203040506070880BE6A22D6D1DDFC19520D9FA1762B9DE6A45B97B31B"
    ),
    MoshPacketVector(
        key: "000102030405060708090A0B0C0D0E0F",
        sequence: 0x0102030405060708,
        direction: .toClient,
        datagram: "81020304050607089958FDAA8B9E05F6F2FBD2B416C4217252820F2BBCDC"
    ),
]

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
