// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCrypto

struct MoshDatagramSequencerTests {
    @Test
    func sealUsesDirectionAndIncrementsSequence() throws {
        var sequencer = try MoshDatagramSequencer(
            rawKey: key,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )
        let cipher = try MoshDatagramCipher(rawKey: key)

        let first = try cipher.open(datagram: sequencer.seal(plaintext: [1]))
        let second = try cipher.open(datagram: sequencer.seal(plaintext: [2]))

        #expect(first.nonce.direction == .toServer)
        #expect(first.nonce.sequence == 0)
        #expect(first.plaintext == [1])
        #expect(second.nonce.direction == .toServer)
        #expect(second.nonce.sequence == 1)
        #expect(second.plaintext == [2])
        #expect(sequencer.nextSequenceToSend == 2)
    }

    @Test
    func openAcceptsExpectedDirectionAndAdvancesExpectedSequence() throws {
        let cipher = try MoshDatagramCipher(rawKey: key)
        let datagram = try cipher.seal(
            plaintext: [0xaa],
            sequence: 0,
            direction: .toClient
        )
        var sequencer = try MoshDatagramSequencer(
            rawKey: key,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )

        let received = try sequencer.open(datagram: datagram)

        #expect(received.openedDatagram.plaintext == [0xaa])
        #expect(received.sequenceStatus == .new(expectedNextSequence: 1))
        #expect(sequencer.nextExpectedReceiveSequence == 1)
    }

