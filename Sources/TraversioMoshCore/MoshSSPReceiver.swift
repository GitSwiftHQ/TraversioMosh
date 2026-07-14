// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import TraversioMoshWire

public protocol MoshSynchronizedState: Equatable, Sendable {
    func moshDiff(from base: Self) throws -> [UInt8]
    mutating func applyMoshDiff(_ diff: [UInt8]) throws
    mutating func subtractMoshState(_ base: Self) throws
    /// Approximate in-memory byte cost of retaining one instance. Used to
    /// bound the aggregate memory a bounded received-state queue may hold
    /// (see `MoshSSPReceiver.maximumReceivedStateCumulativeByteCount`) in
    /// addition to its existing count ceiling, so a peer cannot reach a
    /// vastly larger aggregate memory cost than that count ceiling was sized
    /// for by keeping every queued state maximally large. Types with no
    /// large peer-controlled payload can rely on the default
    /// `MemoryLayout<Self>.size` implementation below.
    var estimatedByteCount: Int { get }
}

extension MoshSynchronizedState {
    public var estimatedByteCount: Int {
        MemoryLayout<Self>.size
    }
}

public enum MoshSSPError: Error, Equatable, Sendable {
    case protocolVersionMismatch(UInt32)
    case throwawayAfterReference(throwawayNumber: UInt64, oldNumber: UInt64)
    case stateNumberOverflow
    case clockMovedBackward(nowMilliseconds: UInt64, sentAtMilliseconds: UInt64)
}

public enum MoshSSPReceiveResult: Equatable, Sendable {
    case accepted(newNumber: UInt64)
    case duplicate(newNumber: UInt64)
    case missingReference(oldNumber: UInt64)
    /// The received-state queue is full and the new state was dropped without
    /// being acknowledged. Mirrors `Network::Transport::recv`'s 1024-state guard.
    case queueFull(newNumber: UInt64)
}

public struct MoshNumberedState<State: MoshSynchronizedState>: Equatable, Sendable {
    public let number: UInt64
    public let state: State

    public init(number: UInt64, state: State) {
        self.number = number
        self.state = state
    }
}

public struct MoshSSPReceiver<State: MoshSynchronizedState>: Sendable {
    public static var protocolVersion: UInt32 { 2 }

    /// Upper bound on the received-state queue before quenching, matching
    /// official Mosh's `received_states.size() > 1024` guard in
    /// `network/networktransport-impl.h`.
    public static var maximumReceivedStateCount: Int { 1024 }

    /// Once the queue is full, at most one further state is admitted per this
    /// window, matching official Mosh's `receiver_quench_timer = now + 15000`.
    public static var receiverQuenchIntervalMilliseconds: UInt64 { 15_000 }

    /// Upper bound on the received-state queue's aggregate estimated byte
    /// cost, independent of `maximumReceivedStateCount`. The count ceiling
    /// alone assumes official Mosh's own lightweight per-cell representation;
    /// this package's framebuffer-backed states can individually be far
    /// larger (see `MoshTerminalDimensions.maximumCellCount`), so a peer that
    /// keeps every queued state near its own per-state maximum could
    /// otherwise reach the count ceiling at an aggregate memory cost that
    /// ceiling was never sized for. 128 MiB is a generous multiple of one
    /// maximally-sized state — comfortable headroom for legitimate
    /// reordering bursts of several large states — while remaining a
    /// mobile-safe aggregate ceiling regardless of how the queue fills.
    public static var maximumReceivedStateCumulativeByteCount: Int { 128 * 1024 * 1024 }

    private var receivedStates: [MoshNumberedState<State>]
    private var acknowledgementNumberStorage: UInt64
    private var receiverQuenchTimerMilliseconds: UInt64

    public init(initialState: State) {
        self.receivedStates = [MoshNumberedState(number: 0, state: initialState)]
        self.acknowledgementNumberStorage = 0
        self.receiverQuenchTimerMilliseconds = 0
    }

    public var acknowledgementNumber: UInt64 {
        self.acknowledgementNumberStorage
    }

    public var latestState: MoshNumberedState<State> {
        self.receivedStates[self.receivedStates.count - 1]
    }

