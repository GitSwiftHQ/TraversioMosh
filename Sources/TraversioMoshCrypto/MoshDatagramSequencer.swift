// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public enum MoshDatagramSequencerError: Error, Equatable, Sendable {
    case sendSequenceExhausted(UInt64)
    case directionMismatch(expected: MoshPacketDirection, actual: MoshPacketDirection)
    /// The session has sealed the maximum number of AES blocks permitted under
    /// one key. Carries the cumulative block count that would have been reached.
    /// Fail-closed and fatal: the datagram that crossed the limit is not
    /// emitted, mirroring how `sendSequenceExhausted` is handled.
    case blockEncryptionLimitReached(UInt64)
}

public enum MoshDatagramSequenceStatus: Equatable, Sendable {
    case new(expectedNextSequence: UInt64)
    case replayed(expectedNextSequence: UInt64)
}

public struct MoshReceivedDatagram: Equatable, Sendable {
    public let openedDatagram: MoshOpenedDatagram
    public let sequenceStatus: MoshDatagramSequenceStatus

    public init(
        openedDatagram: MoshOpenedDatagram,
        sequenceStatus: MoshDatagramSequenceStatus
    ) {
        self.openedDatagram = openedDatagram
        self.sequenceStatus = sequenceStatus
    }
}

public struct MoshDatagramSequencer: ~Copyable, Sendable {
    /// Maximum number of AES blocks that may be sealed under one session key.
    ///
    /// OCB's privacy and authenticity bounds degrade as s²/2^128, where s is the
    /// total number of blocks acquired by an adversary. Official Mosh caps a
    /// session at 2^47 sealed blocks for this reason (`crypto.cc`, `Session::encrypt`,
    /// `if ( blocks_encrypted >> 47 )`), noting client and server share the key so
    /// the per-side budget is 2^47 rather than 2^48. Reaching the cap kills the
    /// session.
    public static let blockEncryptionLimit: UInt64 = 1 << 47

    private let cipher: MoshDatagramCipher
    private let sendDirection: MoshPacketDirection
    private let receiveDirection: MoshPacketDirection
    private var nextSendSequence: UInt64
    private var expectedReceiveSequence: UInt64
    private var blocksEncrypted: UInt64

    public init(
        cipher: MoshDatagramCipher,
        sendDirection: MoshPacketDirection,
        receiveDirection: MoshPacketDirection,
        initialSendSequence: UInt64 = 0,
        initialExpectedReceiveSequence: UInt64 = 0,
        initialBlocksEncrypted: UInt64 = 0
    ) throws {
        guard initialSendSequence <= MoshPacketNonce.sequenceMask else {
            throw MoshPacketNonceError.sequenceOutOfRange(initialSendSequence)
        }
        guard initialExpectedReceiveSequence <= MoshPacketNonce.sequenceMask + 1 else {
            throw MoshPacketNonceError.sequenceOutOfRange(initialExpectedReceiveSequence)
        }

        self.cipher = cipher
        self.sendDirection = sendDirection
        self.receiveDirection = receiveDirection
        self.nextSendSequence = initialSendSequence
        self.expectedReceiveSequence = initialExpectedReceiveSequence
        self.blocksEncrypted = initialBlocksEncrypted
    }

    public init(
        sessionKey: MoshSessionKey,
        sendDirection: MoshPacketDirection,
        receiveDirection: MoshPacketDirection
    ) throws {
        try self.init(
            cipher: MoshDatagramCipher(sessionKey: sessionKey),
            sendDirection: sendDirection,
            receiveDirection: receiveDirection
        )
    }

    public init(
        rawKey: some Collection<UInt8>,
        sendDirection: MoshPacketDirection,
        receiveDirection: MoshPacketDirection,
        initialSendSequence: UInt64 = 0,
        initialExpectedReceiveSequence: UInt64 = 0,
        initialBlocksEncrypted: UInt64 = 0
    ) throws {
        try self.init(
            cipher: MoshDatagramCipher(rawKey: rawKey),
            sendDirection: sendDirection,
            receiveDirection: receiveDirection,
            initialSendSequence: initialSendSequence,
            initialExpectedReceiveSequence: initialExpectedReceiveSequence,
            initialBlocksEncrypted: initialBlocksEncrypted
        )
    }

    public var nextSequenceToSend: UInt64 {
        self.nextSendSequence
    }

    public var nextExpectedReceiveSequence: UInt64 {
        self.expectedReceiveSequence
    }

    /// Cumulative count of AES blocks sealed under this key.
    public var totalBlocksEncrypted: UInt64 {
        self.blocksEncrypted
    }

    public mutating func seal(plaintext: [UInt8]) throws -> [UInt8] {
        guard self.nextSendSequence <= MoshPacketNonce.sequenceMask else {
            throw MoshDatagramSequencerError.sendSequenceExhausted(self.nextSendSequence)
        }

        // Block accounting matches official Mosh (`crypto.cc`, `Session::encrypt`):
        //   blocks_encrypted += pt_len >> 4;  if ( pt_len & 0xF ) blocks_encrypted++;
        // i.e. ceil(plaintext / 16). Official always passes ad_len == 0, so
        // associated data contributes no blocks, matching this seal path.
        let blockSize = UInt64(MoshAES128OCB.blockSize)
        let plaintextCount = UInt64(plaintext.count)
        let sealedBlocks = plaintextCount / blockSize + (plaintextCount % blockSize == 0 ? 0 : 1)
        let projectedBlocks = self.blocksEncrypted + sealedBlocks

        // Fail closed before emitting the datagram that would cross the limit,
        // mirroring official's throw prior to returning the ciphertext.
        guard projectedBlocks < Self.blockEncryptionLimit else {
            throw MoshDatagramSequencerError.blockEncryptionLimitReached(projectedBlocks)
        }

        let datagram = try self.cipher.seal(
            plaintext: plaintext,
            sequence: self.nextSendSequence,
            direction: self.sendDirection
        )
        self.blocksEncrypted = projectedBlocks
        self.nextSendSequence += 1
        return datagram
    }

    public mutating func open(datagram: [UInt8]) throws -> MoshReceivedDatagram {
        let openedDatagram = try self.cipher.open(datagram: datagram)
        guard openedDatagram.nonce.direction == self.receiveDirection else {
            throw MoshDatagramSequencerError.directionMismatch(
                expected: self.receiveDirection,
                actual: openedDatagram.nonce.direction
            )
        }

        if openedDatagram.nonce.sequence < self.expectedReceiveSequence {
            return MoshReceivedDatagram(
                openedDatagram: openedDatagram,
                sequenceStatus: .replayed(expectedNextSequence: self.expectedReceiveSequence)
            )
        }

        self.expectedReceiveSequence = openedDatagram.nonce.sequence + 1
        return MoshReceivedDatagram(
            openedDatagram: openedDatagram,
            sequenceStatus: .new(expectedNextSequence: self.expectedReceiveSequence)
        )
    }
}
