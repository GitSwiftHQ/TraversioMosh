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

/// Reference-backed, wipeable storage for the 16-byte Mosh session key.
///
/// The key bytes are held in a stable, self-owned heap buffer rather than a
/// Swift `[UInt8]`. A Swift array can be copied or reallocated by the runtime
/// (copy-on-write, resizing), so `memset_s` on an array's transient buffer is
/// not a reliable wipe: other copies may survive untouched. A dedicated
/// `UnsafeMutableBufferPointer` gives one fixed address we fully control and
/// can guarantee to zero.
///
/// Because this is a reference type, every `MoshSessionKey` value that shares
/// the same storage shares one wipeable buffer: wiping through any copy wipes
/// them all. Zeroing also happens automatically in `deinit` when the last
/// reference is released. `memset_s` is used because it is guaranteed by the C
/// standard (and Darwin) not to be elided by the optimizer, unlike a plain
/// zeroing loop or `memset`.
private final class MoshSessionKeyStorage: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<UInt8>

    init(_ bytes: [UInt8]) {
        let allocated = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
        _ = allocated.initialize(from: bytes)
        self.buffer = allocated
    }

    func wipe() {
        guard let base = self.buffer.baseAddress, self.buffer.count > 0 else {
            return
        }
        // memset_s is guaranteed not to be optimized away.
        memset_s(base, self.buffer.count, 0, self.buffer.count)
    }

    deinit {
        self.wipe()
        self.buffer.deallocate()
    }
}

public struct MoshSessionKey: Sendable {
    public static let encodedLength = 22
    public static let byteCount = 16

    private let storage: MoshSessionKeyStorage

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

        self.storage = MoshSessionKeyStorage(bytes)
    }

    public init(rawBytes: some Collection<UInt8>) throws {
        let bytes = Array(rawBytes)
        guard bytes.count == Self.byteCount else {
            throw MoshSessionKeyError.invalidRawByteCount(bytes.count)
        }

        self.storage = MoshSessionKeyStorage(bytes)
    }

    public var rawBytes: [UInt8] {
        Array(self.storage.buffer)
    }

    public var encodedRepresentation: String {
        Self.encode(Array(self.storage.buffer))
    }

    /// Securely zeroes the shared key buffer.
    ///
    /// Because storage is reference-backed, this wipes every `MoshSessionKey`
    /// value that shares the same buffer (for example, copies made by
    /// assignment or by passing the key around). Intended to be called at
    /// session teardown once the key is no longer needed. After a wipe the key
    /// reads as all-zero bytes.
    ///
    /// Note: types that made an independent copy of the raw bytes (for example
    /// a cipher that derived its own key schedule via `rawBytes`) are not
    /// affected by this call and retain their own material.
    public func wipe() {
        self.storage.wipe()
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        let encoded = Data(bytes).base64EncodedString()
        precondition(encoded.hasSuffix("=="), "A 16-byte Mosh session key must encode with == padding.")
        return String(encoded.dropLast(2))
    }
}

extension MoshSessionKey: Equatable {
    public static func == (lhs: MoshSessionKey, rhs: MoshSessionKey) -> Bool {
        let lhsBuffer = lhs.storage.buffer
        let rhsBuffer = rhs.storage.buffer
        guard lhsBuffer.count == rhsBuffer.count else {
            return false
        }
        // Constant-time comparison to avoid leaking key material through timing.
        var difference: UInt8 = 0
        for index in 0..<lhsBuffer.count {
            difference |= lhsBuffer[index] ^ rhsBuffer[index]
        }
        return difference == 0
    }
}

extension MoshSessionKey: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never renders raw key bytes. Prevents string interpolation and logging
    /// from leaking secret material.
    public var description: String {
        "MoshSessionKey(<redacted>)"
    }

    /// Never renders raw key bytes, including via `String(reflecting:)`.
    public var debugDescription: String {
        "MoshSessionKey(<redacted>)"
    }
}
