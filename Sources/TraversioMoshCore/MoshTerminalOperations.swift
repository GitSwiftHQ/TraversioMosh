// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import TraversioMoshWire

public enum MoshTerminalOperationError: Error, Equatable, Sendable {
    case invalidColumnCount(Int32)
    case invalidRowCount(Int32)
}

public struct MoshTerminalDimensions: Equatable, Sendable {
    /// Upper bound on a single terminal dimension.
    ///
    /// A resize instruction is peer-controlled, and `MoshTerminalScreen`
    /// allocates a cell grid of `columns * rows`. Without a ceiling a malicious
    /// `resize` (e.g. `Int32.max` columns) forces an OOM-scale allocation. 1000
    /// comfortably exceeds any real display (well past 8K-wide multi-monitor
    /// layouts) while bounding the grid to at most 1_000_000 cells, so it is a
    /// safe interop cap. Values above the bound are rejected, not clamped, so a
    /// caller never silently renders at the wrong size.
    public static let maximumDimension: Int32 = 1000

    public let columns: Int32
    public let rows: Int32

    public init(columns: Int32, rows: Int32) throws {
        guard columns > 0, columns <= Self.maximumDimension else {
            throw MoshTerminalOperationError.invalidColumnCount(columns)
        }
        guard rows > 0, rows <= Self.maximumDimension else {
            throw MoshTerminalOperationError.invalidRowCount(rows)
        }

        self.columns = columns
        self.rows = rows
    }

    public init(wireSize: MoshTerminalSize) throws {
        try self.init(columns: wireSize.columns, rows: wireSize.rows)
    }

    var wireSize: MoshTerminalSize {
        MoshTerminalSize(columns: self.columns, rows: self.rows)
    }
}

public struct MoshTerminalOutput: Equatable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}

public enum MoshClientOperation: Equatable, Sendable {
    case keystrokes([UInt8])
    case resize(MoshTerminalDimensions)

    public static func operations(from message: MoshClientMessage) throws -> [MoshClientOperation] {
        try message.instructions.flatMap { instruction in
            try Self.operations(from: instruction)
        }
    }

    public static func message(from operations: [MoshClientOperation]) -> MoshClientMessage {
        MoshClientMessage(instructions: operations.map(\.wireInstruction))
    }

    private static func operations(from instruction: MoshClientInstruction) throws -> [MoshClientOperation] {
        var operations: [MoshClientOperation] = []
        if let keystrokes = instruction.keystrokes {
            operations.append(.keystrokes(keystrokes))
        }
        if let resize = instruction.resize {
            operations.append(.resize(try MoshTerminalDimensions(wireSize: resize)))
        }
        return operations
    }

    private var wireInstruction: MoshClientInstruction {
        switch self {
        case .keystrokes(let bytes):
            MoshClientInstruction(keystrokes: bytes)
        case .resize(let dimensions):
            MoshClientInstruction(resize: dimensions.wireSize)
        }
    }
}

public enum MoshHostOperation: Equatable, Sendable {
    case write(MoshTerminalOutput)
    case resize(MoshTerminalDimensions)
    case echoAcknowledgement(UInt64)

    public static func operations(from message: MoshHostMessage) throws -> [MoshHostOperation] {
        try message.instructions.flatMap { instruction in
            try Self.operations(from: instruction)
        }
    }

    public static func message(from operations: [MoshHostOperation]) -> MoshHostMessage {
        MoshHostMessage(instructions: operations.map(\.wireInstruction))
    }

    private static func operations(from instruction: MoshHostInstruction) throws -> [MoshHostOperation] {
        var operations: [MoshHostOperation] = []
        if let hostBytes = instruction.hostBytes {
            operations.append(.write(MoshTerminalOutput(bytes: hostBytes)))
        }
        if let resize = instruction.resize {
            operations.append(.resize(try MoshTerminalDimensions(wireSize: resize)))
        }
        if let echoAcknowledgementNumber = instruction.echoAcknowledgementNumber {
            operations.append(.echoAcknowledgement(echoAcknowledgementNumber))
        }
        return operations
    }

    private var wireInstruction: MoshHostInstruction {
        switch self {
        case .write(let output):
            MoshHostInstruction(hostBytes: output.bytes)
        case .resize(let dimensions):
            MoshHostInstruction(resize: dimensions.wireSize)
        case .echoAcknowledgement(let number):
            MoshHostInstruction(echoAcknowledgementNumber: number)
        }
    }
}

public enum MoshTerminalRenderOperation: Equatable, Sendable {
    case write(MoshTerminalOutput)
    case resize(MoshTerminalDimensions)

    public init?(_ hostOperation: MoshHostOperation) {
        switch hostOperation {
        case .write(let output):
            self = .write(output)
        case .resize(let dimensions):
            self = .resize(dimensions)
        case .echoAcknowledgement:
            return nil
        }
    }

    public static func operations(
        from hostOperations: [MoshHostOperation]
    ) -> [MoshTerminalRenderOperation] {
        hostOperations.compactMap(MoshTerminalRenderOperation.init)
    }
}

public struct MoshTerminalSnapshot: Equatable, Sendable {
    public let dimensions: MoshTerminalDimensions?
    public let operations: [MoshHostOperation]
    public let latestEchoAcknowledgementNumber: UInt64?

    public init(
        dimensions: MoshTerminalDimensions?,
        operations: [MoshHostOperation],
        latestEchoAcknowledgementNumber: UInt64?
    ) {
        self.dimensions = dimensions
        self.operations = operations
        self.latestEchoAcknowledgementNumber = latestEchoAcknowledgementNumber
    }

    public var renderOperations: [MoshTerminalRenderOperation] {
        MoshTerminalRenderOperation.operations(from: self.operations)
    }

    public var renderSnapshot: MoshTerminalRenderSnapshot {
        MoshTerminalRenderSnapshot(
            dimensions: self.dimensions,
            operations: self.renderOperations
        )
    }
}

public struct MoshTerminalRenderSnapshot: Equatable, Sendable {
    public let dimensions: MoshTerminalDimensions?
    public let operations: [MoshTerminalRenderOperation]

    public init(
        dimensions: MoshTerminalDimensions?,
        operations: [MoshTerminalRenderOperation]
    ) {
        self.dimensions = dimensions
        self.operations = operations
    }
}
