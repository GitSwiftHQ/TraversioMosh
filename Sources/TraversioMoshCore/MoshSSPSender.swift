// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import TraversioMoshWire

public struct MoshSSPChaffSource: Sendable {
    public static let maximumByteCount = 16

    private let makeBytes: @Sendable () -> [UInt8]

    public init(makeBytes: @escaping @Sendable () -> [UInt8]) {
        self.makeBytes = makeBytes
    }

    public static let none = MoshSSPChaffSource {
        []
    }

    public static let random = MoshSSPChaffSource {
        let byteCount = Int.random(in: 0...Self.maximumByteCount)
        return (0..<byteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
    }

    func bytes() -> [UInt8] {
        Array(self.makeBytes().prefix(Self.maximumByteCount))
    }
}

public struct MoshSSPSender<State: MoshSynchronizedState>: Sendable {
    public static var protocolVersion: UInt32 { 2 }
    public static var acknowledgementDelayMilliseconds: UInt64 { 100 }
    public static var maximumSentStateCount: Int { 32 }

    private var currentState: State
    private var sentStates: [MoshSentState<State>]
    private var acknowledgementNumberStorage: UInt64
    private var assumedReceiverNumber: UInt64
    private let chaffSource: MoshSSPChaffSource

    public init(
        initialState: State,
        initialSentAtMilliseconds: UInt64 = 0,
        acknowledgementNumber: UInt64 = 0,
        chaffSource: MoshSSPChaffSource = .random
    ) {
        self.currentState = initialState
        self.sentStates = [MoshSentState(number: 0, sentAtMilliseconds: initialSentAtMilliseconds, state: initialState)]
        self.acknowledgementNumberStorage = acknowledgementNumber
        self.assumedReceiverNumber = 0
        self.chaffSource = chaffSource
    }

    public var acknowledgementNumber: UInt64 {
        self.acknowledgementNumberStorage
    }

    public var knownAcknowledgedStateNumber: UInt64 {
        self.sentStates[0].number
    }

    public var lastSentStateNumber: UInt64 {
        self.sentStates[self.sentStates.count - 1].number
    }

    public var shutdownAcknowledged: Bool {
        self.sentStates[0].number == UInt64.max
    }

    public var lastSentAtMilliseconds: UInt64 {
        self.sentStates[self.sentStates.count - 1].sentAtMilliseconds
    }

    public var assumedReceiverStateNumber: UInt64 {
        self.assumedReceiverNumber
    }

    public var sentStateNumbers: [UInt64] {
        self.sentStates.map(\.number)
    }

    public mutating func setCurrentState(_ state: State) {
        self.currentState = state
    }

    public mutating func setAcknowledgementNumber(_ acknowledgementNumber: UInt64) {
        self.acknowledgementNumberStorage = acknowledgementNumber
    }

    public mutating func processAcknowledgement(through acknowledgementNumber: UInt64) {
        guard self.sentStates.contains(where: { $0.number == acknowledgementNumber }) else {
            return
        }

        self.sentStates.removeAll { $0.number < acknowledgementNumber }
        if self.sentStates.contains(where: { $0.number == self.assumedReceiverNumber }) == false {
            self.assumedReceiverNumber = self.sentStates[0].number
        }
    }

    public mutating func makeAcknowledgementInstruction(
        nowMilliseconds: UInt64,
        timeoutMilliseconds: UInt64,
        isShutdown: Bool = false
    ) throws -> MoshTransportInstruction {
        try self.updateAssumedReceiverState(
            nowMilliseconds: nowMilliseconds,
            timeoutMilliseconds: timeoutMilliseconds
        )

        let lastNumber = self.sentStates[self.sentStates.count - 1].number
        guard isShutdown || lastNumber < UInt64.max else {
            throw MoshSSPError.stateNumberOverflow
        }

        let newNumber = isShutdown ? UInt64.max : lastNumber + 1
        let assumedReceiverState = self.sentStates[self.assumedReceiverIndex]
        self.addSentState(
            MoshSentState(
                number: newNumber,
                sentAtMilliseconds: nowMilliseconds,
                state: self.currentState
            )
        )

        return MoshTransportInstruction(
            protocolVersion: Self.protocolVersion,
            oldNumber: assumedReceiverState.number,
            newNumber: newNumber,
            acknowledgementNumber: self.acknowledgementNumberStorage,
            throwawayNumber: self.sentStates[0].number,
            diff: [],
            chaff: self.chaffSource.bytes()
        )
    }

