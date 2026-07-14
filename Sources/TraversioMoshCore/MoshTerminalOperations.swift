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
    /// `resize` (e.g. `Int32.max` columns) forces an OOM-scale allocation. 2048
    /// matches official mosh's effective per-dimension bound (its
    /// terminal-to-host transport buffer is sized 2048 * 2048;
    /// `Framebuffer::resize` itself has no per-dimension cap). Official mosh's
    /// `Cell` is only a few bytes; `MoshTerminalCell` is not, so 2048 x 2048
    /// independently-clamped dimensions still let a peer reach the combined
    /// `maximumCellCount` ceiling below. This bound alone does not prevent that.
    public static let maximumDimension: Int32 = 2048

    /// Upper bound on total cells (`columns * rows`), independent of either
    /// dimension. `MemoryLayout<MoshTerminalCell>.stride` is about 80 bytes on
    /// Apple platforms (a `String`, an optional hyperlink, a text-attributes
    /// struct, and bookkeeping fields), so 2048 x 2048 alone permits a
    /// ~320 MiB single allocation — and `MoshTerminalScreen.resize(_:)` briefly
    /// holds the old grid alive alongside the new one, roughly doubling that
    /// peak. 250,000 cells is about 20 MiB per grid at that stride: generous
    /// headroom over any real terminal (80x24 is 1,920 cells; even an extreme
    /// multi-pane layout is unlikely to exceed a few hundred thousand) while
    /// keeping worst-case resize memory mobile-safe regardless of how the
    /// two dimensions are split. Oversized values are clamped, not rejected,
    /// matching `maximumDimension`'s clamp-not-reject rationale above.
    public static let maximumCellCount = 250_000

    public let columns: Int32
    public let rows: Int32

    public init(columns: Int32, rows: Int32) throws {
        // Nonpositive dimensions stay rejected (official mosh asserts
        // `s_width > 0 && s_height > 0`); only the upper bounds clamp.
        guard columns > 0 else {
            throw MoshTerminalOperationError.invalidColumnCount(columns)
        }
        guard rows > 0 else {
            throw MoshTerminalOperationError.invalidRowCount(rows)
        }

        let clampedColumns = min(columns, Self.maximumDimension)
        let clampedRows = min(rows, Self.maximumDimension)

        guard Int(clampedColumns) * Int(clampedRows) > Self.maximumCellCount else {
            self.columns = clampedColumns
            self.rows = clampedRows
            return
        }

        // Both dimensions already fit individually but their product does not:
        // shrink whichever is larger so the total stays within budget, keeping
        // the smaller (usually the more meaningful) dimension untouched. The
        // divisor is always positive and no larger than `maximumDimension`, and
        // the branch only runs when the current product exceeds
        // `maximumCellCount`, so the recomputed dimension is always smaller
        // than its current (already-clamped) value and always at least 1.
        if clampedColumns >= clampedRows {
            self.rows = clampedRows
            self.columns = Int32(Self.maximumCellCount / Int(clampedRows))
        } else {
            self.columns = clampedColumns
            self.rows = Int32(Self.maximumCellCount / Int(clampedColumns))
        }
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
    /// The consumer's incremental picture is no longer valid and must be replaced
    /// wholesale with this screen snapshot. Emitted when the server re-bases a
    /// diff (its `oldNumber` is not the state the stream last rendered — possible
    /// whenever an acknowledgement is lost), because that diff's operations are
    /// relative to a frame the consumer never saw and cannot be applied
    /// incrementally. Official Mosh has no incremental stream at all: its client
    /// recomputes every frame from the latest framebuffer
    /// (`frontend/stmclient.cc` `display.new_frame`), which this resync mirrors.
    ///
    /// Limitation: the snapshot carries only the visible frame (rows, cursor, and
    /// display modes). Emulator-internal interpretation state — scroll region,
    /// tab stops, pending wrap, current pen attributes, parser state — is NOT
    /// carried and resets to a fresh screen's defaults in
    /// `MoshTerminalScreen.apply(.resync)`. An incremental `apply()` consumer may
    /// therefore render subsequent chained writes with reset interpretation state
    /// until the application re-asserts it. Consumers needing an always-exact
    /// picture should read `MoshSession.screenSnapshot` instead of reconstructing
    /// from this stream.
    case resync(MoshTerminalScreenSnapshot)

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
