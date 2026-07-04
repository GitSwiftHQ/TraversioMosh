// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCore
import TraversioMoshWire

struct MoshSSPInMemoryLoopTests {
    @Test
    func defaultTimingUsesOfficialInitialSendInterval() throws {
        var loop = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            chaffSource: .none
        )

        loop.setCurrentState(ByteState([1]), nowMilliseconds: 0)

        #expect(try loop.waitTime(nowMilliseconds: 0) == 250)
        #expect(try loop.tick(nowMilliseconds: 249) == nil)

        let batch = try #require(try loop.tick(nowMilliseconds: 250))

        #expect(batch.instruction.newNumber == 1)
        #expect(batch.instruction.diff == [1])
    }

    @Test
    func timestampReplySampleControlsSendInterval() throws {
        var loop = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            chaffSource: .none
        )

        loop.setCurrentState(ByteState([1]), nowMilliseconds: 0)
        _ = try #require(try loop.tick(nowMilliseconds: 250))

        try receiveTimestampReply(140, into: &loop, nowMilliseconds: 260)

        loop.setCurrentState(ByteState([1, 2]), nowMilliseconds: 260)

        #expect(try loop.waitTime(nowMilliseconds: 309) == 1)
        #expect(try loop.tick(nowMilliseconds: 309) == nil)

        let nextBatch = try #require(try loop.tick(nowMilliseconds: 310))

        #expect(nextBatch.instruction.newNumber == 2)
        #expect(nextBatch.instruction.diff?.isEmpty == false)
    }

    @Test
    func timestampReplySampleControlsActiveRetryTimeout() throws {
        var loop = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            chaffSource: .none
        )

        loop.setCurrentState(ByteState([1]), nowMilliseconds: 0)
        _ = try #require(try loop.tick(nowMilliseconds: 250))

        try receiveTimestampReply(140, into: &loop, nowMilliseconds: 260)

        #expect(try loop.waitTime(nowMilliseconds: 709) == 1)
        #expect(try loop.tick(nowMilliseconds: 709) == nil)

        let retryBatch = try #require(try loop.tick(nowMilliseconds: 710))

        #expect(retryBatch.instruction.newNumber == 1)
        #expect(retryBatch.instruction.diff?.isEmpty == false)
    }

    @Test
    func fragmentedStateUpdateRoundTripsAndAcknowledges() throws {
        let noReplyTimestamp = UInt16.max
        var client = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            maximumSerializedFragmentByteCount: MoshFragment.headerByteCount + 12,
            chaffSource: .none
        )
        var server = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            chaffSource: .none
        )
        let state = ByteState((0..<200).map { UInt8(truncatingIfNeeded: $0) })

        client.setCurrentState(state, nowMilliseconds: 0)
        let clientBatch = try #require(try client.tick(nowMilliseconds: 20))

        #expect(clientBatch.packets.count > 1)
        #expect(clientBatch.packets.first?.plaintext.timestamp == 20)
        #expect(clientBatch.packets.allSatisfy { $0.plaintext.timestampReply == noReplyTimestamp })

        let receiveResult = try deliver(clientBatch.packets.reversed(), to: &server, nowMilliseconds: 21)

        #expect(receiveResult.receiveResult == .accepted(newNumber: 1))
        #expect(receiveResult.latestState.state == state)
        #expect(server.acknowledgementNumber == 1)

        let acknowledgementBatch = try #require(try server.tick(nowMilliseconds: 121))

        #expect(acknowledgementBatch.instruction.acknowledgementNumber == 1)
        #expect(acknowledgementBatch.instruction.diff == [])
        #expect(acknowledgementBatch.packets.first?.plaintext.timestamp == 121)
        #expect(acknowledgementBatch.packets.first?.plaintext.timestampReply == 120)

        _ = try deliver(acknowledgementBatch.packets, to: &client, nowMilliseconds: 122)

        #expect(client.knownAcknowledgedSendStateNumber == 1)
    }

    @Test
    func freshTimestampReplyIsCorrectedAndConsumedPerOutgoingPacket() throws {
        let noReplyTimestamp = UInt16.max
        var client = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )
        var server = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            maximumSerializedFragmentByteCount: MoshFragment.headerByteCount + 12,
            chaffSource: .none
        )

        client.setCurrentState(ByteState([1, 2, 3]), nowMilliseconds: 0)
        let clientBatch = try #require(try client.tick(nowMilliseconds: 20))

        _ = try deliver(clientBatch.packets, to: &server, nowMilliseconds: 21)

        let serverState = ByteState((0..<200).map { UInt8(truncatingIfNeeded: $0) })
        server.setCurrentState(serverState, nowMilliseconds: 22)
        let serverBatch = try #require(try server.tick(nowMilliseconds: 41))

        #expect(serverBatch.packets.count > 1)
        #expect(serverBatch.packets.first?.plaintext.timestamp == 41)
        #expect(serverBatch.packets.first?.plaintext.timestampReply == 40)
        #expect(serverBatch.packets.dropFirst().allSatisfy { $0.plaintext.timestampReply == noReplyTimestamp })
    }

    @Test
    func staleTimestampReplyIsSuppressedAfterFreshnessWindow() throws {
        let noReplyTimestamp = UInt16.max
        var client = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )
        var server = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            chaffSource: .none
        )

        client.setCurrentState(ByteState([1, 2, 3]), nowMilliseconds: 0)
        let clientBatch = try #require(try client.tick(nowMilliseconds: 20))

        _ = try deliver(clientBatch.packets, to: &server, nowMilliseconds: 21)

        let serverBatch = try #require(try server.tick(nowMilliseconds: 1_021))

        #expect(serverBatch.instruction.acknowledgementNumber == 1)
        #expect(serverBatch.packets.first?.plaintext.timestampReply == noReplyTimestamp)
    }

    @Test
    func serializedPacketReceiveUsesPacketPlaintextBoundary() throws {
        var client = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )
        var server = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            chaffSource: .none
        )

        client.setCurrentState(ByteState([1, 2, 3]), nowMilliseconds: 0)
        let batch = try #require(try client.tick(nowMilliseconds: 20))
        let packet = try #require(batch.packets.first)
        let result = try server.receive(
            serializedPacket: packet.plaintext.serializedBytes(),
            nowMilliseconds: 21
        )
        let instruction = try requireInstruction(result)

        #expect(instruction.receiveResult == .accepted(newNumber: 1))
        #expect(instruction.latestState.state.bytes == [1, 2, 3])
    }

    @Test
    func missingReferenceInstructionDoesNotAdvanceReceiverState() throws {
        var loop = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            chaffSource: .none
        )
        var fragmenter = MoshFragmenter()
        let instruction = MoshTransportInstruction(
            protocolVersion: 2,
            oldNumber: 99,
            newNumber: 100,
            acknowledgementNumber: 0,
            throwawayNumber: 0,
            diff: [1, 2, 3],
            chaff: []
        )
        let fragments = try fragmenter.makeFragments(
            for: instruction,
            maximumSerializedFragmentByteCount: 256
        )
        let fragment = try #require(fragments.first)
        let packet = MoshPacketPlaintext(
            timestamp: 42,
            timestampReply: 0,
            payload: fragment.serializedBytes()
        )

        let result = try requireInstruction(try loop.receive(packet, nowMilliseconds: 43))

        #expect(result.receiveResult == .missingReference(oldNumber: 99))
        #expect(result.acknowledgementNumber == 0)
        #expect(result.latestState == MoshNumberedState(number: 0, state: ByteState()))
    }

    // The outgoing packet timestamp must never be 0xFFFF, which is the wire's
    // "no timestamp" marker. Official Mosh `timestamp16` wraps it to 0.
    @Test
    func outgoingTimestampNeverEqualsNoTimestampSentinel() throws {
        var loop = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )

        // 65_535 truncates to 0xFFFF in 16 bits, which would otherwise collide
        // with the "no timestamp" sentinel.
        loop.setCurrentState(ByteState([1]), nowMilliseconds: 0)
        let batch = try #require(try loop.tick(nowMilliseconds: 65_535))
        let packet = try #require(batch.packets.first)

        #expect(packet.plaintext.timestamp != UInt16.max)
        #expect(packet.plaintext.timestamp == 0)
    }

    // A non-empty-diff state arms the delayed data-acknowledgement (official
    // Mosh `set_data_ack()` gated on `!inst.diff().empty()`), pulling the next
    // acknowledgement forward to now + 100ms. An empty-diff heartbeat updates the
    // ack number but must NOT arm the delayed data-ack, otherwise two instances
    // trade empty acks forever.
    @Test
    func emptyDiffHeartbeatDoesNotArmDelayedDataAcknowledgement() throws {
        var dataLoop = makeReceivingLoop()
        let dataInstruction = MoshTransportInstruction(
            protocolVersion: 2,
            oldNumber: 0,
            newNumber: 1,
            acknowledgementNumber: 0,
            throwawayNumber: 0,
            diff: [0x41],
            chaff: []
        )
        _ = try requireInstruction(
            try dataLoop.receive(singleFragmentPacket(for: dataInstruction), nowMilliseconds: 10)
        )
        // Delayed data-ack armed: next wakeup is the 100ms acknowledgement delay.
        #expect(try dataLoop.waitTime(nowMilliseconds: 10) == 100)

        var heartbeatLoop = makeReceivingLoop()
        let heartbeatInstruction = MoshTransportInstruction(
            protocolVersion: 2,
            oldNumber: 0,
            newNumber: 1,
            acknowledgementNumber: 0,
            throwawayNumber: 0,
            diff: [],
            chaff: []
        )
        _ = try requireInstruction(
            try heartbeatLoop.receive(singleFragmentPacket(for: heartbeatInstruction), nowMilliseconds: 10)
        )
        // No delayed data-ack: next wakeup stays on the idle 3000ms interval.
        #expect(try heartbeatLoop.waitTime(nowMilliseconds: 10) == 2_990)

        // The ack number is still updated for the heartbeat: when the idle
        // interval fires, the emitted acknowledgement carries the new state number.
        let heartbeatAcknowledgement = try #require(try heartbeatLoop.tick(nowMilliseconds: 3_000))
        #expect(heartbeatAcknowledgement.instruction.acknowledgementNumber == 1)
    }

    // A replayed / out-of-order datagram must not advance the connection's
    // `lastHeardAtMilliseconds` liveness signal nor re-arm the delayed
    // data-acknowledgement. Both are ordering-sensitive side effects gated on
    // `isInSequenceOrder`, mirroring official Mosh `Connection::recv_one`, which
    // returns an out-of-order datagram before touching `last_heard`. An
    // in-sequence, non-empty-diff datagram must still do both. Only the idempotent
    // ack-number advance and state application run for the out-of-order copy.
    @Test
    func replayedDatagramDoesNotAdvanceLastHeardOrRearmDataAcknowledgement() throws {
        var loop = makeReceivingLoop()
        let dataInstruction = MoshTransportInstruction(
            protocolVersion: 2,
            oldNumber: 0,
            newNumber: 1,
            acknowledgementNumber: 0,
            throwawayNumber: 0,
            diff: [0x41],
            chaff: []
        )
        let packet = try singleFragmentPacket(for: dataInstruction)

        // Before first contact the liveness signal is nil.
        #expect(loop.lastHeardAtMilliseconds == nil)

        // In-sequence delivery at t=10 applies state 1, advances last-heard, and
        // arms the delayed data-ack (next wakeup pulled forward to now + 100ms).
        let accepted = try requireInstruction(
            try loop.receive(packet, nowMilliseconds: 10, isInSequenceOrder: true)
        )
        #expect(accepted.receiveResult == .accepted(newNumber: 1))
        #expect(loop.lastHeardAtMilliseconds == 10)
        #expect(try loop.waitTime(nowMilliseconds: 10) == 100)

        // Fire the delayed data-ack so the scheduler falls back to its idle 3000ms
        // acknowledgement cadence (next acknowledgement now due at 110 + 3000 = 3110).
        _ = try #require(try loop.tick(nowMilliseconds: 110))
        #expect(loop.lastHeardAtMilliseconds == 10)

        // Replay the identical datagram, classified out-of-order, at a later clock.
        // It is deduped by state number; state is applied exactly once.
        let replay = try requireInstruction(
            try loop.receive(packet, nowMilliseconds: 200, isInSequenceOrder: false)
        )
        #expect(replay.receiveResult == .duplicate(newNumber: 1))
        #expect(replay.latestState.state.bytes == [0x41])

        // Last-heard is UNCHANGED by the replay: it must not be able to mask a real
        // outage in the liveness / no-contact signal. (Pre-fix this became 200.)
        #expect(loop.lastHeardAtMilliseconds == 10)

        // The delayed data-ack is NOT re-armed: the next wakeup stays on the idle
        // interval (3110 - 200 = 2910), not pulled forward to 200 + 100 by a
        // spurious data-ack. (Pre-fix this became 100.)
        #expect(try loop.waitTime(nowMilliseconds: 200) == 2_910)
    }

    @Test
    func shutdownAcknowledgementPrunesSenderThroughMaximumState() throws {
        var client = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )
        var server = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )

        client.startShutdown(nowMilliseconds: 0)
        let shutdownBatch = try #require(try client.tick(nowMilliseconds: 20))

        #expect(shutdownBatch.instruction.newNumber == UInt64.max)

        let serverResult = try deliver(shutdownBatch.packets, to: &server, nowMilliseconds: 21)

        #expect(serverResult.receiveResult == .accepted(newNumber: UInt64.max))
        #expect(server.acknowledgementNumber == UInt64.max)

        let serverAcknowledgement = try #require(try server.tick(nowMilliseconds: 21))

        #expect(serverAcknowledgement.instruction.acknowledgementNumber == UInt64.max)

        _ = try deliver(serverAcknowledgement.packets, to: &client, nowMilliseconds: 22)

        #expect(client.knownAcknowledgedSendStateNumber == UInt64.max)
        #expect(client.shutdownAcknowledged)
        #expect(client.shutdownTimedOut(nowMilliseconds: 10_000) == false)
    }
}

