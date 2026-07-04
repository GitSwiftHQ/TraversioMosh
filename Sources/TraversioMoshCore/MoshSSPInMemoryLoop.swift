// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import TraversioMoshWire

public struct MoshSSPOutgoingPacket: Equatable, Sendable {
    public let plaintext: MoshPacketPlaintext
    public let fragment: MoshFragment

    public init(plaintext: MoshPacketPlaintext, fragment: MoshFragment) {
        self.plaintext = plaintext
        self.fragment = fragment
    }
}

public struct MoshSSPOutgoingBatch: Equatable, Sendable {
    public let event: MoshSSPSendEvent
    public let instruction: MoshTransportInstruction
    public let packets: [MoshSSPOutgoingPacket]

    public init(
        event: MoshSSPSendEvent,
        instruction: MoshTransportInstruction,
        packets: [MoshSSPOutgoingPacket]
    ) {
        self.event = event
        self.instruction = instruction
        self.packets = packets
    }
}

public enum MoshSSPIncomingPacketResult<ReceiveState: MoshSynchronizedState>: Equatable, Sendable {
    case incompleteFragment
    case instruction(MoshSSPIncomingInstructionResult<ReceiveState>)
}

public struct MoshSSPIncomingInstructionResult<ReceiveState: MoshSynchronizedState>: Equatable, Sendable {
    public let instruction: MoshTransportInstruction
    public let receiveResult: MoshSSPReceiveResult
    public let acknowledgementNumber: UInt64
    public let latestState: MoshNumberedState<ReceiveState>

    public init(
        instruction: MoshTransportInstruction,
        receiveResult: MoshSSPReceiveResult,
        acknowledgementNumber: UInt64,
        latestState: MoshNumberedState<ReceiveState>
    ) {
        self.instruction = instruction
        self.receiveResult = receiveResult
        self.acknowledgementNumber = acknowledgementNumber
        self.latestState = latestState
    }
}

public struct MoshSSPInMemoryLoop<
    SendState: MoshSynchronizedState,
    ReceiveState: MoshSynchronizedState
