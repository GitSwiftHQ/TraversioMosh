// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public enum MoshProtobufError: Error, Equatable, Sendable {
    case truncated
    case malformedVarint
    case invalidFieldNumber(Int)
    case varintOutOfRange(fieldNumber: Int, value: UInt64)
    case unsupportedWireType(Int)
    case unexpectedWireType(fieldNumber: Int, expected: Int, actual: Int)
    case recursionLimitExceeded
}

public struct MoshTerminalSize: Equatable, Sendable {
    public let columns: Int32
    public let rows: Int32

    public init(columns: Int32, rows: Int32) {
        self.columns = columns
        self.rows = rows
    }
}

public struct MoshTransportInstruction: Equatable, Sendable {
    public var protocolVersion: UInt32?
    public var oldNumber: UInt64?
    public var newNumber: UInt64?
    public var acknowledgementNumber: UInt64?
    public var throwawayNumber: UInt64?
    public var diff: [UInt8]?
    public var chaff: [UInt8]?

    public init(
        protocolVersion: UInt32? = nil,
        oldNumber: UInt64? = nil,
        newNumber: UInt64? = nil,
        acknowledgementNumber: UInt64? = nil,
        throwawayNumber: UInt64? = nil,
        diff: [UInt8]? = nil,
        chaff: [UInt8]? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.acknowledgementNumber = acknowledgementNumber
        self.throwawayNumber = throwawayNumber
        self.diff = diff
        self.chaff = chaff
    }

    public func serializedBytes() -> [UInt8] {
        var writer = ProtobufWriter()
        writer.appendOptionalVarint(fieldNumber: 1, value: self.protocolVersion.map(UInt64.init))
        writer.appendOptionalVarint(fieldNumber: 2, value: self.oldNumber)
        writer.appendOptionalVarint(fieldNumber: 3, value: self.newNumber)
        writer.appendOptionalVarint(fieldNumber: 4, value: self.acknowledgementNumber)
        writer.appendOptionalVarint(fieldNumber: 5, value: self.throwawayNumber)
        writer.appendOptionalBytes(fieldNumber: 6, value: self.diff)
        writer.appendOptionalBytes(fieldNumber: 7, value: self.chaff)
        return writer.bytes
    }

    public init(serializedBytes: [UInt8]) throws {
        var reader = ProtobufReader(bytes: serializedBytes)
        self.init()

        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                self.protocolVersion = try reader.readUInt32(field: field)
            case 2:
                self.oldNumber = try reader.readVarint(field: field)
            case 3:
                self.newNumber = try reader.readVarint(field: field)
            case 4:
                self.acknowledgementNumber = try reader.readVarint(field: field)
            case 5:
                self.throwawayNumber = try reader.readVarint(field: field)
            case 6:
                self.diff = try reader.readLengthDelimited(field: field)
            case 7:
                self.chaff = try reader.readLengthDelimited(field: field)
            default:
                try reader.skip(field: field)
            }
        }
    }
}

public struct MoshClientMessage: Equatable, Sendable {
    public var instructions: [MoshClientInstruction]

    public init(instructions: [MoshClientInstruction] = []) {
        self.instructions = instructions
    }

    public func serializedBytes() -> [UInt8] {
        var writer = ProtobufWriter()
        for instruction in self.instructions {
            writer.appendBytes(fieldNumber: 1, value: instruction.serializedBytes())
        }
        return writer.bytes
    }

    public init(serializedBytes: [UInt8]) throws {
        var reader = ProtobufReader(bytes: serializedBytes)
        var instructions: [MoshClientInstruction] = []

        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                instructions.append(try MoshClientInstruction(serializedBytes: reader.readLengthDelimited(field: field)))
            default:
                try reader.skip(field: field)
            }
        }

        self.instructions = instructions
    }
}

public struct MoshClientInstruction: Equatable, Sendable {
    public var keystrokes: [UInt8]?
    public var resize: MoshTerminalSize?

    public init(keystrokes: [UInt8]? = nil, resize: MoshTerminalSize? = nil) {
        self.keystrokes = keystrokes
        self.resize = resize
    }

