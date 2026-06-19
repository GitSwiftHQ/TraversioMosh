// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public enum MoshDatagramCipherError: Error, Equatable, Sendable {
    case datagramTooShort(Int)
}

public struct MoshOpenedDatagram: Equatable, Sendable {
    public let nonce: MoshPacketNonce
    public let plaintext: [UInt8]

    public init(nonce: MoshPacketNonce, plaintext: [UInt8]) {
        self.nonce = nonce
        self.plaintext = plaintext
    }
}

public struct MoshDatagramCipher: Sendable {
    public static let nonceByteCount = 8
    public static let minimumDatagramByteCount = nonceByteCount + MoshAES128OCB.tagSize

    private let ocb: MoshAES128OCB

    public init(sessionKey: MoshSessionKey) throws {
        self.ocb = try MoshAES128OCB(sessionKey: sessionKey)
    }

    public init(rawKey: some Collection<UInt8>) throws {
        self.ocb = try MoshAES128OCB(rawKey: rawKey)
    }

    public func seal(plaintext: [UInt8], nonce: MoshPacketNonce) throws -> [UInt8] {
        let sealedPayload = try self.ocb.seal(plaintext: plaintext, nonce: nonce.rawBytes)
        return nonce.datagramBytes + sealedPayload
    }

    public func seal(
        plaintext: [UInt8],
        sequence: UInt64,
        direction: MoshPacketDirection
    ) throws -> [UInt8] {
        let nonce = try MoshPacketNonce(sequence: sequence, direction: direction)
        return try self.seal(plaintext: plaintext, nonce: nonce)
    }

    public func open(datagram: [UInt8]) throws -> MoshOpenedDatagram {
        guard datagram.count >= Self.minimumDatagramByteCount else {
            throw MoshDatagramCipherError.datagramTooShort(datagram.count)
        }

        let nonce = try MoshPacketNonce(datagramBytes: datagram.prefix(Self.nonceByteCount))
        let sealedPayload = Array(datagram.dropFirst(Self.nonceByteCount))
        let plaintext = try self.ocb.open(ciphertext: sealedPayload, nonce: nonce.rawBytes)

        return MoshOpenedDatagram(nonce: nonce, plaintext: plaintext)
    }
}
