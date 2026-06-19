// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public enum MoshPacketWireError: Error, Equatable, Sendable {
    case truncatedPacketHeader(Int)
    case truncatedFragmentHeader(Int)
    case fragmentNumberOutOfRange(UInt16)
}

public struct MoshPacketPlaintext: Equatable, Sendable {
    public static let headerByteCount = 4

    public let timestamp: UInt16
    public let timestampReply: UInt16
    public let payload: [UInt8]

    public init(timestamp: UInt16, timestampReply: UInt16, payload: [UInt8]) {
        self.timestamp = timestamp
        self.timestampReply = timestampReply
        self.payload = payload
    }

    public init(serializedBytes: [UInt8]) throws {
        guard serializedBytes.count >= Self.headerByteCount else {
            throw MoshPacketWireError.truncatedPacketHeader(serializedBytes.count)
        }

        self.timestamp = Self.readUInt16(serializedBytes, at: 0)
        self.timestampReply = Self.readUInt16(serializedBytes, at: 2)
        self.payload = Array(serializedBytes.dropFirst(Self.headerByteCount))
    }

    public func serializedBytes() -> [UInt8] {
        Self.writeUInt16(self.timestamp)
            + Self.writeUInt16(self.timestampReply)
            + self.payload
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    fileprivate static func writeUInt16(_ value: UInt16) -> [UInt8] {
        [
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }
}

public struct MoshFragment: Equatable, Sendable {
    public static let headerByteCount = 10
    public static let maxFragmentNumber = UInt16.max >> 1
    private static let finalBit = UInt16(1) << 15

    public let instructionID: UInt64
    public let fragmentNumber: UInt16
    public let isFinal: Bool
    public let contents: [UInt8]

    public init(
        instructionID: UInt64,
        fragmentNumber: UInt16,
        isFinal: Bool,
        contents: [UInt8]
    ) throws {
        guard fragmentNumber <= Self.maxFragmentNumber else {
            throw MoshPacketWireError.fragmentNumberOutOfRange(fragmentNumber)
        }

        self.instructionID = instructionID
        self.fragmentNumber = fragmentNumber
        self.isFinal = isFinal
        self.contents = contents
    }

    public init(serializedBytes: [UInt8]) throws {
        guard serializedBytes.count >= Self.headerByteCount else {
            throw MoshPacketWireError.truncatedFragmentHeader(serializedBytes.count)
        }

        let combinedFragmentNumber = Self.readUInt16(serializedBytes, at: 8)
        self.instructionID = Self.readUInt64(serializedBytes, at: 0)
        self.fragmentNumber = combinedFragmentNumber & Self.maxFragmentNumber
        self.isFinal = (combinedFragmentNumber & Self.finalBit) != 0
        self.contents = Array(serializedBytes.dropFirst(Self.headerByteCount))
    }

    public func serializedBytes() -> [UInt8] {
        var combinedFragmentNumber = self.fragmentNumber
        if self.isFinal {
            combinedFragmentNumber |= Self.finalBit
        }

        return Self.writeUInt64(self.instructionID)
            + MoshPacketPlaintext.writeUInt16(combinedFragmentNumber)
            + self.contents
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value = UInt64(0)
        for byte in bytes[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    private static func writeUInt64(_ value: UInt64) -> [UInt8] {
        [
            UInt8((value >> 56) & 0xff),
            UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }
}
