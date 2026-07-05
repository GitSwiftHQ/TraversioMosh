// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import CommonCrypto
import Foundation

public enum MoshAES128OCBError: Error, Equatable, Sendable {
    case invalidNonceLength(Int)
    case ciphertextTooShort(Int)
    case authenticationFailed
    case commonCrypto(status: Int32)
}

public struct MoshAES128OCB: Sendable {
    public static let blockSize = 16
    public static let tagSize = 16

    /// All long-lived key-derived material (raw AES key plus the OCB L table)
    /// lives in this shared, reference-backed storage and is zeroed when the
    /// last copy of the cipher chain is deallocated. See `OCBKeyMaterial`.
    private let material: OCBKeyMaterial

    private var lStar: Block { self.material.lStar }
    private var lDollar: Block { self.material.lDollar }
    private var lZero: Block { self.material.lZero }

    public init(sessionKey: MoshSessionKey) throws {
        // Copies the key straight from the session key's locked buffer into
        // the cipher's own wipeable storage, without an intermediate array.
        self.material = try sessionKey.withUnsafeKeyBytes { keyBytes in
            try OCBKeyMaterial(key: keyBytes)
        }
    }

    public init(rawKey: some Collection<UInt8>) throws {
        // The local intermediate is best-effort wiped; if `rawKey` is itself a
        // `[UInt8]`, the caller-owned original remains the caller's
        // responsibility (copy-on-write prevents wiping it from here).
        var keyBytes = Array(rawKey)
        defer { MoshKeyWipe.bestEffort(&keyBytes) }

        self.material = try keyBytes.withUnsafeBufferPointer { buffer in
            try OCBKeyMaterial(key: buffer)
        }
    }

    /// Test-only hook: observes the key-material wipe that runs when the last
    /// reference to this cipher's key material is released. The observer is
    /// called from `deinit`, after `memset_s`, with whether the material reads
    /// as all-zero. Not synchronized — install before sharing across tasks.
    internal func _installKeyMaterialDeinitWipeHook(
        _ observer: @escaping @Sendable (_ zeroedOnDeinit: Bool) -> Void
    ) {
        self.material.deinitWipeObserver = observer
    }

    public func seal(
        plaintext: [UInt8],
        nonce: [UInt8],
        associatedData: [UInt8] = []
    ) throws -> [UInt8] {
        try Self.validateNonce(nonce)

        let hash = try self.hash(associatedData)
        let offset0 = try self.initialOffset(nonce: nonce)
        let fullBlockCount = plaintext.count / Self.blockSize
        let partialByteCount = plaintext.count % Self.blockSize

        var offset = offset0
        var checksum = Block.zero
        var ciphertext: [UInt8] = []
        ciphertext.reserveCapacity(plaintext.count + Self.tagSize)

        for blockIndex in 1..<(fullBlockCount + 1) {
            offset.xorInPlace(self.lSubscript(blockIndex.trailingZeroBitCount))

            let range = ((blockIndex - 1) * Self.blockSize)..<(blockIndex * Self.blockSize)
            let plaintextBlock = Block(Array(plaintext[range]))
            let encrypted = try self.material.encrypt(plaintextBlock.xored(with: offset))
            let ciphertextBlock = encrypted.xored(with: offset)

            ciphertext.append(contentsOf: ciphertextBlock.bytes)
            checksum.xorInPlace(plaintextBlock)
        }

        let tag: Block
        if partialByteCount > 0 {
            let offsetStar = offset.xored(with: self.lStar)
            let pad = try self.material.encrypt(offsetStar)
            let partialStart = fullBlockCount * Self.blockSize
            let partial = Array(plaintext[partialStart...])

            for index in 0..<partialByteCount {
                ciphertext.append(partial[index] ^ pad.bytes[index])
            }

            checksum.xorInPlace(Block.padded(partial))
            tag = try self.material.encrypt(
                checksum
                    .xored(with: offsetStar)
                    .xored(with: self.lDollar)
            ).xored(with: hash)
        } else {
            tag = try self.material.encrypt(
                checksum
                    .xored(with: offset)
                    .xored(with: self.lDollar)
            ).xored(with: hash)
        }

        ciphertext.append(contentsOf: tag.bytes)
        return ciphertext
    }

