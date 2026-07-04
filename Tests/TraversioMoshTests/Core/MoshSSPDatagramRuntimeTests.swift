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

    // A replayed (seq < expected) datagram is authentic — it passed OCB
    // authentication and the direction check in the sequencer — so it is still
    // delivered to the SSP loop rather than dropped before assembly. Because SSP
    // numbers its states, re-delivering an already-seen instruction is idempotent:
    // the receiver dedups it (`.duplicate`) and the latest state is unchanged.
    // This proves delivery without opening a replay hole. (Regression: this test
    // previously asserted the buggy behavior that a replayed datagram was
    // classified and dropped before packet assembly.)
    @Test
    func replayedDatagramIsDeliveredButDedupedByStateNumber() async throws {
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
            let replayInstruction = try requireRuntimeInstruction(replayResult)

            #expect(replayInstruction.receivedDatagram.sequenceStatus == .replayed(expectedNextSequence: 1))
            #expect(replayInstruction.instructionResult.receiveResult == .duplicate(newNumber: 1))
            #expect(await runtime.latestReceivedState().state.bytes == [0x41])

            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    // A two-fragment instruction whose datagrams arrive in reverse sequence order
    // must still assemble. The final fragment (higher datagram seq) arrives first
    // and advances the sequencer's expected sequence; the earlier fragment then
    // arrives as `.replayed` (seq < expected). The fix delivers that out-of-order
    // datagram's plaintext to the loop so the fragment assembler completes the
    // instruction instead of stalling until a retransmit.
    @Test
    func reorderedFragmentsAssembleWhenEarlierDatagramArrivesLast() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let runtime = try makeRuntime(
            link: pair.server,
            clock: clock,
            sendDirection: .toClient,
            receiveDirection: .toServer
        )
        var senderSequencer = try MoshDatagramSequencer(
            rawKey: runtimeKey,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )

        do {
            try await runtime.start()

            // Build a single instruction that spans two fragments. A deterministic,
            // low-compressibility diff plus a tiny fragment capacity guarantees the
            // instruction fragments into more than one datagram.
            var fragmenter = MoshFragmenter()
            let diffBytes = (0..<200).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
            let instruction = MoshTransportInstruction(
                protocolVersion: 2,
                oldNumber: 0,
                newNumber: 1,
                acknowledgementNumber: 0,
                throwawayNumber: 0,
                diff: diffBytes,
                chaff: []
            )
            let fragments = try fragmenter.makeFragments(
                for: instruction,
                maximumSerializedFragmentByteCount: MoshFragment.headerByteCount + 7
            )
            #expect(fragments.count >= 2)

            // Seal each fragment in fragment order, so fragment 0 rides the lower
            // datagram sequence and the final fragment rides the higher one.
            let datagrams = try fragments.map { fragment -> [UInt8] in
                let plaintext = MoshPacketPlaintext(
                    timestamp: 20,
                    timestampReply: UInt16.max,
                    payload: fragment.serializedBytes()
                )
                return try senderSequencer.seal(plaintext: plaintext.serializedBytes())
            }

            await clock.set(20)

            // Deliver in reverse datagram-sequence order: final fragment first.
            var completed: MoshSSPDatagramIncomingInstruction<ByteState>?
            for datagram in datagrams.reversed() {
                let result = try await runtime.receiveDatagram(datagram)
                if case .instruction(let delivered) = result {
                    completed = delivered
                }
            }

            let deliveredInstruction = try #require(completed)
            #expect(deliveredInstruction.instructionResult.receiveResult == .accepted(newNumber: 1))
            #expect(await runtime.latestReceivedState().state.bytes == diffBytes)
            // The instruction completed on an out-of-order (earlier) datagram; its
            // replayed sequence status is preserved on the yielded instruction,
            // confirming assembly finished on an out-of-sequence delivery rather
            // than on the leading in-order datagram.
            guard case .replayed = deliveredInstruction.receivedDatagram.sequenceStatus else {
                Issue.record("Expected the completing datagram to be out of order.")
                throw RuntimeTestFailure()
            }

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

    // Defect B (the crux): swapping the datagram link must preserve the crypto
    // session's monotonic send sequence. The first datagram sealed on the NEW link
    // must carry the NEXT sequence number, never 0 — otherwise the OCB nonce would
    // repeat under the same key and destroy confidentiality and authenticity. This
    // asserts continuity directly on the wire (decoding each datagram's nonce) AND
    // via the runtime's borrowed accessor.
    @Test
    func replaceLinkPreservesSendSequenceWithoutNonceReset() async throws {
        let pairA = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let runtime = try makeRuntime(
            link: pairA.client,
            clock: clock,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )
        // A bare cipher decodes the nonce off the wire without any replay/sequence
        // bookkeeping, so it reads exactly what the runtime sealed.
        let cipher = try MoshDatagramCipher(rawKey: runtimeKey)

        do {
            try await pairA.server.start()
            try await runtime.start()

            #expect(await runtime.nextSequenceToSend() == 0)

            await clock.set(0)
            await runtime.setCurrentState(ByteState([0x01]))
            await clock.set(20)
            _ = try #require(try await runtime.sendDueDatagrams())

            let firstDatagram = try #require(try await withRuntimeTimeout {
                try await nextDatagram(from: pairA.server)
            })
            let firstNonce = try cipher.open(datagram: firstDatagram).nonce
            #expect(firstNonce.sequence == 0)
            #expect(firstNonce.direction == .toServer)
            #expect(await runtime.nextSequenceToSend() == 1)

            // Swap in a fresh link to the same endpoint (a client port hop). The
            // sequencer and SSP loop are never read out, copied, or reset.
            let pairB = await MoshInMemoryDatagramLink.connectedPair()
            try await pairB.server.start()
            try await runtime.replaceLink(pairB.client)

            // Continuity holds across the swap: sealing did not reset.
            #expect(await runtime.nextSequenceToSend() == 1)

            await clock.set(100)
            await runtime.setCurrentState(ByteState([0x01, 0x02]))
            await clock.set(200)
            _ = try #require(try await runtime.sendDueDatagrams())

            let secondDatagram = try #require(try await withRuntimeTimeout {
                try await nextDatagram(from: pairB.server)
            })
            let secondNonce = try cipher.open(datagram: secondDatagram).nonce
            // THE assertion: the first datagram on the NEW link carries sequence 1,
            // the next sequence after the swap — not a reset to 0.
            #expect(secondNonce.sequence == 1)
            #expect(secondNonce.sequence != 0)
            #expect(secondNonce.direction == .toServer)
            #expect(await runtime.nextSequenceToSend() == 2)

            await runtime.stop()
            await pairA.server.stop()
            await pairB.server.stop()
        } catch {
            await runtime.stop()
            await pairA.server.stop()
            throw error
        }
    }

    // Defect A: a transient `link.send` failure must be recorded (not thrown) and
    // must not tear the runtime down; the SSP retransmit timer then re-delivers the
    // still-unacknowledged state once the link recovers.
    @Test
    func transientSendFailureIsRecordedThenUnackedStateRetransmits() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let timing = MoshSSPSendTimingConfiguration(
            sendIntervalMilliseconds: 20,
            acknowledgementIntervalMilliseconds: 1_000,
            activeRetryTimeoutMilliseconds: 10_000,
            sendMinimumDelayMilliseconds: 0,
            timeoutMilliseconds: 50
        )
        // The client's first outgoing send fails transiently; afterwards the link
        // forwards to the real in-memory peer (recovery).
        let clientLink = IntermittentForwardingLink(inner: pair.client, initialFailures: 1)
        let client = try makeRuntime(
            link: clientLink,
            clock: clock,
            sendDirection: .toServer,
            receiveDirection: .toClient,
            timing: timing
        )
        let server = try makeRuntime(
            link: pair.server,
            clock: clock,
            sendDirection: .toClient,
            receiveDirection: .toServer,
            timing: timing
        )
        let serverInstructionTask = Task<MoshSSPDatagramIncomingInstruction<ByteState>?, Error> {
            var iterator = server.incomingInstructions.makeAsyncIterator()
            return try await iterator.next()
        }

        do {
            try await client.start()
            try await server.start()

            await clock.set(0)
            await client.setCurrentState(ByteState([0x41]))

            // First send: the link rejects it. sendDueDatagrams must still return a
            // batch (the state is accounted for retransmit) and must NOT throw.
            await clock.set(20)
            let firstBatch = try await client.sendDueDatagrams()
            #expect(firstBatch != nil)
            #expect(await client.recordedSendError() != nil)

            // The runtime is alive: make the client hear from the server (so the
            // SSP retransmit branch, which requires recent contact, becomes active)
            // without acknowledging client state 1.
            await clock.set(40)
            await server.setCurrentState(ByteState([0x99]))
            _ = try await server.sendDueDatagrams()
            _ = try await withRuntimeTimeout {
                // Give the client's receive loop time to process the server datagram
                // (updates last-heard). Poll until contact is registered.
                while await client.lastHeardAtMilliseconds() == nil {
                    try await Task.sleep(for: .milliseconds(1))
                }
                return true
            }

            // Advance and retransmit until the recovered link delivers the unacked
            // state. The second (recovered) send succeeds and clears the error.
            var retransmitted = false
            for step in 1...50 where retransmitted == false {
                await clock.set(40 + UInt64(step) * 20)
                if try await client.sendDueDatagrams() != nil {
                    retransmitted = true
                }
            }
            #expect(retransmitted)
            #expect(await client.recordedSendError() == nil)

            let serverInstruction = try #require(try await withRuntimeTimeout {
                try await serverInstructionTask.value
            })
            // The server received the state that had failed to send initially,
            // proving automatic recovery after the transient failure.
            #expect(serverInstruction.instructionResult.latestState.state.bytes == [0x41])

            serverInstructionTask.cancel()
            await client.stop()
            await server.stop()
        } catch {
            serverInstructionTask.cancel()
            await client.stop()
            await server.stop()
            throw error
        }
    }

    // Defect C: a runtime abandoned WITHOUT an explicit `stop()` must still tear
    // down its datagram link, so the underlying socket cannot leak. The runtime's
    // `deinit` drives the link's `stop()`.
    @Test
    func abandonedRuntimeStopsLinkToPreventSocketLeak() async throws {
        let link = StopSpyDatagramLink()

        do {
            var runtime: MoshSSPDatagramRuntime<ByteState, ByteState>? = try makeRuntime(
                link: link,
                clock: ManualMillisecondsClock(),
                sendDirection: .toServer,
                receiveDirection: .toClient
            )
            try await runtime?.start()
            // Drop the only strong reference without calling stop().
            runtime = nil
        }

        // The deinit-driven stop runs on a detached task; poll briefly for it.
        let stopped = try await withRuntimeTimeout {
            while await link.stopCount() == 0 {
                try await Task.sleep(for: .milliseconds(1))
            }
            return true
        }
        #expect(stopped)
        #expect(await link.stopCount() >= 1)
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
    link: any MoshDatagramLink,
    clock: ManualMillisecondsClock,
    sendDirection: MoshPacketDirection,
    receiveDirection: MoshPacketDirection,
    timing: MoshSSPSendTimingConfiguration = MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20)
) throws -> MoshSSPDatagramRuntime<ByteState, ByteState> {
    let loop = MoshSSPInMemoryLoop(
        initialSendState: ByteState(),
        initialReceiveState: ByteState(),
        timing: timing,
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

private func nextDatagram(from link: MoshInMemoryDatagramLink) async throws -> [UInt8]? {
    var iterator = link.incomingDatagrams.makeAsyncIterator()
    return try await iterator.next()
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

/// Wraps a real in-memory link but rejects the first `initialFailures` sends with
/// a transient error before forwarding subsequent datagrams to the peer. Incoming
/// datagrams pass straight through from the inner link.
private actor IntermittentForwardingLink: MoshDatagramLink {
    nonisolated let incomingDatagrams: MoshDatagramStream

    private let inner: MoshInMemoryDatagramLink
    private let sendError: MoshDatagramTransportError
    private var failuresRemaining: Int

    init(
        inner: MoshInMemoryDatagramLink,
        initialFailures: Int,
        sendError: MoshDatagramTransportError = .notConnected
    ) {
        self.inner = inner
        self.incomingDatagrams = inner.incomingDatagrams
        self.failuresRemaining = initialFailures
        self.sendError = sendError
    }

    func start() async throws {
        try await self.inner.start()
    }

    func send(_ datagram: [UInt8]) async throws {
        if self.failuresRemaining > 0 {
            self.failuresRemaining -= 1
            throw self.sendError
        }
        try await self.inner.send(datagram)
    }

    func stop() async {
        await self.inner.stop()
    }
}

/// Records how many times `stop()` was invoked, so a leak/teardown test can prove
/// an abandoned runtime still stopped its link.
private actor StopSpyDatagramLink: MoshDatagramLink {
    nonisolated let incomingDatagrams: MoshDatagramStream

    private let continuation: MoshDatagramStream.Continuation
    private var stopCountStorage = 0

    init() {
        var capturedContinuation: MoshDatagramStream.Continuation?
        self.incomingDatagrams = MoshDatagramStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }
        self.continuation = capturedContinuation
    }

    func start() async throws {}

    func send(_ datagram: [UInt8]) async throws {
        _ = datagram
    }

    func stop() async {
        self.stopCountStorage += 1
        self.continuation.finish()
    }

    func stopCount() -> Int {
        self.stopCountStorage
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
