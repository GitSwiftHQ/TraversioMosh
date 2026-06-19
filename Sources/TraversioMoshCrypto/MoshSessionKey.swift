// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Foundation

public enum MoshSessionKeyError: Error, Equatable, Sendable {
    case invalidEncodedLength(actualUTF8Bytes: Int)
    case invalidBase64
    case invalidDecodedByteCount(Int)
    case nonCanonicalEncoding
    case invalidRawByteCount(Int)
}

public struct MoshSessionKey: Equatable, Sendable {
    public static let encodedLength = 22
    public static let byteCount = 16

    private let storage: [UInt8]

    public init(encodedRepresentation: String) throws {
        let encodedByteCount = encodedRepresentation.utf8.count
        guard encodedByteCount == Self.encodedLength else {
            throw MoshSessionKeyError.invalidEncodedLength(actualUTF8Bytes: encodedByteCount)
        }

        guard let decoded = Data(base64Encoded: encodedRepresentation + "==") else {
            throw MoshSessionKeyError.invalidBase64
        }

        let bytes = Array(decoded)
        guard bytes.count == Self.byteCount else {
            throw MoshSessionKeyError.invalidDecodedByteCount(bytes.count)
        }

        let canonical = Self.encode(bytes)
        guard canonical == encodedRepresentation else {
            throw MoshSessionKeyError.nonCanonicalEncoding
        }

        self.storage = bytes
    }

    public init(rawBytes: some Collection<UInt8>) throws {
        let bytes = Array(rawBytes)
        guard bytes.count == Self.byteCount else {
            throw MoshSessionKeyError.invalidRawByteCount(bytes.count)
        }

        self.storage = bytes
    }

    public var rawBytes: [UInt8] {
        self.storage
    }

    public var encodedRepresentation: String {
        Self.encode(self.storage)
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        let encoded = Data(bytes).base64EncodedString()
        precondition(encoded.hasSuffix("=="), "A 16-byte Mosh session key must encode with == padding.")
        return String(encoded.dropLast(2))
    }
}