    public func open(
        ciphertext: [UInt8],
        nonce: [UInt8],
        associatedData: [UInt8] = []
    ) throws -> [UInt8] {
        try Self.validateNonce(nonce)

        guard ciphertext.count >= Self.tagSize else {
            throw MoshAES128OCBError.ciphertextTooShort(ciphertext.count)
        }

        let tagStart = ciphertext.count - Self.tagSize
        let ciphertextCore = Array(ciphertext[..<tagStart])
        let receivedTag = Array(ciphertext[tagStart...])

        let hash = try self.hash(associatedData)
        let offset0 = try self.initialOffset(nonce: nonce)
        let fullBlockCount = ciphertextCore.count / Self.blockSize
        let partialByteCount = ciphertextCore.count % Self.blockSize

        var offset = offset0
        var checksum = Block.zero
        var plaintext: [UInt8] = []
        plaintext.reserveCapacity(ciphertextCore.count)

        for blockIndex in 1..<(fullBlockCount + 1) {
            offset.xorInPlace(self.lSubscript(blockIndex.trailingZeroBitCount))

            let range = ((blockIndex - 1) * Self.blockSize)..<(blockIndex * Self.blockSize)
            let ciphertextBlock = Block(Array(ciphertextCore[range]))
            let decrypted = try self.material.decrypt(ciphertextBlock.xored(with: offset))
            let plaintextBlock = decrypted.xored(with: offset)

            plaintext.append(contentsOf: plaintextBlock.bytes)
            checksum.xorInPlace(plaintextBlock)
        }

        let expectedTag: Block
        if partialByteCount > 0 {
            let offsetStar = offset.xored(with: self.lStar)
            let pad = try self.material.encrypt(offsetStar)
            let partialStart = fullBlockCount * Self.blockSize
            let partialCiphertext = Array(ciphertextCore[partialStart...])
            var partialPlaintext: [UInt8] = []
            partialPlaintext.reserveCapacity(partialByteCount)

            for index in 0..<partialByteCount {
                partialPlaintext.append(partialCiphertext[index] ^ pad.bytes[index])
            }

            plaintext.append(contentsOf: partialPlaintext)
            checksum.xorInPlace(Block.padded(partialPlaintext))
            expectedTag = try self.material.encrypt(
                checksum
                    .xored(with: offsetStar)
                    .xored(with: self.lDollar)
            ).xored(with: hash)
        } else {
            expectedTag = try self.material.encrypt(
                checksum
                    .xored(with: offset)
                    .xored(with: self.lDollar)
            ).xored(with: hash)
        }

        guard Self.constantTimeEquals(expectedTag.bytes, receivedTag) else {
            throw MoshAES128OCBError.authenticationFailed
        }

        return plaintext
    }

    private static func validateNonce(_ nonce: [UInt8]) throws {
        guard nonce.count >= 1 && nonce.count <= 15 else {
            throw MoshAES128OCBError.invalidNonceLength(nonce.count)
        }
    }

    private func hash(_ associatedData: [UInt8]) throws -> Block {
        let fullBlockCount = associatedData.count / Self.blockSize
        let partialByteCount = associatedData.count % Self.blockSize
        var offset = Block.zero
        var sum = Block.zero

        for blockIndex in 1..<(fullBlockCount + 1) {
            offset.xorInPlace(self.lSubscript(blockIndex.trailingZeroBitCount))

            let range = ((blockIndex - 1) * Self.blockSize)..<(blockIndex * Self.blockSize)
            let associatedBlock = Block(Array(associatedData[range]))
            let encrypted = try self.material.encrypt(associatedBlock.xored(with: offset))
            sum.xorInPlace(encrypted)
        }

        if partialByteCount > 0 {
            offset.xorInPlace(self.lStar)
            let partialStart = fullBlockCount * Self.blockSize
            let partial = Array(associatedData[partialStart...])
            let encrypted = try self.material.encrypt(Block.padded(partial).xored(with: offset))
            sum.xorInPlace(encrypted)
        }

        return sum
    }