>: Sendable {
    private struct PendingTimestampReply: Equatable, Sendable {
        var timestamp: UInt16
        var receivedAtMilliseconds: UInt64
    }

    private static var packetTimestampNoReply: UInt16 { UInt16.max }
    private static var timestampReplyFreshnessWindowMilliseconds: UInt64 { 1_000 }

    public private(set) var scheduler: MoshSSPSendScheduler<SendState>
    public private(set) var receiver: MoshSSPReceiver<ReceiveState>

    private var fragmenter: MoshFragmenter
    private var assembly: MoshFragmentAssembly
    private let maximumSerializedFragmentByteCount: Int
    private var pendingTimestampReply: PendingTimestampReply?

    public init(
        initialSendState: SendState,
        initialReceiveState: ReceiveState,
        initialNowMilliseconds: UInt64 = 0,
        timing: MoshSSPSendTimingConfiguration = MoshSSPSendTimingConfiguration(),
        maximumSerializedFragmentByteCount: Int = 1_280,
        chaffSource: MoshSSPChaffSource = .random
    ) {
        self.scheduler = MoshSSPSendScheduler(
            initialState: initialSendState,
            initialNowMilliseconds: initialNowMilliseconds,
            timing: timing,
            chaffSource: chaffSource
        )
        self.receiver = MoshSSPReceiver(initialState: initialReceiveState)
        self.fragmenter = MoshFragmenter()
        self.assembly = MoshFragmentAssembly()
        self.maximumSerializedFragmentByteCount = maximumSerializedFragmentByteCount
        self.pendingTimestampReply = nil
    }

    public var latestReceivedState: MoshNumberedState<ReceiveState> {
        self.receiver.latestState
    }

    public var acknowledgementNumber: UInt64 {
        self.receiver.acknowledgementNumber
    }

    public var knownAcknowledgedSendStateNumber: UInt64 {
        self.scheduler.sender.knownAcknowledgedStateNumber
    }

    public var lastSentSendStateNumber: UInt64 {
        self.scheduler.sender.lastSentStateNumber
    }

    public var sendIntervalMilliseconds: UInt64 {
        self.scheduler.sendIntervalMilliseconds
    }

    public var shutdownAcknowledged: Bool {
        self.scheduler.shutdownAcknowledged
    }

    public var currentSendState: SendState {
        self.scheduler.sender.currentSendState
    }

    public mutating func setCurrentState(_ state: SendState, nowMilliseconds: UInt64) {
        self.scheduler.setCurrentState(state, nowMilliseconds: nowMilliseconds)
    }

    public mutating func modifyCurrentState(
        nowMilliseconds: UInt64,
        _ body: (inout SendState) -> Void
    ) {
        self.scheduler.modifyCurrentState(nowMilliseconds: nowMilliseconds, body)
    }

    public mutating func startShutdown(nowMilliseconds: UInt64) {
        self.scheduler.startShutdown(nowMilliseconds: nowMilliseconds)
    }

    public func shutdownTimedOut(nowMilliseconds: UInt64) -> Bool {
        self.scheduler.shutdownTimedOut(nowMilliseconds: nowMilliseconds)
    }

    public mutating func waitTime(nowMilliseconds: UInt64) throws -> UInt64? {
        try self.scheduler.waitTime(nowMilliseconds: nowMilliseconds)
    }

    public mutating func tick(nowMilliseconds: UInt64) throws -> MoshSSPOutgoingBatch? {
        guard let event = try self.scheduler.tick(nowMilliseconds: nowMilliseconds) else {
            return nil
        }

        let instruction: MoshTransportInstruction
        switch event {
        case .data(let dataInstruction), .acknowledgement(let dataInstruction):
            instruction = dataInstruction
        }

        let fragments = try self.fragmenter.makeFragments(
            for: instruction,
            maximumSerializedFragmentByteCount: self.maximumSerializedFragmentByteCount
        )
        let timestamp = Self.packetTimestamp(for: nowMilliseconds)
        let packets = fragments.map { fragment in
            let plaintext = MoshPacketPlaintext(
                timestamp: timestamp,
                timestampReply: self.consumeTimestampReply(nowMilliseconds: nowMilliseconds),
                payload: fragment.serializedBytes()
            )
            return MoshSSPOutgoingPacket(plaintext: plaintext, fragment: fragment)
        }

        return MoshSSPOutgoingBatch(
            event: event,
            instruction: instruction,
            packets: packets
        )
    }

    public mutating func receive(
        _ packet: MoshPacketPlaintext,
        nowMilliseconds: UInt64,
        isInSequenceOrder: Bool = true
    ) throws -> MoshSSPIncomingPacketResult<ReceiveState> {
        // Connection-level timestamp, RTT, and last-heard state may only advance
        // for an in-sequence datagram. This mirrors official Mosh
        // `Connection::recv_one` (network/network.cc ~482-524): when a datagram's
        // seq is below `expected_receiver_seq` it "don't use (but do return)
        // out-of-order packets for timestamp or targeting" and returns the payload
        // before touching `saved_timestamp`, the RTT estimator, or `last_heard`.
        // Skipping these is security-sensitive: a replayed datagram must not be
        // able to move the timestamp/RTT estimators. The transport-level work
        // below (ack processing, state application) is idempotent by state number
        // and still runs, exactly as official's `Transport::recv` does for the
        // returned out-of-order payload.
        if isInSequenceOrder {
            if packet.timestamp != Self.packetTimestampNoReply {
                self.pendingTimestampReply = PendingTimestampReply(
                    timestamp: packet.timestamp,
                    receivedAtMilliseconds: nowMilliseconds
                )
            }
            self.scheduler.processPacketTimestampReply(
                packet.timestampReply,
                nowMilliseconds: nowMilliseconds
            )
            self.scheduler.noteRemoteHeard(nowMilliseconds: nowMilliseconds)
        }

        let fragment = try MoshFragment(serializedBytes: packet.payload)
        guard let instruction = try self.assembly.add(fragment) else {
            return .incompleteFragment
        }

        if let acknowledgementNumber = instruction.acknowledgementNumber {
            self.scheduler.processAcknowledgement(
                through: acknowledgementNumber,
                nowMilliseconds: nowMilliseconds
            )
        }

        let receiveResult = try self.receiver.receive(instruction, nowMilliseconds: nowMilliseconds)
        if self.receiver.acknowledgementNumber == instruction.newNumber {
            // Official Mosh (`network/networktransport-impl.h` recv ~168-173)
            // always `set_ack_num` when a state is appended at the back but only
            // `set_data_ack` `if ( !inst.diff().empty() )`. An empty-diff
            // heartbeat therefore advances the ack number without arming the
            // delayed data-acknowledgement; otherwise two instances trade empty
            // acks forever, because each empty ack mints a fresh state number
            // that the peer would then delay-ack in turn.
            let hadNonEmptyDiff = (instruction.diff?.isEmpty == false)
            self.scheduler.noteReceivedState(
                number: self.receiver.acknowledgementNumber,
                hadNonEmptyDiff: hadNonEmptyDiff,
                nowMilliseconds: nowMilliseconds
            )
        }

        let result = MoshSSPIncomingInstructionResult(
            instruction: instruction,
            receiveResult: receiveResult,
            acknowledgementNumber: self.receiver.acknowledgementNumber,
            latestState: self.receiver.latestState
        )
        return .instruction(result)
    }

    public mutating func receive(
        serializedPacket: [UInt8],
        nowMilliseconds: UInt64
    ) throws -> MoshSSPIncomingPacketResult<ReceiveState> {
        let packet = try MoshPacketPlaintext(serializedBytes: serializedPacket)
        return try self.receive(packet, nowMilliseconds: nowMilliseconds)
    }

    private static func packetTimestamp(for nowMilliseconds: UInt64) -> UInt16 {
        // Never emit 0xFFFF as a live timestamp: that value is the "no timestamp"
        // marker on the wire. Mirrors official Mosh `Network::timestamp16`
        // (network/network.cc ~570-577), which does `if ( ts == uint16_t( -1 ) )
        // ts++;`, wrapping 0xFFFF to 0x0000.
        let truncated = UInt16(truncatingIfNeeded: nowMilliseconds)
        return truncated == Self.packetTimestampNoReply ? truncated &+ 1 : truncated
    }

    private mutating func consumeTimestampReply(nowMilliseconds: UInt64) -> UInt16 {
        guard let pendingTimestampReply else {
            return Self.packetTimestampNoReply
        }
        guard nowMilliseconds >= pendingTimestampReply.receivedAtMilliseconds else {
            return Self.packetTimestampNoReply
        }

        let elapsedMilliseconds = nowMilliseconds - pendingTimestampReply.receivedAtMilliseconds
        guard elapsedMilliseconds < Self.timestampReplyFreshnessWindowMilliseconds else {
            return Self.packetTimestampNoReply
        }

        self.pendingTimestampReply = nil
        return UInt16(truncatingIfNeeded: UInt64(pendingTimestampReply.timestamp) + elapsedMilliseconds)
    }
}
