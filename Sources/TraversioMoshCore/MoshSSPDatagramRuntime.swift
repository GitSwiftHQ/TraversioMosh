// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Dispatch
import TraversioMoshCrypto
import TraversioMoshTransport
import TraversioMoshWire

public protocol MoshMillisecondsClock: Sendable {
    func nowMilliseconds() async -> UInt64
}

public struct MoshSystemMillisecondsClock: MoshMillisecondsClock {
    public init() {}

    public func nowMilliseconds() async -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}

public enum MoshSSPDatagramRuntimeError: Error, Equatable, Sendable {
    case notStarted
    case stopped
}

public enum MoshSSPDatagramRuntimeLinkEvent: Equatable, Sendable {
    /// The datagram link's incoming stream terminated with an error: the underlying
    /// transport died (e.g. an `NWConnection` reached `.failed`, or an injected
    /// transport failure fired). The runtime deliberately does NOT tear itself down
    /// on this signal — it keeps the crypto session (`MoshDatagramSequencer`), the
    /// SSP loop/state, and the `incomingInstructions` stream intact, and stops only
    /// the dead link. The owner should install a fresh link with `replaceLink(_:)`
    /// to resume against the same session (see `MoshSession`'s bounded rebuild).
    /// Carries the failure's textual description because `Error` is neither
    /// `Equatable` nor reliably `Sendable`.
    case linkFailed(String)
}

public struct MoshSSPDatagramOutgoingPacket: Equatable, Sendable {
    public let packet: MoshSSPOutgoingPacket
    public let datagram: [UInt8]

    public init(packet: MoshSSPOutgoingPacket, datagram: [UInt8]) {
        self.packet = packet
        self.datagram = datagram
    }
}

public struct MoshSSPDatagramOutgoingBatch: Equatable, Sendable {
    public let sspBatch: MoshSSPOutgoingBatch
    public let packets: [MoshSSPDatagramOutgoingPacket]

    public init(
        sspBatch: MoshSSPOutgoingBatch,
        packets: [MoshSSPDatagramOutgoingPacket]
    ) {
        self.sspBatch = sspBatch
        self.packets = packets
    }
}

public struct MoshSSPDatagramIncomingInstruction<ReceiveState: MoshSynchronizedState>: Equatable, Sendable {
    public let receivedDatagram: MoshReceivedDatagram
    public let packet: MoshPacketPlaintext
    public let instructionResult: MoshSSPIncomingInstructionResult<ReceiveState>

    public init(
        receivedDatagram: MoshReceivedDatagram,
        packet: MoshPacketPlaintext,
        instructionResult: MoshSSPIncomingInstructionResult<ReceiveState>
    ) {
        self.receivedDatagram = receivedDatagram
        self.packet = packet
        self.instructionResult = instructionResult
    }
}

public enum MoshSSPDatagramIncomingPacketResult<ReceiveState: MoshSynchronizedState>: Equatable, Sendable {
    case incompleteFragment(receivedDatagram: MoshReceivedDatagram, packet: MoshPacketPlaintext)
    case instruction(MoshSSPDatagramIncomingInstruction<ReceiveState>)
}

public actor MoshSSPDatagramRuntime<
    SendState: MoshSynchronizedState,
    ReceiveState: MoshSynchronizedState
