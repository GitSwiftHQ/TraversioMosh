// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import TraversioMoshWire

public protocol MoshSynchronizedState: Equatable, Sendable {
    func moshDiff(from base: Self) throws -> [UInt8]
    mutating func applyMoshDiff(_ diff: [UInt8]) throws
    mutating func subtractMoshState(_ base: Self) throws
}

public enum MoshSSPError: Error, Equatable, Sendable {
    case protocolVersionMismatch(UInt32)
    case throwawayAfterReference(throwawayNumber: UInt64, oldNumber: UInt64)
}

public enum MoshSSPReceiveResult: Equatable, Sendable {
    case accepted(newNumber: UInt64)
    case duplicate(newNumber: UInt64)
    case missingReference(oldNumber: UInt64)
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

    private var receivedStates: [MoshNumberedState<State>]
    private var acknowledgementNumberStorage: UInt64

    public init(initialState: State) {
        self.receivedStates = [MoshNumberedState(number: 0, state: initialState)]
        self.acknowledgementNumberStorage = 0
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

    public mutating func receive(_ instruction: MoshTransportInstruction) throws -> MoshSSPReceiveResult {
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

        var newState = referenceState.state
        if let diff = instruction.diff, !diff.isEmpty {
            try newState.applyMoshDiff(diff)
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
