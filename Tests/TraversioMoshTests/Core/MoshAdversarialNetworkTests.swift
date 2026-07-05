// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

// Adversarial-network dimension for the Mosh data plane.
//
// The rest of the suite exercises the SSP/runtime over a LOSSLESS, ORDERED,
// ZERO-LATENCY in-memory link, so the very failure modes Mosh must survive
// (loss, duplication, reordering, transient send errors, link death) were
// structurally invisible. This file injects those faults deterministically and
// proves each landed remediation holds under adversity, and — because both ends
// run the SAME implementation — asserts observable PROTOCOL properties (final
// state equality AND bounded retransmit / bounded memory), not merely "both
// sides agree", to partially counter the same-implementation blind spot.
//
// Determinism (the suite must not flake): every fault decision is a pure
// function of a monotonically increasing SEND ORDINAL consulted against an
// explicit, test-orchestrated script or a fixed-seed SplitMix64 PRNG — never
// `Date`, `Task.sleep` wall-clock timing, or unseeded randomness. All protocol
// time is driven by an injected `ManualMillisecondsClock`; the only real-time
// use is a coarse safety timeout that turns a hang into a failure and never
// participates in sequencing.

import Testing
import TraversioMoshCore
import TraversioMoshCrypto
import TraversioMoshTransport
import TraversioMoshWire

struct MoshAdversarialNetworkTests {
    // WP4 (idempotent dedup by state number) + SSP retransmit under loss. The
    // client's first transmission of a state is DROPPED by the link; the SSP
    // active-retry timer must re-deliver the still-unacknowledged state so the
    // server converges, and a second retransmit must be deduped (`.duplicate`)
    // rather than re-applied — proving delivery is idempotent by state number.
    @Test
    func packetLossRetransmitsThenDedupsByStateNumber() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let timing = retransmitTiming
        let clientLink = FaultInjectingDatagramLink(inner: pair.client)
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
        // Two server-side instructions: the first accepted retransmit, then a
        // deduped duplicate.
        let serverInstructionsTask = collectInstructions(from: server, count: 2)