    @Test
    func openRejectsUnexpectedDirection() throws {
        let cipher = try MoshDatagramCipher(rawKey: key)
        let datagram = try cipher.seal(
            plaintext: [0xaa],
            sequence: 0,
            direction: .toServer
        )
        var sequencer = try MoshDatagramSequencer(
            rawKey: key,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )

        #expect(
            throws: MoshDatagramSequencerError.directionMismatch(expected: .toClient, actual: .toServer)
        ) {
            _ = try sequencer.open(datagram: datagram)
        }
    }

    @Test
    func replayedDatagramReturnsPlaintextWithoutAdvancingExpectedSequence() throws {
        let cipher = try MoshDatagramCipher(rawKey: key)
        let datagram = try cipher.seal(
            plaintext: [0x01, 0x02],
            sequence: 0,
            direction: .toClient
        )
        var sequencer = try MoshDatagramSequencer(
            rawKey: key,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )

        _ = try sequencer.open(datagram: datagram)
        let replay = try sequencer.open(datagram: datagram)

        #expect(replay.openedDatagram.plaintext == [0x01, 0x02])
        #expect(replay.sequenceStatus == .replayed(expectedNextSequence: 1))
        #expect(sequencer.nextExpectedReceiveSequence == 1)
    }

    @Test
    func receiveGapAdvancesExpectedSequenceAndMarksLowerPacketReplay() throws {
        let cipher = try MoshDatagramCipher(rawKey: key)
        let later = try cipher.seal(
            plaintext: [0x02],
            sequence: 2,
            direction: .toClient
        )
        let earlier = try cipher.seal(
            plaintext: [0x01],
            sequence: 1,
            direction: .toClient
        )
        var sequencer = try MoshDatagramSequencer(
            rawKey: key,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )

        let laterResult = try sequencer.open(datagram: later)
        let earlierResult = try sequencer.open(datagram: earlier)

        #expect(laterResult.sequenceStatus == .new(expectedNextSequence: 3))
        #expect(earlierResult.openedDatagram.plaintext == [0x01])
        #expect(earlierResult.sequenceStatus == .replayed(expectedNextSequence: 3))
        #expect(sequencer.nextExpectedReceiveSequence == 3)
    }

    @Test
    func sendSequenceExhaustionFailsClosedAfterMaximumSequence() throws {
        var sequencer = try MoshDatagramSequencer(
            rawKey: key,
            sendDirection: .toServer,
            receiveDirection: .toClient,
            initialSendSequence: MoshPacketNonce.sequenceMask
        )

        _ = try sequencer.seal(plaintext: [0xff])

        #expect(
            throws: MoshDatagramSequencerError.sendSequenceExhausted(MoshPacketNonce.sequenceMask + 1)
        ) {
            _ = try sequencer.seal(plaintext: [0x00])
        }
    }

    @Test
    func initializerRejectsOutOfRangeSendSequence() throws {
        #expect(
            throws: MoshPacketNonceError.sequenceOutOfRange(MoshPacketNonce.sequenceMask + 1)
        ) {
            _ = try MoshDatagramSequencer(
                rawKey: key,
                sendDirection: .toServer,
                receiveDirection: .toClient,
                initialSendSequence: MoshPacketNonce.sequenceMask + 1
            )
        }
    }

    @Test
    func initializerAllowsReceiveSequenceAfterMaximumPacket() throws {
        let cipher = try MoshDatagramCipher(rawKey: key)
        let datagram = try cipher.seal(
            plaintext: [0xff],
            sequence: MoshPacketNonce.sequenceMask,
            direction: .toClient
        )
        var sequencer = try MoshDatagramSequencer(
            rawKey: key,
            sendDirection: .toServer,
            receiveDirection: .toClient,
            initialExpectedReceiveSequence: MoshPacketNonce.sequenceMask + 1
        )

        let replay = try sequencer.open(datagram: datagram)

        #expect(replay.sequenceStatus == .replayed(expectedNextSequence: MoshPacketNonce.sequenceMask + 1))
        #expect(sequencer.nextExpectedReceiveSequence == MoshPacketNonce.sequenceMask + 1)
    }

    @Test
    func initializerRejectsReceiveSequenceBeyondMaximumPacket() throws {
        #expect(
            throws: MoshPacketNonceError.sequenceOutOfRange(MoshPacketNonce.sequenceMask + 2)
        ) {
            _ = try MoshDatagramSequencer(
                rawKey: key,
                sendDirection: .toServer,
                receiveDirection: .toClient,
                initialExpectedReceiveSequence: MoshPacketNonce.sequenceMask + 2
            )
        }
    }

    // MARK: - Block-count accounting (OCB s^2/2^128 degradation limit)

    @Test(
        "Sealing counts ceil(plaintext / 16) AES blocks, matching official Mosh",
        arguments: [
            (0, UInt64(0)),
            (1, UInt64(1)),
            (15, UInt64(1)),
            (16, UInt64(1)),
            (17, UInt64(2)),
            (32, UInt64(2)),
            (33, UInt64(3)),
        ]
    )
    func sealCountsCeilingBlocksPerPlaintext(plaintextCount: Int, expectedBlocks: UInt64) throws {
        var sequencer = try MoshDatagramSequencer(
            rawKey: key,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )

        _ = try sequencer.seal(plaintext: [UInt8](repeating: 0xab, count: plaintextCount))

        #expect(sequencer.totalBlocksEncrypted == expectedBlocks)
    }

    @Test
    func blockCountAccumulatesAcrossSeals() throws {
        var sequencer = try MoshDatagramSequencer(
            rawKey: key,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )

        _ = try sequencer.seal(plaintext: [UInt8](repeating: 0, count: 17)) // 2 blocks
        _ = try sequencer.seal(plaintext: [UInt8](repeating: 0, count: 16)) // 1 block
        _ = try sequencer.seal(plaintext: [UInt8](repeating: 0, count: 1))  // 1 block

        #expect(sequencer.totalBlocksEncrypted == 4)
    }

    @Test
    func sealWithinBlockLimitIsUnaffected() throws {
        var sequencer = try MoshDatagramSequencer(
            rawKey: key,
            sendDirection: .toServer,
            receiveDirection: .toClient,
            initialBlocksEncrypted: MoshDatagramSequencer.blockEncryptionLimit - 2
        )

        // One more block reaches limit - 1, still strictly below the cap.
        let datagram = try sequencer.seal(plaintext: [UInt8](repeating: 0x7, count: 16))
        let opened = try MoshDatagramCipher(rawKey: key).open(datagram: datagram)

        #expect(opened.plaintext == [UInt8](repeating: 0x7, count: 16))
        #expect(sequencer.totalBlocksEncrypted == MoshDatagramSequencer.blockEncryptionLimit - 1)
    }

    @Test
    func sealFailsClosedAtBlockEncryptionLimit() throws {
        var sequencer = try MoshDatagramSequencer(
            rawKey: key,
            sendDirection: .toServer,
            receiveDirection: .toClient,
            initialBlocksEncrypted: MoshDatagramSequencer.blockEncryptionLimit - 1
        )

        let sequenceBefore = sequencer.nextSequenceToSend

        // The block that would push the cumulative count to exactly 2^47 must
        // not be emitted; it fails closed with a fatal, thrown error.
        #expect(
            throws: MoshDatagramSequencerError.blockEncryptionLimitReached(
                MoshDatagramSequencer.blockEncryptionLimit
            )
        ) {
            _ = try sequencer.seal(plaintext: [UInt8](repeating: 0, count: 16))
        }

        // Fail-closed: the send sequence and block count did not advance.
        #expect(sequencer.nextSequenceToSend == sequenceBefore)
        #expect(sequencer.totalBlocksEncrypted == MoshDatagramSequencer.blockEncryptionLimit - 1)
    }

    @Test
    func sealFailsClosedWhenMultiBlockPlaintextCrossesLimit() throws {
        var sequencer = try MoshDatagramSequencer(
            rawKey: key,
            sendDirection: .toServer,
            receiveDirection: .toClient,
            initialBlocksEncrypted: MoshDatagramSequencer.blockEncryptionLimit - 1
        )

        // 32 bytes = 2 blocks would reach 2^47 + 1, crossing the cap.
        #expect(
            throws: MoshDatagramSequencerError.blockEncryptionLimitReached(
                MoshDatagramSequencer.blockEncryptionLimit + 1
            )
        ) {
            _ = try sequencer.seal(plaintext: [UInt8](repeating: 0, count: 32))
        }
    }
}

private let key = Array(UInt8(0)..<UInt8(16))