    public func serializedBytes() -> [UInt8] {
        var writer = ProtobufWriter()
        if let keystrokes {
            writer.appendBytes(fieldNumber: 2, value: Self.serializedKeystroke(keystrokes))
        }
        if let resize {
            writer.appendBytes(fieldNumber: 3, value: Self.serializedResize(resize))
        }
        return writer.bytes
    }

    public init(serializedBytes: [UInt8]) throws {
        var reader = ProtobufReader(bytes: serializedBytes)
        self.init()

        while let field = try reader.nextField() {
            switch field.number {
            case 2:
                self.keystrokes = try Self.parseKeystroke(reader.readLengthDelimited(field: field))
            case 3:
                self.resize = try Self.parseResize(reader.readLengthDelimited(field: field))
            default:
                try reader.skip(field: field)
            }
        }
    }

    private static func serializedKeystroke(_ keys: [UInt8]) -> [UInt8] {
        var writer = ProtobufWriter()
        writer.appendBytes(fieldNumber: 4, value: keys)
        return writer.bytes
    }

    private static func parseKeystroke(_ bytes: [UInt8]) throws -> [UInt8]? {
        var reader = ProtobufReader(bytes: bytes)
        var keys: [UInt8]?

        while let field = try reader.nextField() {
            switch field.number {
            case 4:
                keys = try reader.readLengthDelimited(field: field)
            default:
                try reader.skip(field: field)
            }
        }

        return keys
    }

    fileprivate static func serializedResize(_ resize: MoshTerminalSize) -> [UInt8] {
        var writer = ProtobufWriter()
        // proto2 int32: sign-extend to 64 bits so negative dimensions encode as
        // the canonical 10-byte varint a conformant peer expects. Non-negative
        // values still encode in <= 5 bytes (identical to the prior encoding).
        writer.appendVarint(fieldNumber: 5, value: UInt64(bitPattern: Int64(resize.columns)))
        writer.appendVarint(fieldNumber: 6, value: UInt64(bitPattern: Int64(resize.rows)))
        return writer.bytes
    }

    fileprivate static func parseResize(_ bytes: [UInt8]) throws -> MoshTerminalSize? {
        var reader = ProtobufReader(bytes: bytes)
        var columns: Int32?
        var rows: Int32?

        while let field = try reader.nextField() {
            switch field.number {
            case 5:
                columns = try reader.readInt32(field: field)
            case 6:
                rows = try reader.readInt32(field: field)
            default:
                try reader.skip(field: field)
            }
        }

        guard let columns, let rows else {
            return nil
        }
        return MoshTerminalSize(columns: columns, rows: rows)
    }
}

public struct MoshHostMessage: Equatable, Sendable {
    public var instructions: [MoshHostInstruction]

    public init(instructions: [MoshHostInstruction] = []) {
        self.instructions = instructions
    }

    public func serializedBytes() -> [UInt8] {
        var writer = ProtobufWriter()
        for instruction in self.instructions {
            writer.appendBytes(fieldNumber: 1, value: instruction.serializedBytes())
        }
        return writer.bytes
    }

    public init(serializedBytes: [UInt8]) throws {
        var reader = ProtobufReader(bytes: serializedBytes)
        var instructions: [MoshHostInstruction] = []

        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                instructions.append(try MoshHostInstruction(serializedBytes: reader.readLengthDelimited(field: field)))
            default:
                try reader.skip(field: field)
            }
        }

        self.instructions = instructions
    }
}

public struct MoshHostInstruction: Equatable, Sendable {
    public var hostBytes: [UInt8]?
    public var resize: MoshTerminalSize?
    public var echoAcknowledgementNumber: UInt64?

    public init(
        hostBytes: [UInt8]? = nil,
        resize: MoshTerminalSize? = nil,
        echoAcknowledgementNumber: UInt64? = nil
    ) {
        self.hostBytes = hostBytes
        self.resize = resize
        self.echoAcknowledgementNumber = echoAcknowledgementNumber
    }

    public func serializedBytes() -> [UInt8] {
        var writer = ProtobufWriter()
        if let hostBytes {
            writer.appendBytes(fieldNumber: 2, value: Self.serializedHostBytes(hostBytes))
        }
        if let resize {
            writer.appendBytes(fieldNumber: 3, value: MoshClientInstruction.serializedResize(resize))
        }
        if let echoAcknowledgementNumber {
            writer.appendBytes(fieldNumber: 7, value: Self.serializedEchoAck(echoAcknowledgementNumber))
        }
        return writer.bytes
    }

