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

    // Mirrors `Network::UserStream::subtract`: drop the shared prefix that the
    // peer is already known to hold. `rationalize_states` calls this on every
    // send opportunity so acknowledged keystrokes stop being retained.
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

/// Host (server -> client) synchronized state.
///
/// Official Mosh models this as `Terminal::Complete`: a materialized
/// framebuffer, never an append-only operation log. This type mirrors that: it
/// carries a live `MoshTerminalScreen` (the framebuffer) that received diffs are
/// applied onto, so adopting a received state is a wholesale framebuffer swap
/// and nothing is ever replayed. See `statesync/completeterminal.{h,cc}`.
///
/// `pendingOperations` exists only to support the server-side `moshDiff(from:)`
/// used by the in-memory server fixture (real Mosh computes a visual framebuffer
/// diff via `Display::new_frame`, which this package does not implement). The
/// receive path (`applyMoshDiff`) never touches it, so received states hold no
/// unbounded history by construction.
public struct MoshTerminalHostState: MoshSynchronizedState {
    public static let defaultDimensions: MoshTerminalDimensions = {
        // 80x24 is always valid, so the force-unwrap cannot trap.
        (try? MoshTerminalDimensions(columns: 80, rows: 24))!
    }()

    private var screen: MoshTerminalScreen
    public private(set) var latestEchoAcknowledgementNumber: UInt64?

    /// Operations accumulated for server-side diff computation (send path only).
    private var pendingOperations: [MoshHostOperation]

    /// Operations carried by the most recent `applyMoshDiff` (receive path). The
    /// session emits exactly these to its host/render streams, so a re-based diff
    /// never floods the streams with historical operations.
    public private(set) var lastAppliedOperations: [MoshHostOperation]

    /// Terminal-generated replies (DA/DSR) produced while applying the most
    /// recent diff. Captured for observability only — the session never
    /// transmits them: in official Mosh the server-side emulator answers such
    /// queries and the client asserts it produced none
    /// (`Complete::apply_string`, `statesync/completeterminal.cc`).
    public private(set) var lastAppliedTerminalToHostBytes: [UInt8]

    public init() {
        self.init(dimensions: Self.defaultDimensions)
    }

    public init(dimensions: MoshTerminalDimensions) {
        self.screen = MoshTerminalScreen(dimensions: dimensions)
        self.latestEchoAcknowledgementNumber = nil
        self.pendingOperations = []
        self.lastAppliedOperations = []
        self.lastAppliedTerminalToHostBytes = []
    }

    public init(operations: [MoshHostOperation]) {
        self.init()
        self.append(contentsOf: operations)
    }

    public init(dimensions: MoshTerminalDimensions, operations: [MoshHostOperation]) {
        self.init(dimensions: dimensions)
        self.append(contentsOf: operations)
    }

    public var dimensions: MoshTerminalDimensions {
        self.screen.dimensions
    }

    public var screenSnapshot: MoshTerminalScreenSnapshot {
        self.screen.snapshot
    }

    /// The materialized framebuffer. The session adopts this directly rather than
    /// replaying operations onto its own screen.
    var terminalScreen: MoshTerminalScreen {
        self.screen
    }

    public var snapshot: MoshTerminalSnapshot {
        MoshTerminalSnapshot(
            dimensions: self.screen.dimensions,
            operations: self.lastAppliedOperations,
            latestEchoAcknowledgementNumber: self.latestEchoAcknowledgementNumber
        )
    }

    /// Server-construct entry point: applies the operation to the framebuffer and
    /// records it for `moshDiff(from:)`. Used by the in-memory server fixture.
    public mutating func append(_ operation: MoshHostOperation) {
        _ = try? self.applyToScreen(operation)
        self.pendingOperations.append(operation)
    }

    public mutating func append(contentsOf operations: [MoshHostOperation]) {
        for operation in operations {
            self.append(operation)
        }
    }

    public func moshDiff(from base: MoshTerminalHostState) throws -> [UInt8] {
        let operations = self.pendingOperations.removingPrefix(base.pendingOperations) ?? self.pendingOperations
        return MoshHostOperation.message(from: operations).serializedBytes()
    }

    /// Receive path: applies the diff to the framebuffer, capturing the applied
    /// operations and any terminal-generated replies. This never accumulates
    /// history, so a state reachable by many diffs is still just one framebuffer.
    public mutating func applyMoshDiff(_ diff: [UInt8]) throws {
        self.lastAppliedOperations = []
        self.lastAppliedTerminalToHostBytes = []
        guard diff.isEmpty == false else {
            return
        }

        let message = try MoshHostMessage(serializedBytes: diff)
        let operations = try MoshHostOperation.operations(from: message)
        var terminalToHostBytes: [UInt8] = []
        for operation in operations {
            terminalToHostBytes.append(contentsOf: try self.applyToScreen(operation))
        }
        self.lastAppliedOperations = operations
        self.lastAppliedTerminalToHostBytes = terminalToHostBytes
    }

    /// No-op, matching `Terminal::Complete::subtract`. A framebuffer carries no
    /// shared-prefix history to cut, so `rationalize_states` leaves it untouched.
    public mutating func subtractMoshState(_ base: MoshTerminalHostState) throws {}

    @discardableResult
    private mutating func applyToScreen(_ operation: MoshHostOperation) throws -> [UInt8] {
        switch operation {
        case .write(let output):
            return try self.screen.apply(.write(output))
        case .resize(let dimensions):
            return try self.screen.apply(.resize(dimensions))
        case .echoAcknowledgement(let number):
            self.latestEchoAcknowledgementNumber = number
            return []
        }
    }

    // Equality mirrors `Terminal::Complete::operator==`: framebuffer plus
    // echo-ack. The transient `lastApplied*` and server-only `pendingOperations`
    // are excluded because they are not part of the synchronized state's identity.
    public static func == (lhs: MoshTerminalHostState, rhs: MoshTerminalHostState) -> Bool {
        lhs.screen.snapshot == rhs.screen.snapshot
            && lhs.latestEchoAcknowledgementNumber == rhs.latestEchoAcknowledgementNumber
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
        try self.hostState.applyMoshDiff(message.serializedBytes())
        return self.hostState.lastAppliedOperations
    }

    @discardableResult
    public mutating func applyHostDiff(_ diff: [UInt8]) throws -> [MoshHostOperation] {
        try self.hostState.applyMoshDiff(diff)
        return self.hostState.lastAppliedOperations
    }

    /// Adoption-based accept: the engine's host state *becomes* the received
    /// framebuffer (no replay). The returned operations are exactly the diff that
    /// the accepted state carried, so the caller emits only newly applied work.
    @discardableResult
    public mutating func acceptHostState(_ hostState: MoshTerminalHostState) -> [MoshHostOperation] {
        self.hostState = hostState
        return hostState.lastAppliedOperations
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
