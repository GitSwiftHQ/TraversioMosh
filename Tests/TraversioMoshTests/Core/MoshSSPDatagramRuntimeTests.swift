// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCore
import TraversioMoshCrypto
import TraversioMoshTransport
import TraversioMoshWire

struct MoshSSPDatagramRuntimeTests {
    @Test
    func encryptedInMemoryRuntimeDeliversStateAndAcknowledgement() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let client = try makeRuntime(
            link: pair.client,
            clock: clock,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )
        let server = try makeRuntime(
            link: pair.server,
            clock: clock,
            sendDirection: .toClient,
            receiveDirection: .toServer
        )
        let serverReceiveTask = Task<MoshSSPDatagramIncomingInstruction<ByteState>?, Error> {
            var iterator = server.incomingInstructions.makeAsyncIterator()
            return try await iterator.next()
        }
        var clientReceiveTask: Task<MoshSSPDatagramIncomingInstruction<ByteState>?, Error>?

        do {
            try await client.start()
            try await server.start()

            await clock.set(0)
            await client.setCurrentState(ByteState([1, 2, 3]))

            await clock.set(20)
            let clientBatch = try #require(try await client.sendDueDatagrams())
            let firstClientPacket = try #require(clientBatch.packets.first)

            #expect(clientBatch.packets.count == 1)
            #expect(firstClientPacket.datagram != firstClientPacket.packet.plaintext.serializedBytes())

            let serverInstruction = try #require(try await withRuntimeTimeout {
                try await serverReceiveTask.value
            })

            #expect(serverInstruction.instructionResult.receiveResult == .accepted(newNumber: 1))
            #expect(serverInstruction.instructionResult.latestState.state.bytes == [1, 2, 3])
            #expect(await server.acknowledgementNumber() == 1)

            let activeClientReceiveTask = Task<MoshSSPDatagramIncomingInstruction<ByteState>?, Error> {
                var iterator = client.incomingInstructions.makeAsyncIterator()
                return try await iterator.next()
            }
            clientReceiveTask = activeClientReceiveTask

            await clock.set(120)
            let serverBatch = try #require(try await server.sendDueDatagrams())

            #expect(serverBatch.sspBatch.instruction.acknowledgementNumber == 1)

            let clientInstruction = try #require(try await withRuntimeTimeout {
                try await activeClientReceiveTask.value
            })

            #expect(clientInstruction.instructionResult.receiveResult == .accepted(newNumber: 1))
            #expect(await client.knownAcknowledgedSendStateNumber() == 1)

            clientReceiveTask?.cancel()
            serverReceiveTask.cancel()
            await client.stop()
            await server.stop()
        } catch {
            clientReceiveTask?.cancel()
            serverReceiveTask.cancel()
            await client.stop()
            await server.stop()
            throw error
        }
    }

    @Test
    func replayedDatagramIsClassifiedBeforePacketAssembly() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let runtime = try makeRuntime(
            link: pair.server,
            clock: clock,
            sendDirection: .toClient,
            receiveDirection: .toServer
        )
        var senderLoop = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )
        var senderSequencer = try MoshDatagramSequencer(
            rawKey: runtimeKey,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )

        do {
            try await runtime.start()

            senderLoop.setCurrentState(ByteState([0x41]), nowMilliseconds: 0)
            let batch = try #require(try senderLoop.tick(nowMilliseconds: 20))
            let packet = try #require(batch.packets.first)
            let datagram = try senderSequencer.seal(
                plaintext: packet.plaintext.serializedBytes()
            )

            await clock.set(20)
            let firstResult = try await runtime.receiveDatagram(datagram)
            let firstInstruction = try requireRuntimeInstruction(firstResult)

            #expect(firstInstruction.instructionResult.receiveResult == .accepted(newNumber: 1))
            #expect(await runtime.latestReceivedState().state.bytes == [0x41])

            let replayResult = try await runtime.receiveDatagram(datagram)

            guard case .replayedDatagram(let replay) = replayResult else {
                Issue.record("Expected replayed datagram classification.")
                throw RuntimeTestFailure()
            }
            #expect(replay.sequenceStatus == .replayed(expectedNextSequence: 1))
            #expect(await runtime.latestReceivedState().state.bytes == [0x41])

            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    @Test
    func receiveLoopDropsPacketLocalDatagramFailuresAndContinues() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let runtime = try makeRuntime(
            link: pair.server,
            clock: clock,
            sendDirection: .toClient,
            receiveDirection: .toServer
        )
        var senderLoop = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )
        var senderSequencer = try MoshDatagramSequencer(
            rawKey: runtimeKey,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )
        let instructionTask = Task<MoshSSPDatagramIncomingInstruction<ByteState>?, Error> {
            var iterator = runtime.incomingInstructions.makeAsyncIterator()
            return try await iterator.next()
        }

        do {
            try await pair.client.start()
            try await runtime.start()

            try await pair.client.send([0x01, 0x02, 0x03])
            try await pair.client.send(try tamperedAuthenticatedDatagram())

            senderLoop.setCurrentState(ByteState([0x42]), nowMilliseconds: 0)
            let batch = try #require(try senderLoop.tick(nowMilliseconds: 20))
            let packet = try #require(batch.packets.first)
            let validDatagram = try senderSequencer.seal(
                plaintext: packet.plaintext.serializedBytes()
            )

            await clock.set(20)
            try await pair.client.send(validDatagram)

            let instruction = try #require(try await withRuntimeTimeout {
                try await instructionTask.value
            })

            #expect(instruction.instructionResult.receiveResult == .accepted(newNumber: 1))
            #expect(instruction.instructionResult.latestState.state.bytes == [0x42])
            #expect(await runtime.latestReceivedState().state.bytes == [0x42])

            instructionTask.cancel()
            await runtime.stop()
            await pair.client.stop()
        } catch {
            instructionTask.cancel()
            await runtime.stop()
            await pair.client.stop()
            throw error
        }
    }
}