    public init(serializedBytes: [UInt8]) throws {
        var reader = ProtobufReader(bytes: serializedBytes)
        self.init()

        while let field = try reader.nextField() {
            switch field.number {
            case 2:
                self.hostBytes = try Self.parseHostBytes(reader.readLengthDelimited(field: field))
            case 3:
                self.resize = try MoshClientInstruction.parseResize(reader.readLengthDelimited(field: field))
            case 7:
                self.echoAcknowledgementNumber = try Self.parseEchoAck(reader.readLengthDelimited(field: field))
            default:
                try reader.skip(field: field)
            }
        }
    }

    private static func serializedHostBytes(_ bytes: [UInt8]) -> [UInt8] {
        var writer = ProtobufWriter()
        writer.appendBytes(fieldNumber: 4, value: bytes)
        return writer.bytes
    }

    private static func parseHostBytes(_ bytes: [UInt8]) throws -> [UInt8]? {
        var reader = ProtobufReader(bytes: bytes)
        var hostBytes: [UInt8]?

        while let field = try reader.nextField() {
            switch field.number {
            case 4:
                hostBytes = try reader.readLengthDelimited(field: field)
            default:
                try reader.skip(field: field)
            }
        }

        return hostBytes
    }

    private static func serializedEchoAck(_ number: UInt64) -> [UInt8] {
        var writer = ProtobufWriter()
        writer.appendVarint(fieldNumber: 8, value: number)
        return writer.bytes
    }

    private static func parseEchoAck(_ bytes: [UInt8]) throws -> UInt64? {
        var reader = ProtobufReader(bytes: bytes)
        var number: UInt64?

        while let field = try reader.nextField() {
            switch field.number {
            case 8:
                number = try reader.readVarint(field: field)
            default:
                try reader.skip(field: field)
            }
        }

        return number
    }
}

private struct ProtobufField {
    let number: Int
    let wireType: Int
}

private struct ProtobufWriter {
    private(set) var bytes: [UInt8] = []

    mutating func appendOptionalVarint(fieldNumber: Int, value: UInt64?) {
        guard let value else {
            return
        }
        self.appendVarint(fieldNumber: fieldNumber, value: value)
    }

    mutating func appendVarint(fieldNumber: Int, value: UInt64) {
        self.appendKey(fieldNumber: fieldNumber, wireType: 0)
        self.appendRawVarint(value)
    }

    mutating func appendOptionalBytes(fieldNumber: Int, value: [UInt8]?) {
        guard let value else {
            return
        }
        self.appendBytes(fieldNumber: fieldNumber, value: value)
    }

    mutating func appendBytes(fieldNumber: Int, value: [UInt8]) {
        self.appendKey(fieldNumber: fieldNumber, wireType: 2)
        self.appendRawVarint(UInt64(value.count))
        self.bytes.append(contentsOf: value)
    }

    private mutating func appendKey(fieldNumber: Int, wireType: Int) {
        self.appendRawVarint(UInt64((fieldNumber << 3) | wireType))
    }

    private mutating func appendRawVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            self.bytes.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        self.bytes.append(UInt8(value))
    }
}

private struct ProtobufReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func nextField() throws -> ProtobufField? {
        guard self.offset < self.bytes.count else {
            return nil
        }

        let key = try self.readVarint()
        let fieldNumber = Int(key >> 3)
        let wireType = Int(key & 0x07)

        guard fieldNumber > 0 else {
            throw MoshProtobufError.invalidFieldNumber(fieldNumber)
        }

        return ProtobufField(number: fieldNumber, wireType: wireType)
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while shift < 64 {
            guard self.offset < self.bytes.count else {
                throw MoshProtobufError.truncated
            }

            let byte = self.bytes[self.offset]
            self.offset += 1

            // The 10th byte (shift == 63) of a base-128 varint may only carry
            // bit 63. Payload bits 1–6 would map to bit positions 64–69, which
            // do not exist in a UInt64. Accepting them would silently drop those
            // bits (a non-canonical, lossy encoding), so reject them instead.
            if shift == 63, (byte & 0x7e) != 0 {
                throw MoshProtobufError.malformedVarint
            }

            result |= UInt64(byte & 0x7f) << shift

            if (byte & 0x80) == 0 {
                return result
            }

            shift += 7
        }