    private func initialOffset(nonce: [UInt8]) throws -> Block {
        var formattedNonce = [UInt8](repeating: 0, count: Self.blockSize)
        formattedNonce[Self.blockSize - nonce.count - 1] = 0x01
        formattedNonce.replaceSubrange((Self.blockSize - nonce.count)..<Self.blockSize, with: nonce)

        let bottom = Int(formattedNonce[Self.blockSize - 1] & 0x3f)
        formattedNonce[Self.blockSize - 1] &= 0xc0

        let kTop = try self.material.encrypt(Block(formattedNonce))
        var stretch = kTop.bytes
        for index in 0..<8 {
            stretch.append(kTop.bytes[index] ^ kTop.bytes[index + 1])
        }

        let byteShift = bottom / 8
        let bitShift = bottom % 8
        var offset = [UInt8](repeating: 0, count: Self.blockSize)
        for index in 0..<Self.blockSize {
            if bitShift == 0 {
                offset[index] = stretch[index + byteShift]
            } else {
                offset[index] = (stretch[index + byteShift] << bitShift)
                    | (stretch[index + byteShift + 1] >> (8 - bitShift))
            }
        }

        return Block(offset)
    }

    private func lSubscript(_ index: Int) -> Block {
        guard index > 0 else {
            return self.lZero
        }

        var value = self.lZero
        for _ in 0..<index {
            value = value.doubled()
        }
        return value
    }

    private static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

/// Owns every long-lived piece of key-derived material for one OCB cipher and
/// guarantees it is zeroed when the cipher chain is deallocated.
///
/// Official Mosh destroys the AES key schedule and OCB offset table in
/// `Session::~Session` via `ae_clear` (`crypto.cc`; `ocb_internal.cc` zeroes
/// the whole `ae_ctx` with `memset`, `ocb_openssl.cc` uses `OPENSSL_cleanse`).
/// This class is the Swift counterpart: one fixed heap allocation holding the
/// raw AES-128 key and the derived L table, wiped with `memset_s` in `deinit`.
/// Because `MoshAES128OCB` (and the cipher/sequencer structs wrapping it) all
/// share this one reference, the wipe fires exactly when the last copy dies.
///
/// Buffer layout: `[0..<16]` raw key, `[16..<32]` L*, `[32..<48]` L$,
/// `[48..<64]` L0 (RFC 7253 section 2, key-dependent constants).
///
/// Honest limitations, matching official Mosh's own scope (`ae_clear` zeroes
/// the context; stack temporaries are not wiped there either):
/// - CommonCrypto expands and releases its own AES key schedule inside each
///   `CCCrypt` call; that internal copy is outside our control.
/// - Transient per-datagram `Block` values (offsets, checksums, pads, doubled
///   L values) live in short-lived Swift arrays and are not wiped.
///
/// Concurrency: the buffer is written only during `init` and `deinit` (both
/// exclusive by construction) and is read-only in between, so unsynchronized
/// concurrent reads are safe and `@unchecked Sendable` is sound. The optional
/// deinit observer is a test-only hook, mutated without synchronization;
/// install it before the cipher is shared across tasks.
private final class OCBKeyMaterial: @unchecked Sendable {
    private static let keyOffset = 0
    private static let lStarOffset = MoshAES128OCB.blockSize
    private static let lDollarOffset = 2 * MoshAES128OCB.blockSize
    private static let lZeroOffset = 3 * MoshAES128OCB.blockSize
    private static let byteCount = 4 * MoshAES128OCB.blockSize

    private let buffer: UnsafeMutableBufferPointer<UInt8>

    /// Test-only: called from `deinit` after the wipe, before deallocation,
    /// with whether the material reads as all-zero.
    var deinitWipeObserver: (@Sendable (Bool) -> Void)?

    init(key: UnsafeBufferPointer<UInt8>) throws {
        guard key.count == MoshSessionKey.byteCount else {
            throw MoshSessionKeyError.invalidRawByteCount(key.count)
        }

        let allocated = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Self.byteCount)
        allocated.initialize(repeating: 0)
        for index in 0..<key.count {
            allocated[Self.keyOffset + index] = key[index]
        }
        self.buffer = allocated