    public var stateNumbers: [UInt64] {
        self.receivedStates.map(\.number)
    }

    public mutating func receive(
        _ instruction: MoshTransportInstruction,
        nowMilliseconds: UInt64 = 0
    ) throws -> MoshSSPReceiveResult {
        let protocolVersion = instruction.protocolVersion ?? 0
        guard protocolVersion == Self.protocolVersion else {
            throw MoshSSPError.protocolVersionMismatch(protocolVersion)
        }

        let oldNumber = instruction.oldNumber ?? 0
        let newNumber = instruction.newNumber ?? 0
        let throwawayNumber = instruction.throwawayNumber ?? 0

        guard throwawayNumber <= oldNumber else {
            throw MoshSSPError.throwawayAfterReference(
                throwawayNumber: throwawayNumber,
                oldNumber: oldNumber
            )
        }

        if self.receivedStates.contains(where: { $0.number == newNumber }) {
            return .duplicate(newNumber: newNumber)
        }

        guard let referenceState = self.receivedStates.first(where: { $0.number == oldNumber }) else {
            return .missingReference(oldNumber: oldNumber)
        }

        self.processThrowaway(until: throwawayNumber)

        // Always apply (even an empty diff) so the built state's `lastApplied*`
        // metadata reflects exactly this diff and never a stale copy from the
        // reference state (an empty-diff heartbeat still advances the number).
        // Built before either admission check below so the byte budget can
        // measure the CANDIDATE's own cost, not only the states already queued.
        var newState = referenceState.state
        try newState.applyMoshDiff(instruction.diff ?? [])

        // The byte budget is a hard memory ceiling, not a pacing mechanism.
        // Unlike the count-based quench below — which faithfully mirrors
        // official Mosh's own admit-one-per-window behavior, safe there only
        // because its per-state cost is tiny — periodically admitting one more
        // state despite already being over budget would let this package's far
        // heavier framebuffer-backed states keep creeping the aggregate upward
        // indefinitely, defeating the ceiling entirely over enough quench
        // windows. So this check includes the candidate state's own cost and
        // rejects unconditionally whenever admitting it would cross the
        // budget: no timer, no periodic grace. It recomputes fresh on every
        // call against the queue as `processThrowaway` above just left it, so
        // admission resumes as soon as enough room is freed. A rejected state
        // is dropped before insertion, so it is never acknowledged.
        let projectedByteCount = self.receivedStates.reduce(newState.estimatedByteCount) { total, numberedState in
            total + numberedState.state.estimatedByteCount
        }
        guard projectedByteCount <= Self.maximumReceivedStateCumulativeByteCount else {
            return .queueFull(newNumber: newNumber)
        }

        // Do not accept the state if the queue is full by count. Official Mosh
        // prefers this over dropping states from the middle, because it never
        // wants to ACK a state and then discard it. Once full, one state is
        // admitted per quench window; otherwise the new state is dropped and
        // left unacked. Safe as a periodic-admission (not hard-reject) policy
        // specifically because official Mosh's own per-state cost is small; see
        // the byte budget above for why that same leniency would be unsafe if
        // applied to aggregate memory.
        if self.receivedStates.count > Self.maximumReceivedStateCount {
            if nowMilliseconds < self.receiverQuenchTimerMilliseconds {
                return .queueFull(newNumber: newNumber)
            }
            self.receiverQuenchTimerMilliseconds = nowMilliseconds &+ Self.receiverQuenchIntervalMilliseconds
        }

        let numberedState = MoshNumberedState(number: newNumber, state: newState)
        self.insertReceivedState(numberedState)
        if self.latestState.number == newNumber {
            self.acknowledgementNumberStorage = newNumber
        }

        return .accepted(newNumber: newNumber)
    }

    private mutating func processThrowaway(until throwawayNumber: UInt64) {
        self.receivedStates.removeAll { $0.number < throwawayNumber }
    }

    private mutating func insertReceivedState(_ state: MoshNumberedState<State>) {
        guard let insertionIndex = self.receivedStates.firstIndex(where: { $0.number > state.number }) else {
            self.receivedStates.append(state)
            return
        }

        self.receivedStates.insert(state, at: insertionIndex)
    }
}
