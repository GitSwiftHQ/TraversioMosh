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

            switch Self.decodeMultibyteScalar(from: input, at: index) {
            case .complete(let scalar, let byteCount):
                tokens.append(Self.token(forScalar: scalar))
                index += byteCount
            case .incomplete:
                self.pendingBytes = Array(input[index...])
                return tokens
            case .malformed(let byteCount):
                tokens.append(.scalar(Self.replacementScalar))
                index += byteCount
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

    private static let replacementScalar = Unicode.Scalar(0xfffd)!

    private static func decodeMultibyteScalar(
        from input: [UInt8],
        at offset: Int
    ) -> MultibyteDecodeResult {
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
            return .malformed(byteCount: 1)
        }

        let availableByteCount = input.count - offset
        let availableEnd = min(input.count, offset + expectedByteCount)
        let availableBytes = Array(input[offset..<availableEnd])
        if let malformedByteCount = Self.malformedPrefixByteCount(availableBytes) {
            return .malformed(byteCount: malformedByteCount)
        }
        guard availableByteCount >= expectedByteCount else {
            return .incomplete
        }

        let bytes = availableBytes
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
            return .malformed(byteCount: expectedByteCount)
        }

        return .complete(scalar, byteCount: expectedByteCount)
    }

    private static func malformedPrefixByteCount(_ bytes: [UInt8]) -> Int? {
        guard bytes.count > 1 else {
            return nil
        }

        switch bytes[0] {
        case 0xc2...0xdf:
            return Self.isContinuation(bytes[1]) ? nil : 1
        case 0xe0:
            guard (0xa0...0xbf).contains(bytes[1]) else {
                return 1
            }
            return Self.malformedAfterValidContinuationPrefix(bytes, expectedByteCount: 3)
        case 0xe1...0xef:
            guard Self.isContinuation(bytes[1]) else {
                return 1
            }
            return Self.malformedAfterValidContinuationPrefix(bytes, expectedByteCount: 3)
        case 0xf0:
            guard (0x90...0xbf).contains(bytes[1]) else {
                return 1
            }
            return Self.malformedAfterValidContinuationPrefix(bytes, expectedByteCount: 4)
        case 0xf1...0xf3:
            guard Self.isContinuation(bytes[1]) else {
                return 1
            }
            return Self.malformedAfterValidContinuationPrefix(bytes, expectedByteCount: 4)
        case 0xf4:
            guard (0x80...0x8f).contains(bytes[1]) else {
                return 1
            }
            return Self.malformedAfterValidContinuationPrefix(bytes, expectedByteCount: 4)
        default:
            return 1
        }
    }

    private static func malformedAfterValidContinuationPrefix(
        _ bytes: [UInt8],
        expectedByteCount: Int
    ) -> Int? {
        guard bytes.count > 2 else {
            return nil
        }

        for index in 2..<min(bytes.count, expectedByteCount) {
            guard Self.isContinuation(bytes[index]) else {
                return index
            }
        }

        return nil
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        (0x80...0xbf).contains(byte)
    }
}

private enum MultibyteDecodeResult {
    case complete(Unicode.Scalar, byteCount: Int)
    case incomplete
    case malformed(byteCount: Int)
}