> {
    public typealias IncomingInstructionStream = AsyncThrowingStream<
        MoshSSPDatagramIncomingInstruction<ReceiveState>,
        Error
    >

    public nonisolated let incomingInstructions: IncomingInstructionStream
    /// Out-of-band transport-lifecycle signals (currently `.linkFailed`). Distinct
    /// from `incomingInstructions`, which stays open across a link failure so the
    /// same session can be resumed on a fresh link.
    public nonisolated let linkEvents: AsyncStream<MoshSSPDatagramRuntimeLinkEvent>

    private var link: any MoshDatagramLink
    private let clock: any MoshMillisecondsClock
    private let incomingContinuation: IncomingInstructionStream.Continuation
    private let linkEventContinuation: AsyncStream<MoshSSPDatagramRuntimeLinkEvent>.Continuation
    private var loop: MoshSSPInMemoryLoop<SendState, ReceiveState>
    private var sequencer: MoshDatagramSequencer
    private var receiveTask: Task<Void, Never>?
    /// Monotonic tag identifying the currently-installed link's receive task. A
    /// link swap (`replaceLink`) or teardown bumps it so the previous receive
    /// task's completion handler becomes a no-op and cannot finish or fail the
    /// runtime out from under the new link.
    private var receiveGeneration: UInt64 = 0
    /// Description of the most recent transient `link.send` failure that was
    /// recorded rather than propagated. Mirrors official Mosh
    /// `Connection::send_error` (`network/network.cc` ~378-386): informational, and
    /// cleared once a send succeeds.
    private var recordedSendErrorDescription: String?
    /// Greatest clock value already applied to the SSP loop. The loop/sender assume
    /// a monotonic non-decreasing timeline (official Mosh feeds a monotonic
    /// `timestamp()` derived from `CLOCK_MONOTONIC`; `MoshSSPSender.updateAssumedReceiverState`
    /// enforces `now >= lastSentAt`). Every loop-advancing entry point reads the clock
    /// behind an `await` suspension, so actor reentrancy can interleave two such calls
    /// and apply a later-read value that is momentarily *below* one already fed to the
    /// loop — even though the underlying clock never runs backward. Clamping the applied
    /// value to this high-water mark at the runtime boundary restores the monotonic
    /// timeline the loop is written against, so a benign interleaving skew can no longer
    /// trip the sender's clock-moved-backward guard and tear the session down. It does
    /// not weaken that guard: it is a lower-level invariant still exercised directly, and
    /// the system clock does not produce genuine backward jumps here.
    private var lastAppliedNowMilliseconds: UInt64 = 0
    private var isStarted = false
    private var isStopped = false

    public init(
        loop: MoshSSPInMemoryLoop<SendState, ReceiveState>,
        sequencer: consuming MoshDatagramSequencer,
        link: any MoshDatagramLink,
        clock: any MoshMillisecondsClock = MoshSystemMillisecondsClock(),
        bufferingPolicy: IncomingInstructionStream.Continuation.BufferingPolicy = .bufferingNewest(256)
    ) {
        let streamAndContinuation = Self.makeIncomingInstructionStream(bufferingPolicy: bufferingPolicy)
        self.incomingInstructions = streamAndContinuation.stream
        self.incomingContinuation = streamAndContinuation.continuation
        let linkEventStreamAndContinuation = Self.makeLinkEventStream()
        self.linkEvents = linkEventStreamAndContinuation.stream
        self.linkEventContinuation = linkEventStreamAndContinuation.continuation
        self.loop = loop
        self.sequencer = sequencer
        self.link = link
        self.clock = clock
    }

    /// Even if the runtime is abandoned without an explicit `stop()`, cancel the
    /// receive task and stop the current link so its underlying socket cannot leak.
    /// `deinit` cannot `await`, so the async `stop()` is driven from a detached task
    /// that owns the link for the duration; `stop()` is idempotent.
    deinit {
        self.receiveTask?.cancel()
        self.incomingContinuation.finish()
        self.linkEventContinuation.finish()
        if self.isStopped == false {
            let link = self.link
            Task { await link.stop() }
        }
    }

    public func start() async throws {
        guard self.isStopped == false else {
            throw MoshSSPDatagramRuntimeError.stopped
        }
        guard self.isStarted == false else {
            return
        }

        try await self.link.start()
        self.isStarted = true
        self.startReceiveTask()
    }

    /// Swap in a fresh datagram link WITHOUT resetting the crypto session.
    ///
    /// This is the core of transport-death resilience (client port hop / NAT
    /// rebind / Wi-Fi↔cellular). The old link is torn down and a new one installed
    /// in place, but the `MoshDatagramSequencer` (OCB key AND monotonic send
    /// sequence) and the SSP loop/state are untouched — they are stored properties
    /// of this actor and are never read out, copied, or forked across the swap.
    /// Because the sequencer is `~Copyable` and owned here throughout, the first
    /// datagram sealed on the NEW link necessarily carries the NEXT send sequence,
    /// never 0. Resetting it would reuse nonces under the same key and destroy OCB
    /// confidentiality and authenticity. This mirrors official Mosh, whose
    /// `Connection::hop_port` opens a new socket while the same `Session`/OCB key
    /// and `direction_seq` continue unchanged (`network/network.cc` ~116-125).
    ///
    /// The receive generation is bumped BEFORE the old link is stopped so the old
    /// receive task's terminal handler (which fires when its stream ends) is a
    /// no-op and cannot finish/fail the runtime. The `incomingInstructions` and
    /// `linkEvents` streams stay open across the swap.
    public func replaceLink(_ newLink: any MoshDatagramLink) async throws {
        try self.requireStarted()

        self.receiveGeneration &+= 1
        self.receiveTask?.cancel()
        self.receiveTask = nil
        await self.link.stop()

        self.link = newLink
        self.recordedSendErrorDescription = nil
        try await newLink.start()
        self.startReceiveTask()
    }

    public func stop() async {
        guard self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.receiveGeneration &+= 1
        self.receiveTask?.cancel()
        self.receiveTask = nil
        await self.link.stop()
        self.incomingContinuation.finish()
        self.linkEventContinuation.finish()
    }

    public func setCurrentState(_ state: SendState) async {
        let nowMilliseconds = await self.monotonicNowMilliseconds()
        self.loop.setCurrentState(state, nowMilliseconds: nowMilliseconds)
    }

    public func modifyCurrentState(_ body: @Sendable (inout SendState) -> Void) async {
        let nowMilliseconds = await self.monotonicNowMilliseconds()
        self.loop.modifyCurrentState(nowMilliseconds: nowMilliseconds, body)
    }

    public func currentSendState() -> SendState {
        self.loop.currentSendState
    }

    public func startShutdown() async {
        let nowMilliseconds = await self.monotonicNowMilliseconds()
        self.loop.startShutdown(nowMilliseconds: nowMilliseconds)
    }

    public func shutdownTimedOut() async -> Bool {
        let nowMilliseconds = await self.monotonicNowMilliseconds()
        return self.loop.shutdownTimedOut(nowMilliseconds: nowMilliseconds)
    }

    public func waitTime() async throws -> UInt64? {
        try self.requireStarted()
        let nowMilliseconds = await self.monotonicNowMilliseconds()
        return try self.loop.waitTime(nowMilliseconds: nowMilliseconds)
    }

    public func sendDueDatagrams() async throws -> MoshSSPDatagramOutgoingBatch? {
        try self.requireStarted()
        let nowMilliseconds = await self.monotonicNowMilliseconds()
        guard let batch = try self.loop.tick(nowMilliseconds: nowMilliseconds) else {
            return nil
        }

        // Seal is FATAL on throw. `MoshDatagramSequencer.seal` only throws when the
        // send sequence space or the per-key OCB block budget is exhausted
        // (`sendSequenceExhausted` / `blockEncryptionLimitReached`); both are
        // fail-closed, session-ending crypto conditions that must NOT be swallowed.
        // Sealing here (before any send) also advances the nonce/block counters
        // exactly once per transmission, so a retransmit rides a fresh nonce — the
        // same ordering official Mosh uses (`session.encrypt` precedes `sendto`).
        let packets = try batch.packets.map { packet in
            let datagram = try self.sequencer.seal(plaintext: packet.plaintext.serializedBytes())
            return MoshSSPDatagramOutgoingPacket(packet: packet, datagram: datagram)
        }

        // Send is TRANSIENT on throw. A failed `link.send` (ENETDOWN/EHOSTUNREACH
        // on a network transition, or a link that is momentarily down/rebuilding)
        // must not fail the session: official Mosh's `Connection::send` records the
        // errno into `send_error` and RETURNS (`network/network.cc` ~372-386). The
        // datagram is already accounted as sent by the SSP sender, so its
        // retransmit timer re-sends the still-unacknowledged state once
        // connectivity returns — recovery is automatic. We only classify precisely:
        // cooperative cancellation still propagates; every other error at this
        // transport boundary is recorded and swallowed.
        for packet in packets {
            do {
                try await self.link.send(packet.datagram)
                self.recordedSendErrorDescription = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.recordedSendErrorDescription = String(describing: error)
            }
        }

        return MoshSSPDatagramOutgoingBatch(sspBatch: batch, packets: packets)
    }

    @discardableResult
    public func receiveDatagram(
        _ datagram: [UInt8]
    ) async throws -> MoshSSPDatagramIncomingPacketResult<ReceiveState> {
        try self.requireStarted()

        let receivedDatagram = try self.sequencer.open(datagram: datagram)
        // `sequencer.open` has already authenticated the datagram (OCB) and
        // verified its direction; a `.replayed` status means only that the
        // sequence number is below the expected next sequence (an authentic but
        // out-of-order/duplicate datagram). Official Mosh still delivers such a
        // packet's payload to the transport so a reordered fragment can complete
        // its instruction ("don't use (but do return) out-of-order packets",
        // network/network.cc), and the sequencer has already declined to advance
        // its replay window, so delivering the plaintext opens no replay hole.
        // We only suppress the connection-level timestamp/RTT/heard updates for
        // an out-of-order datagram by passing `isInSequenceOrder: false`.
        let isInSequenceOrder: Bool
        switch receivedDatagram.sequenceStatus {
        case .new:
            isInSequenceOrder = true
        case .replayed:
            isInSequenceOrder = false
        }

        let packet = try MoshPacketPlaintext(
            serializedBytes: receivedDatagram.openedDatagram.plaintext
        )
        let nowMilliseconds = await self.monotonicNowMilliseconds()
        let packetResult = try self.loop.receive(
            packet,
            nowMilliseconds: nowMilliseconds,
            isInSequenceOrder: isInSequenceOrder
        )

        switch packetResult {
        case .incompleteFragment:
            return .incompleteFragment(receivedDatagram: receivedDatagram, packet: packet)
        case .instruction(let instructionResult):
            let instruction = MoshSSPDatagramIncomingInstruction(
                receivedDatagram: receivedDatagram,
                packet: packet,
                instructionResult: instructionResult
            )
            self.incomingContinuation.yield(instruction)
            return .instruction(instruction)
        }
    }

    public func latestReceivedState() -> MoshNumberedState<ReceiveState> {
        self.loop.latestReceivedState
    }

    public func acknowledgementNumber() -> UInt64 {
        self.loop.acknowledgementNumber
    }

    public func knownAcknowledgedSendStateNumber() -> UInt64 {
        self.loop.knownAcknowledgedSendStateNumber
    }

    public func lastSentSendStateNumber() -> UInt64 {
        self.loop.lastSentSendStateNumber
    }

    public func sendIntervalMilliseconds() -> UInt64 {
        self.loop.sendIntervalMilliseconds
    }

    public func shutdownAcknowledged() -> Bool {
        self.loop.shutdownAcknowledged
    }

    /// The sequence number the NEXT sealed datagram will carry. Borrows the
    /// runtime-owned `~Copyable` sequencer in place (no copy/fork). Used to prove
    /// send-sequence continuity across a `replaceLink` swap: it must not reset.
    public func nextSequenceToSend() -> UInt64 {
        self.sequencer.nextSequenceToSend
    }

    /// Clock time (ms) at which the peer was last heard from, or `nil` before first
    /// contact. Informational liveness signal.
    public func lastHeardAtMilliseconds() -> UInt64? {
        self.loop.lastHeardAtMilliseconds
    }

    /// Smoothed round-trip time estimate (ms).
    public func smoothedRoundTripMilliseconds() -> Double {
        self.loop.smoothedRoundTripMilliseconds
    }

    /// Round-trip time variation estimate (ms).
    public func roundTripVariationMilliseconds() -> Double {
        self.loop.roundTripVariationMilliseconds
    }

    /// Description of the most recent recorded-but-swallowed `link.send` failure,
    /// or `nil` if the last send succeeded. Mirrors official `Connection::send_error`.
    public func recordedSendError() -> String? {
        self.recordedSendErrorDescription
    }

    /// Reads the clock and returns a value clamped to be monotonic non-decreasing
    /// with respect to what has already been applied to the SSP loop. Because the read
    /// and the subsequent loop call run without an intervening suspension, the applied
    /// timeline the loop sees is guaranteed monotonic even under actor reentrancy at the
    /// clock read. See `lastAppliedNowMilliseconds`.
    private func monotonicNowMilliseconds() async -> UInt64 {
        let reading = await self.clock.nowMilliseconds()
        let monotonic = max(reading, self.lastAppliedNowMilliseconds)
        self.lastAppliedNowMilliseconds = monotonic
        return monotonic
    }

    private func requireStarted() throws {
        guard self.isStopped == false else {
            throw MoshSSPDatagramRuntimeError.stopped
        }
        guard self.isStarted else {
            throw MoshSSPDatagramRuntimeError.notStarted
        }
    }

    private func startReceiveTask() {
        let stream = self.link.incomingDatagrams
        let generation = self.receiveGeneration
        self.receiveTask = Task { [weak self] in
            do {
                for try await datagram in stream {
                    try Task.checkCancellation()
                    guard let self else {
                        return
                    }
                    do {
                        _ = try await self.receiveDatagram(datagram)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard Self.isPacketLocalDatagramError(error) else {
                            // A non-transient error while PROCESSING a datagram
                            // (e.g. malformed wire/fragment) is fatal and owned by
                            // this runtime — finish with the error rather than
                            // treating it as transport death.
                            await self.finishFromReceiveTask(throwing: error, generation: generation)
                            return
                        }
                    }
                }

                // The incoming stream ended cleanly (nil): the link was stopped
                // without a fault. Finish the runtime as before.
                guard let self else {
                    return
                }
                await self.finishFromReceiveTask(throwing: nil, generation: generation)
            } catch is CancellationError {
                // The task was cancelled by `replaceLink`/`stop`, both of which own
                // their own teardown. Do nothing here.
                return
            } catch {
                // The incoming datagram STREAM itself faulted: the transport died
                // (NWConnection `.failed`, injected transport failure). Keep the
                // crypto session and SSP state; surface for a link rebuild.
                guard let self else {
                    return
                }
                await self.handleLinkFailure(error, generation: generation)
            }
        }
    }

    private nonisolated static func isPacketLocalDatagramError(_ error: Error) -> Bool {
        switch error {
        case is MoshDatagramCipherError:
            return true
        case let error as MoshAES128OCBError:
            switch error {
            case .authenticationFailed, .ciphertextTooShort:
                return true
            case .invalidNonceLength, .commonCrypto:
                return false
            }
        case let error as MoshDatagramSequencerError:
            switch error {
            case .directionMismatch:
                return true
            case .sendSequenceExhausted, .blockEncryptionLimitReached:
                return false
            }
        default:
            return false
        }
    }

    private func finishFromReceiveTask(throwing error: Error?, generation: UInt64) async {
        guard self.receiveGeneration == generation, self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.receiveGeneration &+= 1
        self.receiveTask = nil
        await self.link.stop()
        if let error {
            self.incomingContinuation.finish(throwing: error)
        } else {
            self.incomingContinuation.finish()
        }
        self.linkEventContinuation.finish()
    }

    /// The current link's incoming stream faulted. Unlike `finishFromReceiveTask`,
    /// this preserves the runtime: `incomingInstructions` stays open, the SSP loop
    /// and `~Copyable` sequencer are untouched, and only the dead link is stopped.
    /// A `.linkFailed` event is surfaced so the owner can install a fresh link with
    /// `replaceLink(_:)`. The receive generation is bumped so this defunct task can
    /// no longer act on the runtime.
    private func handleLinkFailure(_ error: Error, generation: UInt64) async {
        guard self.receiveGeneration == generation, self.isStopped == false else {
            return
        }

        self.receiveGeneration &+= 1
        self.receiveTask = nil
        let deadLink = self.link
        self.linkEventContinuation.yield(.linkFailed(String(describing: error)))
        await deadLink.stop()
    }

    private static func makeIncomingInstructionStream(
        bufferingPolicy: IncomingInstructionStream.Continuation.BufferingPolicy
    ) -> (stream: IncomingInstructionStream, continuation: IncomingInstructionStream.Continuation) {
        var capturedContinuation: IncomingInstructionStream.Continuation?
        let stream = IncomingInstructionStream(bufferingPolicy: bufferingPolicy) { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }

        return (stream, capturedContinuation)
    }

    private static func makeLinkEventStream() -> (
        stream: AsyncStream<MoshSSPDatagramRuntimeLinkEvent>,
        continuation: AsyncStream<MoshSSPDatagramRuntimeLinkEvent>.Continuation
    ) {
        var capturedContinuation: AsyncStream<MoshSSPDatagramRuntimeLinkEvent>.Continuation?
        let stream = AsyncStream<MoshSSPDatagramRuntimeLinkEvent>(
            bufferingPolicy: .bufferingNewest(16)
        ) { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncStream did not provide a continuation")
        }

        return (stream, capturedContinuation)
    }
}
