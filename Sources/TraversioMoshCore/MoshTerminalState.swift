// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import TraversioMoshWire

public struct MoshTerminalClientState: MoshSynchronizedState {
    public private(set) var operations: [MoshClientOperation]

    public init(operations: [MoshClientOperation] = []) {
        self.operations = operations
    }

    public mutating func append(_ operation: MoshClientOperation) {
        self.operations.append(operation)
    }

    public mutating func append(contentsOf operations: [MoshClientOperation]) {
        self.operations.append(contentsOf: operations)
    }

    public func moshDiff(from base: MoshTerminalClientState) throws -> [UInt8] {
        let operations = self.operations.removingPrefix(base.operations) ?? self.operations
        return Self.serializedOperations(operations)
    }

    public mutating func applyMoshDiff(_ diff: [UInt8]) throws {
        guard diff.isEmpty == false else {
            return
        }

        let message = try MoshClientMessage(serializedBytes: diff)
        self.operations.append(contentsOf: try MoshClientOperation.operations(from: message))
    }

    public mutating func subtractMoshState(_ base: MoshTerminalClientState) throws {
        guard let operations = self.operations.removingPrefix(base.operations) else {
            return
        }
        self.operations = operations
    }

    private static func serializedOperations(_ operations: [MoshClientOperation]) -> [UInt8] {
        MoshClientOperation.message(from: operations).serializedBytes()
    }
}

public struct MoshTerminalHostState: MoshSynchronizedState {
    public private(set) var operations: [MoshHostOperation]
    public private(set) var dimensions: MoshTerminalDimensions?
    public private(set) var latestEchoAcknowledgementNumber: UInt64?

    public init(operations: [MoshHostOperation] = []) {
        self.operations = []
        self.dimensions = nil
        self.latestEchoAcknowledgementNumber = nil
        self.append(contentsOf: operations)
    }

    public var snapshot: MoshTerminalSnapshot {
        MoshTerminalSnapshot(
            dimensions: self.dimensions,
            operations: self.operations,
            latestEchoAcknowledgementNumber: self.latestEchoAcknowledgementNumber
        )
    }

    public mutating func append(_ operation: MoshHostOperation) {
        self.operations.append(operation)
        self.updateProjection(with: operation)
    }

    public mutating func append(contentsOf operations: [MoshHostOperation]) {
        for operation in operations {
            self.append(operation)
        }
    }

    public func moshDiff(from base: MoshTerminalHostState) throws -> [UInt8] {
        let operations = self.operations.removingPrefix(base.operations) ?? self.operations
        return Self.serializedOperations(operations)
    }

    public mutating func applyMoshDiff(_ diff: [UInt8]) throws {
        guard diff.isEmpty == false else {
            return
        }

        let message = try MoshHostMessage(serializedBytes: diff)
        self.append(contentsOf: try MoshHostOperation.operations(from: message))
    }

    public mutating func subtractMoshState(_ base: MoshTerminalHostState) throws {
        guard let operations = self.operations.removingPrefix(base.operations) else {
            return
        }
        self.operations = []
        self.dimensions = nil
        self.latestEchoAcknowledgementNumber = nil
        self.append(contentsOf: operations)
    }

    private mutating func updateProjection(with operation: MoshHostOperation) {
        switch operation {
        case .write:
            break
        case .resize(let dimensions):
            self.dimensions = dimensions
        case .echoAcknowledgement(let number):
            self.latestEchoAcknowledgementNumber = number
        }
    }

    private static func serializedOperations(_ operations: [MoshHostOperation]) -> [UInt8] {
        MoshHostOperation.message(from: operations).serializedBytes()
    }
}

public struct MoshTerminalStateEngine: Sendable {
    public private(set) var clientState: MoshTerminalClientState
    public private(set) var hostState: MoshTerminalHostState

    public init(
        clientState: MoshTerminalClientState = MoshTerminalClientState(),
        hostState: MoshTerminalHostState = MoshTerminalHostState()
    ) {
        self.clientState = clientState
        self.hostState = hostState
    }

    public var snapshot: MoshTerminalSnapshot {
        self.hostState.snapshot
    }

    @discardableResult
    public mutating func enqueueClientOperation(
        _ operation: MoshClientOperation
    ) -> MoshTerminalClientState {
        self.clientState.append(operation)
        return self.clientState
    }

    @discardableResult
    public mutating func enqueueClientOperations(
        _ operations: [MoshClientOperation]
    ) -> MoshTerminalClientState {
        self.clientState.append(contentsOf: operations)
        return self.clientState
    }

    @discardableResult
    public mutating func applyHostMessage(_ message: MoshHostMessage) throws -> [MoshHostOperation] {
        let operations = try MoshHostOperation.operations(from: message)
        self.hostState.append(contentsOf: operations)
        return operations
    }

    @discardableResult
    public mutating func applyHostDiff(_ diff: [UInt8]) throws -> [MoshHostOperation] {
        let beforeCount = self.hostState.operations.count
        try self.hostState.applyMoshDiff(diff)
        return Array(self.hostState.operations.dropFirst(beforeCount))
    }
}

private extension Array where Element: Equatable {
    func removingPrefix(_ prefix: [Element]) -> [Element]? {
        guard self.count >= prefix.count else {
            return nil
        }
        guard Array(self.prefix(prefix.count)) == prefix else {
            return nil
        }
        return Array(self.dropFirst(prefix.count))
    }
}