    public mutating func makeDataInstruction(
        nowMilliseconds: UInt64,
        timeoutMilliseconds: UInt64,
        isShutdown: Bool = false
    ) throws -> MoshTransportInstruction? {
        try self.updateAssumedReceiverState(
            nowMilliseconds: nowMilliseconds,
            timeoutMilliseconds: timeoutMilliseconds
        )

        var assumedReceiverState = self.sentStates[self.assumedReceiverIndex]
        var diff = try self.currentState.moshDiff(from: assumedReceiverState.state)
        self.attemptProspectiveResendOptimization(diff: &diff, assumedReceiverState: &assumedReceiverState)

        guard diff.isEmpty == false else {
            return nil
        }

        let newNumber: UInt64
        if isShutdown {
            newNumber = UInt64.max
            if newNumber == self.sentStates[self.sentStates.count - 1].number {
                self.sentStates[self.sentStates.count - 1].sentAtMilliseconds = nowMilliseconds
            } else {
                self.addSentState(
                    MoshSentState(
                        number: newNumber,
                        sentAtMilliseconds: nowMilliseconds,
                        state: self.currentState
                    )
                )
            }
        } else if self.currentState == self.sentStates[self.sentStates.count - 1].state {
            newNumber = self.sentStates[self.sentStates.count - 1].number
            self.sentStates[self.sentStates.count - 1].sentAtMilliseconds = nowMilliseconds
        } else {
            let lastNumber = self.sentStates[self.sentStates.count - 1].number
            guard lastNumber < UInt64.max else {
                throw MoshSSPError.stateNumberOverflow
            }

            newNumber = lastNumber + 1
            self.addSentState(
                MoshSentState(
                    number: newNumber,
                    sentAtMilliseconds: nowMilliseconds,
                    state: self.currentState
                )
            )
        }

        self.assumedReceiverNumber = newNumber

        return MoshTransportInstruction(
            protocolVersion: Self.protocolVersion,
            oldNumber: assumedReceiverState.number,
            newNumber: newNumber,
            acknowledgementNumber: self.acknowledgementNumberStorage,
            throwawayNumber: self.sentStates[0].number,
            diff: diff,
            chaff: self.chaffSource.bytes()
        )
    }

    private var assumedReceiverIndex: Int {
        self.sentStates.firstIndex { $0.number == self.assumedReceiverNumber } ?? 0
    }

    var currentStateMatchesKnownAcknowledgedState: Bool {
        self.currentState == self.sentStates[0].state
    }

    var currentStateMatchesLastSentState: Bool {
        self.currentState == self.sentStates[self.sentStates.count - 1].state
    }

    var currentStateMatchesAssumedReceiverState: Bool {
        self.currentState == self.sentStates[self.assumedReceiverIndex].state
    }

    mutating func refreshAssumedReceiverState(
        nowMilliseconds: UInt64,
        timeoutMilliseconds: UInt64
    ) throws {
        try self.updateAssumedReceiverState(
            nowMilliseconds: nowMilliseconds,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    private mutating func updateAssumedReceiverState(
        nowMilliseconds: UInt64,
        timeoutMilliseconds: UInt64
    ) throws {
        let lastSentAtMilliseconds = self.sentStates[self.sentStates.count - 1].sentAtMilliseconds
        guard nowMilliseconds >= lastSentAtMilliseconds else {
            throw MoshSSPError.clockMovedBackward(
                nowMilliseconds: nowMilliseconds,
                sentAtMilliseconds: lastSentAtMilliseconds
            )
        }

        self.assumedReceiverNumber = self.sentStates[0].number
        let freshnessWindow = timeoutMilliseconds > UInt64.max - Self.acknowledgementDelayMilliseconds
            ? UInt64.max
            : timeoutMilliseconds + Self.acknowledgementDelayMilliseconds

        for state in self.sentStates.dropFirst() {
            if nowMilliseconds - state.sentAtMilliseconds < freshnessWindow {
                self.assumedReceiverNumber = state.number
            } else {
                return
            }
        }
    }

    private mutating func addSentState(_ state: MoshSentState<State>) {
        self.sentStates.append(state)
        if self.sentStates.count > Self.maximumSentStateCount {
            let removalIndex = self.sentStates.count - 16
            let removedState = self.sentStates.remove(at: removalIndex)
            if removedState.number == self.assumedReceiverNumber {
                self.assumedReceiverNumber = self.sentStates[0].number
            }
        }
    }

    private mutating func attemptProspectiveResendOptimization(
        diff proposedDiff: inout [UInt8],
        assumedReceiverState: inout MoshSentState<State>
    ) {
        guard assumedReceiverState.number != self.sentStates[0].number else {
            return
        }

        guard let resendDiff = try? self.currentState.moshDiff(from: self.sentStates[0].state) else {
            return
        }

        if resendDiff.count <= proposedDiff.count
            || (resendDiff.count < 1000 && resendDiff.count >= proposedDiff.count && resendDiff.count - proposedDiff.count < 100) {
            assumedReceiverState = self.sentStates[0]
            self.assumedReceiverNumber = assumedReceiverState.number
            proposedDiff = resendDiff
        }
    }
}

private struct MoshSentState<State: MoshSynchronizedState>: Equatable, Sendable {
    let number: UInt64
    var sentAtMilliseconds: UInt64
    let state: State
}
