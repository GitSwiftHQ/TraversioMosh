// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public enum MoshTerminalInputParserError: Error, Equatable, Sendable {
    case invalidUTF8(offset: Int)
    case truncatedUTF8(byteCount: Int)
}

public enum MoshTerminalControl: Equatable, Sendable {
    case null
    case bell
    case backspace
    case horizontalTab
    case lineFeed
    case carriageReturn
    case escape
    case delete
    case c0(UInt8)
    case c1(UInt8)

    public static func ascii(_ byte: UInt8) -> MoshTerminalControl? {
        switch byte {
        case 0x00:
            return .null
        case 0x07:
            return .bell
        case 0x08:
            return .backspace
        case 0x09:
            return .horizontalTab
        case 0x0a, 0x0b, 0x0c:
            return .lineFeed
        case 0x0d:
            return .carriageReturn
        case 0x1b:
            return .escape
        case 0x7f:
            return .delete
        case 0x01...0x1f:
            return .c0(byte)
        default:
            return nil
        }
    }
}

public enum MoshTerminalInputToken: Equatable, Sendable {
    case scalar(Unicode.Scalar)
    case control(MoshTerminalControl)
}

public struct MoshTerminalInputParser: Sendable {
    private var pendingBytes: [UInt8]

    public init() {
        self.pendingBytes = []
    }

    public var pendingByteCount: Int {
        self.pendingBytes.count
    }

    public mutating func parse(_ bytes: some Collection<UInt8>) throws -> [MoshTerminalInputToken] {
        let input = self.pendingBytes + Array(bytes)
        var tokens: [MoshTerminalInputToken] = []
        var index = 0

        while index < input.count {
            let byte = input[index]

            if byte < 0x80 {
                tokens.append(Self.token(forASCII: byte))
                index += 1
                continue
            }

            switch try Self.decodeMultibyteScalar(from: input, at: index) {
            case .complete(let scalar, let byteCount):
                tokens.append(Self.token(forScalar: scalar))
                index += byteCount
            case .incomplete:
                self.pendingBytes = Array(input[index...])
                return tokens
            }
        }

        self.pendingBytes = []
        return tokens
    }

    public mutating func finish() throws {
        guard self.pendingBytes.isEmpty else {
            let byteCount = self.pendingBytes.count
            self.pendingBytes = []
            throw MoshTerminalInputParserError.truncatedUTF8(byteCount: byteCount)
        }
    }

    private static func token(forASCII byte: UInt8) -> MoshTerminalInputToken {
        if let control = MoshTerminalControl.ascii(byte) {
            return .control(control)
        }

        return .scalar(Unicode.Scalar(byte))
    }

    private static func token(forScalar scalar: Unicode.Scalar) -> MoshTerminalInputToken {
        if scalar.value >= 0x80, scalar.value <= 0x9f {
            return .control(.c1(UInt8(scalar.value)))
        }

        return .scalar(scalar)
    }

    private static func decodeMultibyteScalar(
        from input: [UInt8],
        at offset: Int
    ) throws -> MultibyteDecodeResult {
        let lead = input[offset]
        let expectedByteCount: Int

        switch lead {
        case 0xc2...0xdf:
            expectedByteCount = 2
        case 0xe0...0xef:
            expectedByteCount = 3
        case 0xf0...0xf4:
            expectedByteCount = 4
        default:
            throw MoshTerminalInputParserError.invalidUTF8(offset: offset)
        }

        guard input.count - offset >= expectedByteCount else {
            return .incomplete
        }

        let bytes = Array(input[offset..<(offset + expectedByteCount)])
        guard Self.hasValidContinuationBytes(bytes) else {
            throw MoshTerminalInputParserError.invalidUTF8(offset: offset)
        }

        let value: UInt32
        switch expectedByteCount {
        case 2:
            value = (UInt32(bytes[0] & 0x1f) << 6)
                | UInt32(bytes[1] & 0x3f)
        case 3:
            value = (UInt32(bytes[0] & 0x0f) << 12)
                | (UInt32(bytes[1] & 0x3f) << 6)
                | UInt32(bytes[2] & 0x3f)
        case 4:
            value = (UInt32(bytes[0] & 0x07) << 18)
                | (UInt32(bytes[1] & 0x3f) << 12)
                | (UInt32(bytes[2] & 0x3f) << 6)
                | UInt32(bytes[3] & 0x3f)
        default:
            preconditionFailure("Unexpected UTF-8 scalar byte count")
        }

        guard let scalar = Unicode.Scalar(value) else {
            throw MoshTerminalInputParserError.invalidUTF8(offset: offset)
        }

        return .complete(scalar, byteCount: expectedByteCount)
    }

    private static func hasValidContinuationBytes(_ bytes: [UInt8]) -> Bool {
        switch bytes[0] {
        case 0xc2...0xdf:
            return Self.isContinuation(bytes[1])
        case 0xe0:
            return (0xa0...0xbf).contains(bytes[1])
                && Self.isContinuation(bytes[2])
        case 0xe1...0xec:
            return Self.isContinuation(bytes[1])
                && Self.isContinuation(bytes[2])
        case 0xed:
            return (0x80...0x9f).contains(bytes[1])
                && Self.isContinuation(bytes[2])
        case 0xee...0xef:
            return Self.isContinuation(bytes[1])
                && Self.isContinuation(bytes[2])
        case 0xf0:
            return (0x90...0xbf).contains(bytes[1])
                && Self.isContinuation(bytes[2])
                && Self.isContinuation(bytes[3])
        case 0xf1...0xf3:
            return Self.isContinuation(bytes[1])
                && Self.isContinuation(bytes[2])
                && Self.isContinuation(bytes[3])
        case 0xf4:
            return (0x80...0x8f).contains(bytes[1])
                && Self.isContinuation(bytes[2])
                && Self.isContinuation(bytes[3])
        default:
            return false
        }
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        (0x80...0xbf).contains(byte)
    }
}

private enum MultibyteDecodeResult {
    case complete(Unicode.Scalar, byteCount: Int)
    case incomplete
}
