// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Foundation
import os

public enum MoshSessionKeyError: Error, Equatable, Sendable {
    case invalidEncodedLength(actualUTF8Bytes: Int)
    case invalidBase64
    case invalidDecodedByteCount(Int)
    case nonCanonicalEncoding
    case invalidRawByteCount(Int)
}

/// Best-effort zeroization for locally owned intermediate secret buffers.
///
/// Swift arrays and `Data` are copy-on-write: if the value is still shared
/// with another reference when the wipe runs, the mutable-access entry point
/// copies the storage first and only the copy is zeroed. These helpers are
/// therefore only a reliable wipe for values the caller uniquely owns (for
/// example, a decode intermediate created and consumed in one scope). The
/// guaranteed wipe path for long-lived key material is the dedicated
/// `UnsafeMutableBufferPointer`-backed storage below.
internal enum MoshKeyWipe {
    internal static func bestEffort(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else {
                return
            }
            memset_s(base, buffer.count, 0, buffer.count)
        }
    }

    internal static func bestEffort(_ data: inout Data) {
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else {
                return
            }
            memset_s(base, raw.count, 0, raw.count)
        }
    }
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
///
/// Concurrency: `wipe()` may race reads (`rawBytes`, `==`, and so on), so all
/// buffer access goes through an unfair lock. The key is only read at session
/// setup — never per datagram (`MoshAES128OCB` copies it once at init) — so
/// the lock is not on any hot path. `deinit` skips the lock because the last
/// release is exclusive by definition. This makes the `@unchecked Sendable`
/// annotation sound.
private final class MoshSessionKeyStorage: @unchecked Sendable {
    private let buffer: UnsafeMutableBufferPointer<UInt8>
    private let lock = OSAllocatedUnfairLock()

    init(_ bytes: [UInt8]) {
        let allocated = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
        _ = allocated.initialize(from: bytes)
        self.buffer = allocated
    }

    /// Grants read-only access to the key bytes while holding the lock, so a
    /// concurrent `wipe()` cannot mutate the buffer mid-read.
    func withLockedBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try self.lock.withLockUnchecked {
            try body(UnsafeBufferPointer(self.buffer))
        }
    }

    func wipe() {
        self.lock.withLockUnchecked {
            self.wipeAssumingExclusiveAccess()
        }
    }

    private func wipeAssumingExclusiveAccess() {
        guard let base = self.buffer.baseAddress, self.buffer.count > 0 else {
            return
        }
        // memset_s is guaranteed not to be optimized away.
        memset_s(base, self.buffer.count, 0, self.buffer.count)
    }

    deinit {
        // The final release holds the only reference; no lock needed.
        self.wipeAssumingExclusiveAccess()
        self.buffer.deallocate()
    }
}

public struct MoshSessionKey: Sendable {
    public static let encodedLength = 22
    public static let byteCount = 16

    private let storage: MoshSessionKeyStorage

    /// Decodes the 22-character Mosh base64 key encoding.
    ///
    /// Locally owned decode intermediates (the decoded `Data`, the byte array,
    /// and the canonical re-encoding's backing `Data`) are best-effort wiped
    /// before this initializer returns. The caller-owned
    /// `encodedRepresentation` string itself is immutable and cannot be wiped
    /// from here; the caller remains responsible for its copy of the secret.
    public init(encodedRepresentation: String) throws {
        let encodedByteCount = encodedRepresentation.utf8.count
        guard encodedByteCount == Self.encodedLength else {
            throw MoshSessionKeyError.invalidEncodedLength(actualUTF8Bytes: encodedByteCount)
        }

        guard var decoded = Data(base64Encoded: encodedRepresentation + "==") else {
            throw MoshSessionKeyError.invalidBase64
        }
        defer { MoshKeyWipe.bestEffort(&decoded) }

        var bytes = Array(decoded)
        defer { MoshKeyWipe.bestEffort(&bytes) }

        guard bytes.count == Self.byteCount else {
            throw MoshSessionKeyError.invalidDecodedByteCount(bytes.count)
        }

        let canonical = Self.encode(bytes)
        guard canonical == encodedRepresentation else {
            throw MoshSessionKeyError.nonCanonicalEncoding
        }

        self.storage = MoshSessionKeyStorage(bytes)
    }

