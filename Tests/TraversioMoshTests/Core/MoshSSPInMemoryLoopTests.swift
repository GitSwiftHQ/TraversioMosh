// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCore
import TraversioMoshWire

struct MoshSSPInMemoryLoopTests {
    @Test
    func fragmentedStateUpdateRoundTripsAndAcknowledges() throws {
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
        #expect(clientBatch.packets.first?.plaintext.timestampReply == 0)

        let receiveResult = try deliver(clientBatch.packets.reversed(), to: &server, nowMilliseconds: 21)

        #expect(receiveResult.receiveResult == .accepted(newNumber: 1))
        #expect(receiveResult.latestState.state == state)
        #expect(server.acknowledgementNumber == 1)

        let acknowledgementBatch = try #require(try server.tick(nowMilliseconds: 121))

        #expect(acknowledgementBatch.instruction.acknowledgementNumber == 1)
        #expect(acknowledgementBatch.instruction.diff == [])
        #expect(acknowledgementBatch.packets.first?.plaintext.timestamp == 121)
        #expect(acknowledgementBatch.packets.first?.plaintext.timestampReply == 20)

        _ = try deliver(acknowledgementBatch.packets, to: &client, nowMilliseconds: 122)

        #expect(client.knownAcknowledgedSendStateNumber == 1)
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
