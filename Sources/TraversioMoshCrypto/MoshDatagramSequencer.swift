// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public enum MoshDatagramSequencerError: Error, Equatable, Sendable {
    case sendSequenceExhausted(UInt64)
    case directionMismatch(expected: MoshPacketDirection, actual: MoshPacketDirection)
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

public struct MoshDatagramSequencer: Sendable {
    private let cipher: MoshDatagramCipher
    private let sendDirection: MoshPacketDirection
    private let receiveDirection: MoshPacketDirection
    private var nextSendSequence: UInt64
    private var expectedReceiveSequence: UInt64

    public init(
        cipher: MoshDatagramCipher,
        sendDirection: MoshPacketDirection,
        receiveDirection: MoshPacketDirection,
        initialSendSequence: UInt64 = 0,
        initialExpectedReceiveSequence: UInt64 = 0
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
        initialExpectedReceiveSequence: UInt64 = 0
    ) throws {
        try self.init(
            cipher: MoshDatagramCipher(rawKey: rawKey),
            sendDirection: sendDirection,
            receiveDirection: receiveDirection,
            initialSendSequence: initialSendSequence,
            initialExpectedReceiveSequence: initialExpectedReceiveSequence
        )
    }

    public var nextSequenceToSend: UInt64 {
        self.nextSendSequence
    }

    public var nextExpectedReceiveSequence: UInt64 {
        self.expectedReceiveSequence
    }

    public mutating func seal(plaintext: [UInt8]) throws -> [UInt8] {
        guard self.nextSendSequence <= MoshPacketNonce.sequenceMask else {
            throw MoshDatagramSequencerError.sendSequenceExhausted(self.nextSendSequence)
        }

        let datagram = try self.cipher.seal(
            plaintext: plaintext,
            sequence: self.nextSendSequence,
            direction: self.sendDirection
        )
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