        throw MoshProtobufError.malformedVarint
    }

    mutating func readInt32(field: ProtobufField) throws -> Int32 {
        // proto2 int32 is transmitted as a full-width 64-bit varint; negative
        // values arrive sign-extended to 10 bytes. Truncate to the low 32 bits
        // and reinterpret as two's-complement Int32.
        let value = try self.readVarint(field: field)
        return Int32(truncatingIfNeeded: value)
    }

    mutating func readVarint(field: ProtobufField) throws -> UInt64 {
        try self.requireWireType(0, field: field)
        return try self.readVarint()
    }

    mutating func readUInt32(field: ProtobufField) throws -> UInt32 {
        let value = try self.readVarint(field: field)
        guard value <= UInt64(UInt32.max) else {
            throw MoshProtobufError.varintOutOfRange(fieldNumber: field.number, value: value)
        }
        return UInt32(value)
    }

    mutating func readLengthDelimited(field: ProtobufField) throws -> [UInt8] {
        try self.requireWireType(2, field: field)
        return try self.readLengthDelimited()
    }

    private mutating func readLengthDelimited() throws -> [UInt8] {
        // Keep the declared length as UInt64 and bounds-check it against the
        // remaining byte count BEFORE any Int conversion. A trapping
        // `Int(UInt64)` here would crash the process on a length > Int.max sent
        // by a peer. `remaining` is a non-negative Int (offset <= count), so a
        // length that survives the guard is provably <= Int.max and safe to
        // narrow.
        let length = try self.readVarint()
        let remaining = UInt64(self.bytes.count - self.offset)
        guard length <= remaining else {
            throw MoshProtobufError.truncated
        }

        let count = Int(length)
        defer {
            self.offset += count
        }
        return Array(self.bytes[self.offset..<(self.offset + count)])
    }

    /// Group skipping recurses per nesting level, so the depth must be capped
    /// or a short run of start-group tags overflows the stack. 100 matches the
    /// C++ protobuf default recursion limit.
    private static let maximumGroupDepth = 100

    mutating func skip(field: ProtobufField) throws {
        try self.skip(field: field, groupDepth: 0)
    }

    private mutating func skip(field: ProtobufField, groupDepth: Int) throws {
        switch field.wireType {
        case 0:
            _ = try self.readVarint()
        case 1:
            try self.skipBytes(8)
        case 2:
            _ = try self.readLengthDelimited()
        case 3:
            // Start-group: recursively skip fields up to the matching end-group.
            guard groupDepth < Self.maximumGroupDepth else {
                throw MoshProtobufError.recursionLimitExceeded
            }
            try self.skipGroup(fieldNumber: field.number, groupDepth: groupDepth + 1)
        case 5:
            try self.skipBytes(4)
        default:
            // Includes wire type 4 (end-group) encountered without a matching
            // start-group, which is malformed.
            throw MoshProtobufError.unsupportedWireType(field.wireType)
        }
    }

    private mutating func skipGroup(fieldNumber: Int, groupDepth: Int) throws {
        while let field = try self.nextField() {
            if field.wireType == 4 {
                guard field.number == fieldNumber else {
                    // Mismatched end-group tag is malformed.
                    throw MoshProtobufError.unsupportedWireType(field.wireType)
                }
                return
            }
            try self.skip(field: field, groupDepth: groupDepth)
        }
        // Ran out of bytes before the matching end-group.
        throw MoshProtobufError.truncated
    }

    private func requireWireType(_ expected: Int, field: ProtobufField) throws {
        guard field.wireType == expected else {
            throw MoshProtobufError.unexpectedWireType(
                fieldNumber: field.number,
                expected: expected,
                actual: field.wireType
            )
        }
    }

    private mutating func skipBytes(_ count: Int) throws {
        guard self.offset + count <= self.bytes.count else {
            throw MoshProtobufError.truncated
        }
        self.offset += count
    }
}