        do {
            try await clientLink.start()
            try await client.start()
            try await server.start()

            // Establish contact so the client has "heard" the server recently,
            // which the SSP active-retry retransmit branch requires.
            await clock.set(0)
            await server.setCurrentState(ByteState([0x99]))
            await clock.set(20)
            _ = try await server.sendDueDatagrams()
            try await waitUntilHeard(client)

            // The client's next transmission is dropped on the wire.
            await clock.set(40)
            await client.setCurrentState(ByteState([0x41]))
            await clientLink.dropNext(1)
            await clock.set(60)
            let droppedBatch = try await client.sendDueDatagrams()
            #expect(droppedBatch != nil)             // produced and accounted for retransmit
            #expect(await clientLink.droppedCount() == 1)
            #expect(await client.recordedSendError() == nil)  // a drop is not a send error

            // Advance to the retransmit deadline; the recovered link delivers it.
            await clock.set(210)
            _ = try await client.sendDueDatagrams()
            // Force one further retransmit (server never acked) to prove dedup.
            await clock.set(400)
            _ = try await client.sendDueDatagrams()

            let serverInstructions = try await withAdversarialTimeout {
                try await serverInstructionsTask.value
            }
            #expect(serverInstructions.count == 2)
            #expect(serverInstructions[0].instructionResult.receiveResult == .accepted(newNumber: 1))
            #expect(serverInstructions[1].instructionResult.receiveResult == .duplicate(newNumber: 1))
            // Idempotent: the state was applied exactly once.
            #expect(await server.latestReceivedState().state.bytes == [0x41])

            await client.stop()
            await server.stop()
            await clientLink.stop()
        } catch {
            serverInstructionsTask.cancel()
            await client.stop()
            await server.stop()
            await clientLink.stop()
            throw error
        }
    }

    // WP4 (out-of-order delivery / fragment reassembly). A single instruction
    // that spans two datagrams is delivered in REVERSE datagram order by the
    // link (the earlier fragment is held and released after the later one). The
    // full datagram path — seal, link, receive task, sequencer out-of-order
    // classification, fragment assembly — must still complete the instruction,
    // extending the runtime-unit reorder coverage to an end-to-end two-endpoint
    // flow.
    @Test
    func reorderedFragmentsAssembleThroughLinkAndReceiveTask() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let clientLink = FaultInjectingDatagramLink(inner: pair.client)
        // A tiny fragment capacity guarantees the low-compressibility diff spans
        // more than one datagram.
        let client = try makeRuntime(
            link: clientLink,
            clock: clock,
            sendDirection: .toServer,
            receiveDirection: .toClient,
            fragmentByteCount: MoshFragment.headerByteCount + 8
        )
        let server = try makeRuntime(
            link: pair.server,
            clock: clock,
            sendDirection: .toClient,
            receiveDirection: .toServer
        )
        let serverInstructionsTask = collectInstructions(from: server, count: 1)
        let diffBytes = (0..<200).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }

        do {
            try await clientLink.start()
            try await client.start()
            try await server.start()

            await clock.set(0)
            await client.setCurrentState(ByteState(diffBytes))
            // Hold the FIRST datagram of the batch. Every later fragment is
            // forwarded in order (arriving in-sequence); the held first fragment is
            // then released LAST, so it arrives out of order and the instruction
            // must complete on that out-of-sequence datagram.
            await clock.set(20)
            await clientLink.holdNext(1)
            let batch = try #require(try await client.sendDueDatagrams())
            #expect(batch.packets.count >= 2)      // genuinely fragmented
            try await clientLink.releaseHeld()

            let serverInstructions = try await withAdversarialTimeout {
                try await serverInstructionsTask.value
            }
            let assembled = try #require(serverInstructions.first)
            #expect(assembled.instructionResult.receiveResult == .accepted(newNumber: 1))
            #expect(await server.latestReceivedState().state.bytes == diffBytes)
            // The instruction completed on an out-of-order (replayed-seq) datagram.
            guard case .replayed = assembled.receivedDatagram.sequenceStatus else {
                Issue.record("Expected assembly to complete on an out-of-order datagram.")
                throw AdversarialTestFailure()
            }

            await client.stop()
            await server.stop()
            await clientLink.stop()
        } catch {
            serverInstructionsTask.cancel()
            await client.stop()
            await server.stop()
            await clientLink.stop()
            throw error
        }
    }

    // WP4 (duplicate dedup + replayed datagrams must not corrupt state or move
    // the RTT/timestamp estimators). The link duplicates a datagram, and the same
    // datagram is then replayed at a LATER clock. Each copy is deduped by state
    // number (idempotent: the state is applied exactly once) and — because its
    // sequence is below the expected next sequence — is classified out-of-order,
    // so the security-sensitive round-trip estimator must NOT move (a replay must
    // not be able to steer the RTT/timestamp clock).
    //
    // The `isInSequenceOrder` gate in MoshSSPInMemoryLoop.receive suppresses the
    // connection-level side effects (`noteRemoteHeard`/timestamp/RTT) for an
    // out-of-order datagram, matching official Mosh's `recv_one`, which returns
    // an out-of-order packet before touching `Connection::last_heard`. The
    // transport-level side effects — the transport-sender last-heard advance and
    // the delayed data-ack arming — follow a different official rule: they fire
    // whenever a genuinely NEW state is appended at the back of the receiver
    // queue (`Transport::recv`'s push_back path), regardless of datagram order.
    // A replayed datagram is deduped by state number and appends nothing, so it
    // advances NEITHER signal: only the idempotent ack pruning runs for the
    // returned out-of-order payload. A replay therefore cannot mask a real
    // outage in the liveness / no-contact signal or keep the active-retry timer
    // hot. This test asserts that invariant alongside the RTT/timestamp one.
    @Test
    func duplicateAndReplayAreDedupedAndDoNotMoveRoundTripEstimate() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let clientLink = FaultInjectingDatagramLink(inner: pair.client)
        let client = try makeRuntime(
            link: clientLink,
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
        // A single inline iterator so the clock can be advanced deterministically
        // BETWEEN the in-order deliveries and the late replay.
        var serverInstructions = server.incomingInstructions.makeAsyncIterator()

        do {
            try await clientLink.start()
            try await client.start()
            try await server.start()

            await clock.set(100)
            await client.setCurrentState(ByteState([0x41]))
            await clientLink.duplicateNext(1)          // link delivers it twice
            await clock.set(120)                       // past the send-minimum delay
            _ = try #require(try await client.sendDueDatagrams())

            // The exact datagram the link put on the wire, for a later manual replay.
            let capturedDatagram = try #require(await clientLink.lastForwardedDatagram())

            // Both copies were processed at clock 120 before the clock advances: the
            // first is accepted, the link's duplicate is deduped.
            let first = try #require(await serverInstructions.next())
            let second = try #require(await serverInstructions.next())
            #expect(first.instructionResult.receiveResult == .accepted(newNumber: 1))
            #expect(second.instructionResult.receiveResult == .duplicate(newNumber: 1))
            // The out-of-order round-trip estimator baseline, captured before replay.
            let smoothedBeforeReplay = await server.smoothedRoundTripMilliseconds()
            let variationBeforeReplay = await server.roundTripVariationMilliseconds()
            // The last-heard liveness baseline. The in-order delivery at clock 120
            // advanced it; the later replay must NOT move it.
            let lastHeardBeforeReplay = try #require(await server.lastHeardAtMilliseconds())

            // Replay the identical datagram much later, bypassing the fault link so
            // it reaches the server at a strictly greater clock value.
            await clock.set(5_000)
            try await pair.client.send(capturedDatagram)

            let replay = try #require(await serverInstructions.next())
            #expect(replay.instructionResult.receiveResult == .duplicate(newNumber: 1))
            // State applied exactly once (idempotent by state number).
            #expect(await server.latestReceivedState().state.bytes == [0x41])
            // The replay is out-of-order, so the RTT/timestamp estimators are
            // untouched — a replay cannot steer the round-trip clock.
            #expect(await server.smoothedRoundTripMilliseconds() == smoothedBeforeReplay)
            #expect(await server.roundTripVariationMilliseconds() == variationBeforeReplay)
            // The replay is out-of-order, so the last-heard liveness signal is also
            // untouched — it stays at the in-order delivery's clock (120), never the
            // replay's clock (5_000). A replay cannot mask a real server outage.
            #expect(await server.lastHeardAtMilliseconds() == lastHeardBeforeReplay)

            await client.stop()
            await server.stop()
            await clientLink.stop()
        } catch {
            await client.stop()
            await server.stop()
            await clientLink.stop()
            throw error
        }
    }

    // WP5 (transient send-error tolerance). The link rejects the client's send
    // attempts a fixed number of times before recovering. Each failure must be
    // recorded (not thrown) and must not tear the runtime down; the SSP
    // retransmit timer keeps re-sending until the recovered link delivers the
    // still-unacknowledged state and the server converges.
    @Test
    func transientSendFailuresAreToleratedAndStateConverges() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let timing = retransmitTiming
        let clientLink = FaultInjectingDatagramLink(inner: pair.client)
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
        let serverInstructionsTask = collectInstructions(from: server, count: 1)

        do {
            try await clientLink.start()
            try await client.start()
            try await server.start()

            await clock.set(0)
            await server.setCurrentState(ByteState([0x99]))
            await clock.set(20)
            _ = try await server.sendDueDatagrams()
            try await waitUntilHeard(client)

            // The next three send attempts fail transiently.
            await clock.set(40)
            await client.setCurrentState(ByteState([0x41]))
            await clientLink.failNext(3)

            await clock.set(60)
            _ = try await client.sendDueDatagrams()
            #expect(await client.recordedSendError() != nil)   // recorded, not thrown/fatal

            // Retransmit until the recovered link delivers the state.
            var recoveredClock: UInt64 = 40
            for _ in 0..<40 {
                recoveredClock += 200
                await clock.set(recoveredClock)
                _ = try await client.sendDueDatagrams()
                if await clientLink.forwardedCount() > 0 {
                    break
                }
            }
            #expect(await clientLink.failedSendCount() == 3)
            #expect(await clientLink.forwardedCount() >= 1)
            #expect(await client.recordedSendError() == nil)   // cleared on a good send

            let serverInstructions = try await withAdversarialTimeout {
                try await serverInstructionsTask.value
            }
            #expect(try #require(serverInstructions.first).instructionResult.latestState.state.bytes == [0x41])

            await client.stop()
            await server.stop()
            await clientLink.stop()
        } catch {
            serverInstructionsTask.cancel()
            await client.stop()
            await server.stop()
            await clientLink.stop()
            throw error
        }
    }

    // WP5 (survives a total-outage window). The link is fully PARTITIONED (every
    // datagram dropped) for a window while the client keeps trying to send state,
    // then the partition heals. The runtime must stay alive across the outage and
    // the SSP retransmit timer must re-deliver the still-unacknowledged state once
    // connectivity returns, so the server converges — the property that lets a
    // Mosh session survive arbitrarily long link outages.
    @Test
    func partitionWindowThenHealDeliversUnacknowledgedState() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let timing = retransmitTiming
        let clientLink = FaultInjectingDatagramLink(inner: pair.client)
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
        let serverInstructionsTask = collectInstructions(from: server, count: 1)

        do {
            try await clientLink.start()
            try await client.start()
            try await server.start()

            // Establish contact so the active-retry retransmit branch is eligible.
            await clock.set(0)
            await server.setCurrentState(ByteState([0x99]))
            await clock.set(20)
            _ = try await server.sendDueDatagrams()
            try await waitUntilHeard(client)

            // Partition the link: everything the client sends is dropped.
            await clientLink.setPartitioned(true)
            await clock.set(40)
            await client.setCurrentState(ByteState([0x41]))

            var outageClock: UInt64 = 40
            for _ in 0..<6 {
                outageClock += 200
                await clock.set(outageClock)
                _ = try await client.sendDueDatagrams()
            }
            // Nothing crossed the partition, and the runtime is still alive.
            #expect(await clientLink.forwardedCount() == 0)
            #expect(await clientLink.droppedCount() >= 1)

            // Heal, then retransmit: the still-unacknowledged state is delivered.
            await clientLink.setPartitioned(false)
            var healedClock = outageClock
            for _ in 0..<6 where await clientLink.forwardedCount() == 0 {
                healedClock += 200
                await clock.set(healedClock)
                _ = try await client.sendDueDatagrams()
            }
            #expect(await clientLink.forwardedCount() >= 1)

            let serverInstructions = try await withAdversarialTimeout {
                try await serverInstructionsTask.value
            }
            #expect(try #require(serverInstructions.first).instructionResult.latestState.state.bytes == [0x41])

            await client.stop()
            await server.stop()
            await clientLink.stop()
        } catch {
            serverInstructionsTask.cancel()
            await client.stop()
            await server.stop()
            await clientLink.stop()
            throw error
        }
    }

    // WP5 (link death + rebuild preserves the crypto session and send sequence).
    // The client's transport is KILLED mid-session (its incoming stream faults),
    // which the runtime surfaces as `.linkFailed` WITHOUT tearing the session
    // down. Both ends then rebuild onto a fresh link with `replaceLink`, which
    // must preserve the monotonic send sequence (no nonce reset) so post-swap
    // state is accepted `.new` by the server and converges. Driven at the runtime
    // layer because a mutual port-hop requires swapping BOTH endpoints' links,
    // which the runtime API exposes directly; `MoshSession`'s automatic rebuild
    // is covered by the existing session-level tests.
    @Test
    func linkDeathRebuildPreservesSendSequenceAndConverges() async throws {
        let pairA = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let clientLink = FaultInjectingDatagramLink(inner: pairA.client)
        let client = try makeRuntime(
            link: clientLink,
            clock: clock,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )
        let server = try makeRuntime(
            link: pairA.server,
            clock: clock,
            sendDirection: .toClient,
            receiveDirection: .toServer
        )
        var serverInstructions = server.incomingInstructions.makeAsyncIterator()

        do {
            try await clientLink.start()
            try await client.start()
            try await server.start()

            // State 1 over the original link.
            await clock.set(0)
            await client.setCurrentState(ByteState([0x01]))
            await clock.set(20)
            _ = try #require(try await client.sendDueDatagrams())
            let preSwap = try #require(await serverInstructions.next())
            #expect(preSwap.instructionResult.receiveResult == .accepted(newNumber: 1))
            let sequenceAfterState1 = await client.nextSequenceToSend()
            #expect(sequenceAfterState1 == 1)

            // Kill the client's transport. The runtime surfaces `.linkFailed` and
            // stays alive (crypto session + SSP state intact).
            await clientLink.failIncoming(MoshDatagramTransportError.notConnected)
            let event = try await withAdversarialTimeout { await firstLinkEvent(client) }
            guard case .linkFailed = event else {
                Issue.record("Expected a .linkFailed event.")
                throw AdversarialTestFailure()
            }

            // Mutual port hop onto a fresh link; sequence must NOT reset.
            let pairB = await MoshInMemoryDatagramLink.connectedPair()
            try await server.replaceLink(pairB.server)
            try await client.replaceLink(pairB.client)
            #expect(await client.nextSequenceToSend() == sequenceAfterState1)  // continuity

            // State 2 under load over the rebuilt link converges, and — proving no
            // nonce reset — is accepted `.new` (a reset to seq 0 would read as a
            // replayed sequence at the server and never advance its state).
            await clock.set(100)
            await client.setCurrentState(ByteState([0x01, 0x02]))
            await clock.set(120)
            _ = try #require(try await client.sendDueDatagrams())
            #expect(await client.nextSequenceToSend() == sequenceAfterState1 + 1)

            let postSwap = try #require(await serverInstructions.next())
            #expect(postSwap.instructionResult.receiveResult == .accepted(newNumber: 2))
            #expect(await server.latestReceivedState().state.bytes == [0x01, 0x02])

            await client.stop()
            await server.stop()
            await clientLink.stop()
            await pairB.client.stop()
            await pairB.server.stop()
        } catch {
            await client.stop()
            await server.stop()
            await clientLink.stop()
            throw error
        }
    }

    // WP3 (state-model rationalize + bounded retained state). Over a long session
    // of many acked client keystrokes AND many acked host diffs, the retained
    // sender state must stay bounded: `rationalize_states` cuts the acknowledged
    // common prefix so the retained operation payload collapses after acks, the
    // sent-state ring stays under its hard cap, and the receiver prunes history
    // via throwaway rather than accumulating it.
    @Test
    func longSessionRetainedStateStaysBounded() async throws {
        let timing = MoshSSPSendTimingConfiguration(
            sendIntervalMilliseconds: 20,
            sendMinimumDelayMilliseconds: 0
        )
        var client = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            timing: timing,
            chaffSource: .none
        )
        var server = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            timing: timing,
            chaffSource: .none
        )

        let rounds = 300
        var now: UInt64 = 0
        for round in 0..<rounds {
            now += 50
            // Client appends one keystroke byte (a growing delta, mirroring how
            // MoshSession appends client operations).
            client.modifyCurrentState(nowMilliseconds: now) { state in
                state.bytes.append(UInt8(truncatingIfNeeded: round))
            }
            if let clientBatch = try client.tick(nowMilliseconds: now) {
                for packet in clientBatch.packets {
                    _ = try server.receive(packet.plaintext, nowMilliseconds: now)
                }
            }

            // Server (host) also produces a diff each round; acknowledges the client.
            now += 50
            server.modifyCurrentState(nowMilliseconds: now) { state in
                state.bytes.append(UInt8(truncatingIfNeeded: round &* 7))
            }
            if let serverBatch = try server.tick(nowMilliseconds: now) {
                for packet in serverBatch.packets {
                    _ = try client.receive(packet.plaintext, nowMilliseconds: now)
                }
            }

            // Client acknowledges the host diff so the reverse direction also drains.
            now += 50
            if let ackBatch = try client.tick(nowMilliseconds: now) {
                for packet in ackBatch.packets {
                    _ = try server.receive(packet.plaintext, nowMilliseconds: now)
                }
            }
        }

        // Drain final acknowledgements so both directions reach their acked prefix,
        // then run one more timer recompute so `rationalize_states` fires.
        now += 3_000
        for _ in 0..<4 {
            if let serverAck = try server.tick(nowMilliseconds: now) {
                for packet in serverAck.packets {
                    _ = try client.receive(packet.plaintext, nowMilliseconds: now)
                }
            }
            if let clientAck = try client.tick(nowMilliseconds: now) {
                for packet in clientAck.packets {
                    _ = try server.receive(packet.plaintext, nowMilliseconds: now)
                }
            }
            now += 3_000
        }
        _ = try client.waitTime(nowMilliseconds: now)
        _ = try server.waitTime(nowMilliseconds: now)

        // Correctness: the server received every keystroke in order.
        let expectedKeystrokes = (0..<rounds).map { UInt8(truncatingIfNeeded: $0) }
        #expect(server.latestReceivedState.state.bytes == expectedKeystrokes)

        // Bounded memory (the crux). The sent-state ring never exceeds its hard cap,
        // and after full acknowledgement `rationalize_states` has cut the entire
        // acknowledged prefix out of the retained client state — so the retained
        // operation payload is a small constant, NOT proportional to the 300 rounds.
        let cap = MoshSSPSender<ByteState>.maximumSentStateCount
        #expect(client.scheduler.sender.sentStateNumbers.count <= cap)
        #expect(client.scheduler.sender.currentSendState.bytes.count == 0)
        // The receiver prunes history via throwaway rather than accumulating all
        // 300 states.
        #expect(server.receiver.stateNumbers.count <= 4)
        #expect(client.receiver.stateNumbers.count <= 4)

        _ = server // silence unused-warning paths on some toolchains
    }

    // WP4 (empty-diff heartbeat-ack gating). Two idle peers exchanging only
    // empty-diff heartbeats must settle to the ~3s acknowledgement cadence, NOT a
    // ~100ms empty-ack storm. An empty-diff heartbeat updates the ack number but
    // must not arm the delayed data-acknowledgement; otherwise each empty ack
    // mints a state the peer delay-acks in turn, forever.
    @Test
    func idlePeersSettleToHeartbeatCadenceWithoutAckStorm() async throws {
        var a = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            chaffSource: .none
        )
        var b = MoshSSPInMemoryLoop(
            initialSendState: ByteState(),
            initialReceiveState: ByteState(),
            chaffSource: .none
        )

        let horizon: UInt64 = 30_000
        var now: UInt64 = 0
        var totalHeartbeats = 0
        // Advance the shared clock to whichever peer is due next, tick both, and
        // exchange whatever they emit. A storm would drive the emitted-heartbeat
        // count toward horizon/100 (~600); the gated cadence keeps it near
        // horizon/3000 per side (~20 total).
        while now < horizon {
            let waitA = (try a.waitTime(nowMilliseconds: now)) ?? UInt64.max
            let waitB = (try b.waitTime(nowMilliseconds: now)) ?? UInt64.max
            let step = min(waitA, waitB)
            guard step != UInt64.max else {
                break
            }
            now += max(step, 1)

            if let batchA = try a.tick(nowMilliseconds: now) {
                totalHeartbeats += batchA.packets.count
                for packet in batchA.packets {
                    _ = try b.receive(packet.plaintext, nowMilliseconds: now)
                }
            }
            if let batchB = try b.tick(nowMilliseconds: now) {
                totalHeartbeats += batchB.packets.count
                for packet in batchB.packets {
                    _ = try a.receive(packet.plaintext, nowMilliseconds: now)
                }
            }
        }

        // Cadence, not storm: far below the ~600 an empty-ack ping-pong produces.
        #expect(totalHeartbeats <= 40)
        // Each idle peer's next wakeup is on the multi-second heartbeat interval,
        // never the 100ms delayed-ack interval.
        #expect(try #require(try a.waitTime(nowMilliseconds: now)) > 1_000)
        #expect(try #require(try b.waitTime(nowMilliseconds: now)) > 1_000)
    }

    // WP1 (wire robustness / strict malformed-datagram policy). A peer that
    // passes OCB authentication and the direction check but whose plaintext
    // carries a MALFORMED fragment payload triggers a non-packet-local failure.
    // Per the strict failure policy this is fatal and owned by the runtime: the
    // receive task tears the runtime down (finishing `incomingInstructions` with
    // the wire error) rather than silently tolerating a corrupt authenticated
    // stream.
    @Test
    func authenticatedMalformedFragmentTearsRuntimeDown() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let runtime = try makeRuntime(
            link: pair.server,
            clock: clock,
            sendDirection: .toClient,
            receiveDirection: .toServer
        )
        // Seals as the client would (runtime receives on `.toServer`).
        var senderSequencer = try MoshDatagramSequencer(
            rawKey: adversarialKey,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )
        let instructionTask = Task<Void, Error> {
            var iterator = runtime.incomingInstructions.makeAsyncIterator()
            while try await iterator.next() != nil {}
        }

        do {
            try await pair.client.start()
            try await runtime.start()

            // Authentic (OCB seals it, correct direction, in-sequence) but the
            // packet payload is too short to be a fragment header — a wire-level
            // malformation, NOT a crypto/packet-local error.
            let malformedPlaintext = MoshPacketPlaintext(
                timestamp: 20,
                timestampReply: UInt16.max,
                payload: [0x00]
            )
            let datagram = try senderSequencer.seal(plaintext: malformedPlaintext.serializedBytes())
            await clock.set(20)
            try await pair.client.send(datagram)

            // The receive task finished the stream with the wire error.
            await #expect(throws: MoshPacketWireError.self) {
                try await withAdversarialTimeout { try await instructionTask.value }
            }
            // The runtime is torn down: further receives are rejected as stopped.
            await #expect(throws: MoshSSPDatagramRuntimeError.stopped) {
                _ = try await runtime.receiveDatagram(datagram)
            }

            await runtime.stop()
            await pair.client.stop()
        } catch {
            instructionTask.cancel()
            await runtime.stop()
            await pair.client.stop()
            throw error
        }
    }

    // WP5 (packet-local receive tolerance) / WP2 (crypto authentication). A
    // malformed UNAUTHENTICATED datagram (its OCB tag fails to verify) is a
    // packet-local error: it is dropped inside the receive loop without tearing
    // the runtime down, and a subsequent valid datagram is still delivered.
    @Test
    func unauthenticatedMalformedDatagramIsDroppedWithoutTeardown() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let runtime = try makeRuntime(
            link: pair.server,
            clock: clock,
            sendDirection: .toClient,
            receiveDirection: .toServer
        )
        var senderSequencer = try MoshDatagramSequencer(
            rawKey: adversarialKey,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )
        let instructionTask = collectInstructions(from: runtime, count: 1)

        do {
            try await pair.client.start()
            try await runtime.start()

            // A datagram whose ciphertext has been tampered fails OCB authentication.
            let cipher = try MoshDatagramCipher(rawKey: adversarialKey)
            var tampered = try cipher.seal(
                plaintext: MoshPacketPlaintext(timestamp: 0, timestampReply: 0, payload: []).serializedBytes(),
                sequence: 0,
                direction: .toServer
            )
            tampered[tampered.count - 1] ^= 0x01
            try await pair.client.send(tampered)

            // A well-formed authentic datagram after the dropped one.
            let plaintext = MoshPacketPlaintext(
                timestamp: 20,
                timestampReply: UInt16.max,
                payload: try singleFragmentPayload(
                    for: ByteState([0x42]),
                    from: ByteState(),
                    newNumber: 1
                )
            )
            let valid = try senderSequencer.seal(plaintext: plaintext.serializedBytes())
            await clock.set(20)
            try await pair.client.send(valid)

            let instructions = try await withAdversarialTimeout { try await instructionTask.value }
            let delivered = try #require(instructions.first)
            #expect(delivered.instructionResult.receiveResult == .accepted(newNumber: 1))
            #expect(await runtime.latestReceivedState().state.bytes == [0x42])

            await runtime.stop()
            await pair.client.stop()
        } catch {
            instructionTask.cancel()
            await runtime.stop()
            await pair.client.stop()
            throw error
        }
    }

    // Convergence property under seeded pseudo-random loss on BOTH directions.
    // Because both ends run the same implementation, "both sides agree" is a weak
    // check; this asserts OBSERVABLE PROTOCOL PROPERTIES: the server converges to
    // the exact client state (final-state equality) AND memory stays bounded (the
    // sent-state ring under its cap, the receiver history pruned) despite ~35% of
    // datagrams being dropped each way. Guards WP4 (out-of-order/retransmit
    // delivery) and WP3 (bounded retained state) jointly.
    @Test
    func convergenceUnderSeededLossReachesEqualStateWithBoundedMemory() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let clock = ManualMillisecondsClock()
        let timing = retransmitTiming
        let clientLink = FaultInjectingDatagramLink(
            inner: pair.client,
            seededDrop: SeededDropPolicy(seed: 0xA5A5_1234, dropPercent: 35)
        )
        let serverLink = FaultInjectingDatagramLink(
            inner: pair.server,
            seededDrop: SeededDropPolicy(seed: 0x5A5A_9876, dropPercent: 35)
        )
        let client = try makeRuntime(
            link: clientLink,
            clock: clock,
            sendDirection: .toServer,
            receiveDirection: .toClient,
            timing: timing
        )
        let server = try makeRuntime(
            link: serverLink,
            clock: clock,
            sendDirection: .toClient,
            receiveDirection: .toServer,
            timing: timing
        )

        do {
            try await clientLink.start()
            try await serverLink.start()
            try await client.start()
            try await server.start()

            let targetByteCount = 12
            var now: UInt64 = 0
            var appended = 0
            var converged = false

            // Deterministic driver: advance the clock, let each end append (up to the
            // target) and flush due datagrams. Seeded drops decide loss purely from
            // the send ordinal, so the run is byte-for-byte reproducible.
            for _ in 0..<4_000 {
                now += 200
                await clock.set(now)
                if appended < targetByteCount {
                    let nextByte = UInt8(truncatingIfNeeded: appended)
                    await client.modifyCurrentState { state in
                        state.bytes.append(nextByte)
                    }
                    appended += 1
                }
                _ = try? await client.sendDueDatagrams()
                _ = try? await server.sendDueDatagrams()   // acks + heartbeats (also lossy)

                if appended == targetByteCount,
                   await server.latestReceivedState().state.bytes.count == targetByteCount {
                    converged = true
                    break
                }
            }

            let target = (0..<targetByteCount).map { UInt8(truncatingIfNeeded: $0) }
            #expect(converged)
            // Final-state equality: the server holds exactly the client's state
            // despite heavy bidirectional loss — an observable protocol property,
            // not merely "both sides agree".
            #expect(await server.latestReceivedState().state.bytes == target)
            // Loss really happened on both directions (the scenario is adversarial).
            #expect(await clientLink.droppedCount() > 0)
            #expect(await serverLink.droppedCount() > 0)
            // Bounded memory despite the retransmit churn: the unacknowledged send
            // window never exceeds the sent-state ring cap.
            let cap = UInt64(MoshSSPSender<ByteState>.maximumSentStateCount)
            let lastSent = await client.lastSentSendStateNumber()
            let knownAck = await client.knownAcknowledgedSendStateNumber()
            let unacknowledged = lastSent >= knownAck ? lastSent - knownAck : 0
            #expect(unacknowledged <= cap)

            await client.stop()
            await server.stop()
            await clientLink.stop()
            await serverLink.stop()
        } catch {
            await client.stop()
            await server.stop()
            await clientLink.stop()
            await serverLink.stop()
            throw error
        }
    }
}

