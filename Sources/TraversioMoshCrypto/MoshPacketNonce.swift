// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public enum MoshPacketDirection: UInt8, Sendable {
    case toServer = 0
    case toClient = 1
}

public enum MoshPacketNonceError: Error, Equatable, Sendable {
    case sequenceOutOfRange(UInt64)
    case invalidRawByteCount(Int)
    case invalidDatagramByteCount(Int)
    case invalidPrefix([UInt8])
}

public struct MoshPacketNonce: Equatable, Sendable {
    public static let byteCount = 12
    public static let sequenceMask = UInt64.max >> 1
    public static let directionMask = UInt64(1) << 63

    public let rawBytes: [UInt8]
    public let sequence: UInt64
    public let direction: MoshPacketDirection
    public var datagramBytes: [UInt8] {
        Array(self.rawBytes.suffix(8))
    }

    public init(sequence: UInt64, direction: MoshPacketDirection) throws {
        guard sequence <= Self.sequenceMask else {
            throw MoshPacketNonceError.sequenceOutOfRange(sequence)
        }

        let value = sequence | (direction == .toClient ? Self.directionMask : 0)
        self.rawBytes = Self.rawBytes(for: value)
        self.sequence = sequence
        self.direction = direction
    }

    public init(rawBytes: some Collection<UInt8>) throws {
        let bytes = Array(rawBytes)
        guard bytes.count == Self.byteCount else {
            throw MoshPacketNonceError.invalidRawByteCount(bytes.count)
        }

        let prefix = Array(bytes.prefix(4))
        guard prefix == [0, 0, 0, 0] else {
            throw MoshPacketNonceError.invalidPrefix(prefix)
        }

        let value = bytes.suffix(8).reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }

        self.rawBytes = bytes
        self.sequence = value & Self.sequenceMask
        self.direction = (value & Self.directionMask) == 0 ? .toServer : .toClient
    }

    public init(datagramBytes: some Collection<UInt8>) throws {
        let bytes = Array(datagramBytes)
        guard bytes.count == 8 else {
            throw MoshPacketNonceError.invalidDatagramByteCount(bytes.count)
        }
        try self.init(rawBytes: [0, 0, 0, 0] + bytes)
    }

    private static func rawBytes(for value: UInt64) -> [UInt8] {
        [
            0,
            0,
            0,
            0,
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