private func makeReceivingLoop() -> MoshSSPInMemoryLoop<ByteState, ByteState> {
    MoshSSPInMemoryLoop(
        initialSendState: ByteState(),
        initialReceiveState: ByteState(),
        chaffSource: .none
    )
}

private func singleFragmentPacket(
    for instruction: MoshTransportInstruction,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> MoshPacketPlaintext {
    var fragmenter = MoshFragmenter()
    let fragments = try fragmenter.makeFragments(
        for: instruction,
        maximumSerializedFragmentByteCount: 1_280
    )
    #expect(fragments.count == 1, "Test instruction must fit a single fragment.", sourceLocation: sourceLocation)
    let fragment = try #require(fragments.first, sourceLocation: sourceLocation)
    return MoshPacketPlaintext(
        timestamp: UInt16.max,
        timestampReply: UInt16.max,
        payload: fragment.serializedBytes()
    )
}

private func deliver<Packets: Sequence>(
    _ packets: Packets,
    to loop: inout MoshSSPInMemoryLoop<ByteState, ByteState>,
    nowMilliseconds: UInt64,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> MoshSSPIncomingInstructionResult<ByteState> where Packets.Element == MoshSSPOutgoingPacket {
    var completed: MoshSSPIncomingInstructionResult<ByteState>?
    for packet in packets {
        let result = try loop.receive(packet.plaintext, nowMilliseconds: nowMilliseconds)
        switch result {
        case .incompleteFragment:
            break
        case .instruction(let instructionResult):
            completed = instructionResult
        }
    }

    return try #require(completed, sourceLocation: sourceLocation)
}

private func requireInstruction(
    _ result: MoshSSPIncomingPacketResult<ByteState>,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> MoshSSPIncomingInstructionResult<ByteState> {
    guard case .instruction(let instructionResult) = result else {
        Issue.record("Expected a complete instruction.", sourceLocation: sourceLocation)
        throw TestFailure()
    }
    return instructionResult
}

private func receiveTimestampReply(
    _ timestampReply: UInt16,
    into loop: inout MoshSSPInMemoryLoop<ByteState, ByteState>,
    nowMilliseconds: UInt64
) throws {
    var fragmenter = MoshFragmenter()
    let instruction = MoshTransportInstruction(
        protocolVersion: 2,
        oldNumber: 99,
        newNumber: 100,
        acknowledgementNumber: 0,
        throwawayNumber: 0,
        diff: [0],
        chaff: []
    )
    let fragment = try #require(
        try fragmenter.makeFragments(
            for: instruction,
            maximumSerializedFragmentByteCount: 256
        ).first
    )
    let packet = MoshPacketPlaintext(
        timestamp: UInt16.max,
        timestampReply: timestampReply,
        payload: fragment.serializedBytes()
    )

    let result = try requireInstruction(try loop.receive(packet, nowMilliseconds: nowMilliseconds))

    #expect(result.receiveResult == .missingReference(oldNumber: 99))
}

private struct TestFailure: Error {}

private struct ByteState: MoshSynchronizedState {
    var bytes: [UInt8]

    init(_ bytes: [UInt8] = []) {
        self.bytes = bytes
    }

    func moshDiff(from base: ByteState) throws -> [UInt8] {
        guard self.bytes.starts(with: base.bytes) else {
            return self.bytes
        }
        return Array(self.bytes.dropFirst(base.bytes.count))
    }

    mutating func applyMoshDiff(_ diff: [UInt8]) throws {
        self.bytes.append(contentsOf: diff)
    }

    mutating func subtractMoshState(_ base: ByteState) throws {
        if self.bytes.starts(with: base.bytes) {
            self.bytes.removeFirst(base.bytes.count)
        }
    }
}
