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
    public private(set) var scheduler: MoshSSPSendScheduler<SendState>
    public private(set) var receiver: MoshSSPReceiver<ReceiveState>

    private var fragmenter: MoshFragmenter
    private var assembly: MoshFragmentAssembly
    private let maximumSerializedFragmentByteCount: Int
    private var lastReceivedTimestamp: UInt16

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
        self.lastReceivedTimestamp = 0
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

    public var shutdownAcknowledged: Bool {
        self.scheduler.shutdownAcknowledged
    }

    public mutating func setCurrentState(_ state: SendState, nowMilliseconds: UInt64) {
        self.scheduler.setCurrentState(state, nowMilliseconds: nowMilliseconds)
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
                timestampReply: self.lastReceivedTimestamp,
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
        nowMilliseconds: UInt64
    ) throws -> MoshSSPIncomingPacketResult<ReceiveState> {
        self.lastReceivedTimestamp = packet.timestamp
        self.scheduler.noteRemoteHeard(nowMilliseconds: nowMilliseconds)

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

        let receiveResult = try self.receiver.receive(instruction)
        if self.receiver.acknowledgementNumber == instruction.newNumber {
            self.scheduler.noteReceivedState(
                number: self.receiver.acknowledgementNumber,
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
        UInt16(truncatingIfNeeded: nowMilliseconds)
    }
}
