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
    case replayedDatagram(MoshReceivedDatagram)
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

    private let link: any MoshDatagramLink
    private let clock: any MoshMillisecondsClock
    private let incomingContinuation: IncomingInstructionStream.Continuation
    private var loop: MoshSSPInMemoryLoop<SendState, ReceiveState>
    private var sequencer: MoshDatagramSequencer
    private var receiveTask: Task<Void, Never>?
    private var isStarted = false
    private var isStopped = false

    public init(
        loop: MoshSSPInMemoryLoop<SendState, ReceiveState>,
        sequencer: MoshDatagramSequencer,
        link: any MoshDatagramLink,
        clock: any MoshMillisecondsClock = MoshSystemMillisecondsClock(),
        bufferingPolicy: IncomingInstructionStream.Continuation.BufferingPolicy = .bufferingNewest(256)
    ) {
        let streamAndContinuation = Self.makeIncomingInstructionStream(bufferingPolicy: bufferingPolicy)
        self.incomingInstructions = streamAndContinuation.stream
        self.incomingContinuation = streamAndContinuation.continuation
        self.loop = loop
        self.sequencer = sequencer
        self.link = link
        self.clock = clock
    }

    deinit {
        self.receiveTask?.cancel()
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

    public func stop() async {
        guard self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.receiveTask?.cancel()
        self.receiveTask = nil
        await self.link.stop()
        self.incomingContinuation.finish()
    }

    public func setCurrentState(_ state: SendState) async {
        let nowMilliseconds = await self.clock.nowMilliseconds()
        self.loop.setCurrentState(state, nowMilliseconds: nowMilliseconds)
    }

    public func startShutdown() async {
        let nowMilliseconds = await self.clock.nowMilliseconds()
        self.loop.startShutdown(nowMilliseconds: nowMilliseconds)
    }

    public func shutdownTimedOut() async -> Bool {
        let nowMilliseconds = await self.clock.nowMilliseconds()
        return self.loop.shutdownTimedOut(nowMilliseconds: nowMilliseconds)
    }

    public func waitTime() async throws -> UInt64? {
        try self.requireStarted()
        let nowMilliseconds = await self.clock.nowMilliseconds()
        return try self.loop.waitTime(nowMilliseconds: nowMilliseconds)
    }

    public func sendDueDatagrams() async throws -> MoshSSPDatagramOutgoingBatch? {
        try self.requireStarted()
        let nowMilliseconds = await self.clock.nowMilliseconds()
        guard let batch = try self.loop.tick(nowMilliseconds: nowMilliseconds) else {
            return nil
        }

        let packets = try batch.packets.map { packet in
            let datagram = try self.sequencer.seal(plaintext: packet.plaintext.serializedBytes())
            return MoshSSPDatagramOutgoingPacket(packet: packet, datagram: datagram)
        }

        for packet in packets {
            try await self.link.send(packet.datagram)
        }

        return MoshSSPDatagramOutgoingBatch(sspBatch: batch, packets: packets)
    }

    @discardableResult
    public func receiveDatagram(
        _ datagram: [UInt8]
    ) async throws -> MoshSSPDatagramIncomingPacketResult<ReceiveState> {
        try self.requireStarted()

        let receivedDatagram = try self.sequencer.open(datagram: datagram)
        if case .replayed = receivedDatagram.sequenceStatus {
            return .replayedDatagram(receivedDatagram)
        }

        let packet = try MoshPacketPlaintext(
            serializedBytes: receivedDatagram.openedDatagram.plaintext
        )
        let nowMilliseconds = await self.clock.nowMilliseconds()
        let packetResult = try self.loop.receive(packet, nowMilliseconds: nowMilliseconds)

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
                            throw error
                        }
                    }
                }

                guard let self else {
                    return
                }
                await self.finishFromReceiveTask(throwing: nil)
            } catch is CancellationError {
                guard let self else {
                    return
                }
                await self.finishFromReceiveTask(throwing: nil)
            } catch {
                guard let self else {
                    return
                }
                await self.finishFromReceiveTask(throwing: error)
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
            case .sendSequenceExhausted:
                return false
            }
        default:
            return false
        }
    }

    private func finishFromReceiveTask(throwing error: Error?) async {
        guard self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.receiveTask = nil
        await self.link.stop()
        if let error {
            self.incomingContinuation.finish(throwing: error)
        } else {
            self.incomingContinuation.finish()
        }
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
}