private actor ManualMillisecondsClock: MoshMillisecondsClock {
    private var nowMillisecondsStorage: UInt64 = 0

    func set(_ nowMilliseconds: UInt64) {
        self.nowMillisecondsStorage = nowMilliseconds
    }

    func nowMilliseconds() async -> UInt64 {
        self.nowMillisecondsStorage
    }
}

private func makeRuntime(
    link: MoshInMemoryDatagramLink,
    clock: ManualMillisecondsClock,
    sendDirection: MoshPacketDirection,
    receiveDirection: MoshPacketDirection
) throws -> MoshSSPDatagramRuntime<ByteState, ByteState> {
    let loop = MoshSSPInMemoryLoop(
        initialSendState: ByteState(),
        initialReceiveState: ByteState(),
        timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
        chaffSource: .none
    )
    let sequencer = try MoshDatagramSequencer(
        rawKey: runtimeKey,
        sendDirection: sendDirection,
        receiveDirection: receiveDirection
    )
    return MoshSSPDatagramRuntime(
        loop: loop,
        sequencer: sequencer,
        link: link,
        clock: clock
    )
}

private func requireRuntimeInstruction(
    _ result: MoshSSPDatagramIncomingPacketResult<ByteState>,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> MoshSSPDatagramIncomingInstruction<ByteState> {
    guard case .instruction(let instruction) = result else {
        Issue.record("Expected a complete runtime instruction.", sourceLocation: sourceLocation)
        throw RuntimeTestFailure()
    }
    return instruction
}

private func tamperedAuthenticatedDatagram() throws -> [UInt8] {
    let cipher = try MoshDatagramCipher(rawKey: runtimeKey)
    var datagram = try cipher.seal(
        plaintext: MoshPacketPlaintext(
            timestamp: 0,
            timestampReply: 0,
            payload: []
        ).serializedBytes(),
        sequence: 0,
        direction: .toServer
    )
    datagram[datagram.count - 1] ^= 0x01
    return datagram
}

private enum RuntimeTestError: Error, Equatable {
    case timedOut
}

private struct RuntimeTestFailure: Error {}

private func withRuntimeTimeout<T: Sendable>(
    after duration: Duration = .seconds(2),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: duration)
            throw RuntimeTestError.timedOut
        }

        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}

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

private let runtimeKey = Array(UInt8(0)..<UInt8(16))