    /// Copies the raw key bytes into wipeable storage.
    ///
    /// The locally owned intermediate array is best-effort wiped before this
    /// initializer returns. If `rawBytes` is itself a `[UInt8]`, the
    /// caller-owned original cannot be wiped from here (copy-on-write hands
    /// the wipe a fresh copy); the caller remains responsible for it.
    public init(rawBytes: some Collection<UInt8>) throws {
        var bytes = Array(rawBytes)
        defer { MoshKeyWipe.bestEffort(&bytes) }

        guard bytes.count == Self.byteCount else {
            throw MoshSessionKeyError.invalidRawByteCount(bytes.count)
        }

        self.storage = MoshSessionKeyStorage(bytes)
    }

    /// A copy of the key bytes. The returned array is caller-owned and cannot
    /// be wiped by this type; prefer `withUnsafeKeyBytes` inside the module.
    public var rawBytes: [UInt8] {
        self.storage.withLockedBytes { Array($0) }
    }

    public var encodedRepresentation: String {
        var bytes = self.storage.withLockedBytes { Array($0) }
        defer { MoshKeyWipe.bestEffort(&bytes) }
        return Self.encode(bytes)
    }

    /// Grants locked, read-only access to the key bytes without minting an
    /// intermediate copy. Used by `MoshAES128OCB` to copy the key straight
    /// into its own wipeable storage.
    internal func withUnsafeKeyBytes<R>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        try self.storage.withLockedBytes(body)
    }

    /// Securely zeroes the shared key buffer.
    ///
    /// Because storage is reference-backed, this wipes every `MoshSessionKey`
    /// value that shares the same buffer (for example, copies made by
    /// assignment or by passing the key around). Intended to be called at
    /// session teardown once the key is no longer needed. After a wipe the key
    /// reads as all-zero bytes.
    ///
    /// Concurrency: safe to call while other tasks read this key. Buffer
    /// access is serialized by an internal lock, so a racing reader observes
    /// either the key or all zeros — never a torn mix. Deterministic teardown
    /// still requires the caller to stop using the key before wiping;
    /// `deinit` of the last reference is the guaranteed fallback wipe.
    ///
    /// Note: copies of the key material made *before* the wipe are not
    /// affected. `MoshAES128OCB` owns such a copy, but zeroes it itself when
    /// the cipher chain is deallocated. Arrays previously returned by
    /// `rawBytes` are caller-owned and remain the caller's responsibility.
    public func wipe() {
        self.storage.wipe()
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        var data = Data(bytes)
        defer { MoshKeyWipe.bestEffort(&data) }
        let encoded = data.base64EncodedString()
        precondition(encoded.hasSuffix("=="), "A 16-byte Mosh session key must encode with == padding.")
        return String(encoded.dropLast(2))
    }
}

extension MoshSessionKey: Equatable {
    /// Constant-time comparison of the key bytes.
    ///
    /// Locks are never nested: the left-hand key is snapshotted under its own
    /// lock, then compared under the right-hand lock, which rules out lock-
    /// order deadlock when two keys are compared concurrently in both orders.
    /// A comparison racing `wipe()` sees each side either pre- or post-wipe.
    public static func == (lhs: MoshSessionKey, rhs: MoshSessionKey) -> Bool {
        if lhs.storage === rhs.storage {
            return true
        }

        var lhsBytes = lhs.storage.withLockedBytes { Array($0) }
        defer { MoshKeyWipe.bestEffort(&lhsBytes) }

        return rhs.storage.withLockedBytes { rhsBuffer in
            guard lhsBytes.count == rhsBuffer.count else {
                return false
            }
            // Constant-time comparison to avoid leaking key material through timing.
            var difference: UInt8 = 0
            for index in 0..<rhsBuffer.count {
                difference |= lhsBytes[index] ^ rhsBuffer[index]
            }
            return difference == 0
        }
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