        // Derive the OCB L table (RFC 7253 section 2):
        //   L* = E_K(0^128), L$ = double(L*), L0 = double(L$).
        // If encryption throws, Swift still runs `deinit` for the fully
        // initialized instance, so the buffer is wiped and deallocated.
        let lStar = try self.encrypt(.zero)
        let lDollar = lStar.doubled()
        self.store(lStar, at: Self.lStarOffset)
        self.store(lDollar, at: Self.lDollarOffset)
        self.store(lDollar.doubled(), at: Self.lZeroOffset)
    }

    var lStar: Block { self.block(at: Self.lStarOffset) }
    var lDollar: Block { self.block(at: Self.lDollarOffset) }
    var lZero: Block { self.block(at: Self.lZeroOffset) }

    func encrypt(_ block: Block) throws -> Block {
        try self.crypt(block, operation: CCOperation(kCCEncrypt))
    }

    func decrypt(_ block: Block) throws -> Block {
        try self.crypt(block, operation: CCOperation(kCCDecrypt))
    }

    private func block(at offset: Int) -> Block {
        let slice = self.buffer[offset..<(offset + MoshAES128OCB.blockSize)]
        return Block(Array(UnsafeBufferPointer(rebasing: slice)))
    }

    private func store(_ block: Block, at offset: Int) {
        for index in 0..<MoshAES128OCB.blockSize {
            self.buffer[offset + index] = block.bytes[index]
        }
    }

    private func crypt(_ block: Block, operation: CCOperation) throws -> Block {
        var output = [UInt8](repeating: 0, count: MoshAES128OCB.blockSize)
        var bytesMoved = 0

        // `self.buffer` is owned by this instance and outlives the call, so
        // passing its base address to CCCrypt has no lifetime hazard.
        let keyPointer = self.buffer.baseAddress! + Self.keyOffset
        let status = block.bytes.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                CCCrypt(
                    operation,
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyPointer,
                    MoshSessionKey.byteCount,
                    nil,
                    inputBuffer.baseAddress,
                    MoshAES128OCB.blockSize,
                    outputBuffer.baseAddress,
                    MoshAES128OCB.blockSize,
                    &bytesMoved
                )
            }
        }

        guard status == kCCSuccess else {
            throw MoshAES128OCBError.commonCrypto(status: Int32(status))
        }

        return Block(output)
    }

    deinit {
        if let base = self.buffer.baseAddress, self.buffer.count > 0 {
            // memset_s is guaranteed not to be optimized away.
            memset_s(base, self.buffer.count, 0, self.buffer.count)
        }
        if let observer = self.deinitWipeObserver {
            observer(self.buffer.allSatisfy { $0 == 0 })
        }
        self.buffer.deallocate()
    }
}

private struct Block: Equatable, Sendable {
    static let zero = Block([UInt8](repeating: 0, count: MoshAES128OCB.blockSize))

    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        precondition(bytes.count == MoshAES128OCB.blockSize)
        self.bytes = bytes
    }

    static func padded(_ partial: [UInt8]) -> Block {
        precondition(partial.count < MoshAES128OCB.blockSize)

        var bytes = [UInt8](repeating: 0, count: MoshAES128OCB.blockSize)
        bytes.replaceSubrange(0..<partial.count, with: partial)
        bytes[partial.count] = 0x80
        return Block(bytes)
    }

    func xored(with other: Block) -> Block {
        var result = self
        result.xorInPlace(other)
        return result
    }

    mutating func xorInPlace(_ other: Block) {
        var output = self.bytes
        for index in output.indices {
            output[index] ^= other.bytes[index]
        }
        self = Block(output)
    }

    func doubled() -> Block {
        var output = [UInt8](repeating: 0, count: MoshAES128OCB.blockSize)
        var carry: UInt8 = 0

        for index in stride(from: MoshAES128OCB.blockSize - 1, through: 0, by: -1) {
            let byte = self.bytes[index]
            output[index] = (byte << 1) | carry
            carry = byte >> 7
        }

        output[MoshAES128OCB.blockSize - 1] ^= 0x87 & (0 &- carry)

        return Block(output)
    }
}