// MARK: - Deterministic fault-injecting link (test support)

/// A deterministic, seed/script-driven fault-injecting datagram link that
/// decorates an inner `MoshDatagramLink`.
///
/// It owns its own incoming stream and relays the inner link's datagrams into
/// it, so a test can also fault the INCOMING path (`failIncoming`) to model
/// transport death. All outbound fault decisions are a pure function of a
/// monotonically increasing send ordinal against either explicit,
/// test-orchestrated controls (`dropNext`/`failNext`/`duplicateNext`/`holdNext`/
/// `setPartitioned`) or a fixed-seed `SeededDropPolicy` — never wall-clock time
/// or unseeded randomness — so a run is reproducible regardless of task
/// scheduling.
private actor FaultInjectingDatagramLink: MoshDatagramLink {
    nonisolated let incomingDatagrams: MoshDatagramStream

    private let inner: any MoshDatagramLink
    private let incomingContinuation: MoshDatagramStream.Continuation
    private let sendError: MoshDatagramTransportError
    private let seededDrop: SeededDropPolicy?

    private var relayTask: Task<Void, Never>?
    private var isStarted = false
    private var sendOrdinal = 0
    private var dropNextCount = 0
    private var failNextCount = 0
    private var duplicateNextCount = 0
    private var holdNextCount = 0
    private var isPartitioned = false
    private var heldDatagrams: [[UInt8]] = []

    private var forwardedCountStorage = 0
    private var droppedCountStorage = 0
    private var failedSendCountStorage = 0
    private var duplicatedCountStorage = 0
    private var lastForwardedDatagramStorage: [UInt8]?

    init(
        inner: any MoshDatagramLink,
        sendError: MoshDatagramTransportError = .notConnected,
        seededDrop: SeededDropPolicy? = nil
    ) {
        self.inner = inner
        self.sendError = sendError
        self.seededDrop = seededDrop
        var capturedContinuation: MoshDatagramStream.Continuation?
        self.incomingDatagrams = MoshDatagramStream(
            bufferingPolicy: .bufferingNewest(256)
        ) { continuation in
            capturedContinuation = continuation
        }
        guard let capturedContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }
        self.incomingContinuation = capturedContinuation
    }

    func start() async throws {
        // Idempotent: the runtime's `start()`/`replaceLink` also calls `start()`,
        // and a second relay task on the same inner stream would be a double
        // consumer. Start the inner link and the single relay exactly once.
        try await self.inner.start()
        guard self.isStarted == false else {
            return
        }
        self.isStarted = true
        let stream = self.inner.incomingDatagrams
        let continuation = self.incomingContinuation
        self.relayTask = Task {
            do {
                for try await datagram in stream {
                    continuation.yield(datagram)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func send(_ datagram: [UInt8]) async throws {
        self.sendOrdinal += 1

        if self.isPartitioned {
            self.droppedCountStorage += 1
            return
        }
        if let seededDrop, seededDrop.shouldDrop(ordinal: self.sendOrdinal) {
            self.droppedCountStorage += 1
            return
        }
        if self.dropNextCount > 0 {
            self.dropNextCount -= 1
            self.droppedCountStorage += 1
            return
        }
        if self.failNextCount > 0 {
            self.failNextCount -= 1
            self.failedSendCountStorage += 1
            throw self.sendError
        }
        if self.holdNextCount > 0 {
            self.holdNextCount -= 1
            self.heldDatagrams.append(datagram)
            return
        }

        let copies = self.duplicateNextCount > 0 ? 2 : 1
        if self.duplicateNextCount > 0 {
            self.duplicateNextCount -= 1
            self.duplicatedCountStorage += 1
        }
        for _ in 0..<copies {
            try await self.forward(datagram)
        }
    }

    /// Forwards previously held datagrams (in FIFO order) so they arrive AFTER
    /// everything sent while they were held — a deterministic reorder driven
    /// explicitly by the test.
    func releaseHeld() async throws {
        let released = self.heldDatagrams
        self.heldDatagrams.removeAll()
        for held in released {
            try await self.forward(held)
        }
    }

    func stop() async {
        self.relayTask?.cancel()
        self.relayTask = nil
        await self.inner.stop()
        self.incomingContinuation.finish()
    }

    // Fault the incoming path to model transport death.
    func failIncoming(_ error: Error) {
        self.relayTask?.cancel()
        self.relayTask = nil
        self.incomingContinuation.finish(throwing: error)
    }

    // Test-orchestrated, deterministic controls.
    func dropNext(_ count: Int) { self.dropNextCount += count }
    func failNext(_ count: Int) { self.failNextCount += count }
    func duplicateNext(_ count: Int) { self.duplicateNextCount += count }
    func holdNext(_ count: Int) { self.holdNextCount += count }
    func setPartitioned(_ partitioned: Bool) { self.isPartitioned = partitioned }

    func forwardedCount() -> Int { self.forwardedCountStorage }
    func droppedCount() -> Int { self.droppedCountStorage }
    func failedSendCount() -> Int { self.failedSendCountStorage }
    func duplicatedCount() -> Int { self.duplicatedCountStorage }
    func lastForwardedDatagram() -> [UInt8]? { self.lastForwardedDatagramStorage }

    private func forward(_ datagram: [UInt8]) async throws {
        try await self.inner.send(datagram)
        self.forwardedCountStorage += 1
        self.lastForwardedDatagramStorage = datagram
    }
}

/// A fixed-seed SplitMix64 PRNG. Deterministic and self-contained.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        self.state = self.state &+ 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Decides datagram loss as a pure function of the send ordinal, so the drop
/// pattern is independent of task scheduling and reproducible across runs.
private struct SeededDropPolicy: Sendable {
    let seed: UInt64
    let dropPercent: UInt64

    func shouldDrop(ordinal: Int) -> Bool {
        var generator = SplitMix64(seed: self.seed &+ UInt64(ordinal))
        return generator.next() % 100 < self.dropPercent
    }
}

// MARK: - Shared fixtures

private let adversarialKey = Array(UInt8(0)..<UInt8(16))

private let retransmitTiming = MoshSSPSendTimingConfiguration(
    sendIntervalMilliseconds: 20,
    acknowledgementIntervalMilliseconds: 1_000,
    activeRetryTimeoutMilliseconds: 10_000,
    sendMinimumDelayMilliseconds: 0,
    timeoutMilliseconds: 50
)

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
    timing: MoshSSPSendTimingConfiguration = MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
    fragmentByteCount: Int = MoshSSPDatagramBudget.defaultMaximumSerializedFragmentByteCount
) throws -> MoshSSPDatagramRuntime<ByteState, ByteState> {
    let loop = MoshSSPInMemoryLoop(
        initialSendState: ByteState(),
        initialReceiveState: ByteState(),
        timing: timing,
        maximumSerializedFragmentByteCount: fragmentByteCount,
        chaffSource: .none
    )
    let sequencer = try MoshDatagramSequencer(
        rawKey: adversarialKey,
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

private func singleFragmentPayload(
    for state: ByteState,
    from base: ByteState,
    newNumber: UInt64
) throws -> [UInt8] {
    var fragmenter = MoshFragmenter()
    let instruction = MoshTransportInstruction(
        protocolVersion: 2,
        oldNumber: 0,
        newNumber: newNumber,
        acknowledgementNumber: 0,
        throwawayNumber: 0,
        diff: try state.moshDiff(from: base),
        chaff: []
    )
    let fragments = try fragmenter.makeFragments(
        for: instruction,
        maximumSerializedFragmentByteCount: 256
    )
    guard fragments.count == 1, let fragment = fragments.first else {
        throw AdversarialTestFailure()
    }
    return fragment.serializedBytes()
}

private func collectInstructions(
    from runtime: MoshSSPDatagramRuntime<ByteState, ByteState>,
    count: Int
) -> Task<[MoshSSPDatagramIncomingInstruction<ByteState>], Error> {
    Task {
        var iterator = runtime.incomingInstructions.makeAsyncIterator()
        var instructions: [MoshSSPDatagramIncomingInstruction<ByteState>] = []
        while instructions.count < count {
            guard let instruction = try await iterator.next() else {
                break
            }
            instructions.append(instruction)
        }
        return instructions
    }
}

private func firstLinkEvent(
    _ runtime: MoshSSPDatagramRuntime<ByteState, ByteState>
) async -> MoshSSPDatagramRuntimeLinkEvent? {
    var iterator = runtime.linkEvents.makeAsyncIterator()
    return await iterator.next()
}

/// Polls the runtime's informational last-heard signal until first contact is
/// registered. The `Task.sleep(1ms)` is a scheduling yield, not protocol timing:
/// the manual clock governs all SSP time, and the safety timeout bounds it.
private func waitUntilHeard(
    _ runtime: MoshSSPDatagramRuntime<ByteState, ByteState>
) async throws {
    _ = try await withAdversarialTimeout {
        while await runtime.lastHeardAtMilliseconds() == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}

private enum AdversarialTestError: Error, Equatable {
    case timedOut
}

private struct AdversarialTestFailure: Error {}

/// Coarse real-time safety net: turns a hang into a test failure. It never
/// participates in protocol sequencing (that is the manual clock's job).
private func withAdversarialTimeout<T: Sendable>(
    after duration: Duration = .seconds(5),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: duration)
            throw AdversarialTestError.timedOut
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
