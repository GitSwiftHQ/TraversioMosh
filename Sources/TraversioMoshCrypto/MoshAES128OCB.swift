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

    private let blockCipher: AES128BlockCipher
    private let lStar: Block
    private let lDollar: Block
    private let lZero: Block

    public init(sessionKey: MoshSessionKey) throws {
        try self.init(rawKey: sessionKey.rawBytes)
    }

    public init(rawKey: some Collection<UInt8>) throws {
        self.blockCipher = try AES128BlockCipher(key: Array(rawKey))
        self.lStar = try self.blockCipher.encrypt(.zero)
        self.lDollar = self.lStar.doubled()
        self.lZero = self.lDollar.doubled()
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
            let encrypted = try self.blockCipher.encrypt(plaintextBlock.xored(with: offset))
            let ciphertextBlock = encrypted.xored(with: offset)

            ciphertext.append(contentsOf: ciphertextBlock.bytes)
            checksum.xorInPlace(plaintextBlock)
        }

        let tag: Block
        if partialByteCount > 0 {
            let offsetStar = offset.xored(with: self.lStar)
            let pad = try self.blockCipher.encrypt(offsetStar)
            let partialStart = fullBlockCount * Self.blockSize
            let partial = Array(plaintext[partialStart...])

            for index in 0..<partialByteCount {
                ciphertext.append(partial[index] ^ pad.bytes[index])
            }

            checksum.xorInPlace(Block.padded(partial))
            tag = try self.blockCipher.encrypt(
                checksum
                    .xored(with: offsetStar)
                    .xored(with: self.lDollar)
            ).xored(with: hash)
        } else {
            tag = try self.blockCipher.encrypt(
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
            let decrypted = try self.blockCipher.decrypt(ciphertextBlock.xored(with: offset))
            let plaintextBlock = decrypted.xored(with: offset)

            plaintext.append(contentsOf: plaintextBlock.bytes)
            checksum.xorInPlace(plaintextBlock)
        }

        let expectedTag: Block
        if partialByteCount > 0 {
            let offsetStar = offset.xored(with: self.lStar)
            let pad = try self.blockCipher.encrypt(offsetStar)
            let partialStart = fullBlockCount * Self.blockSize
            let partialCiphertext = Array(ciphertextCore[partialStart...])
            var partialPlaintext: [UInt8] = []
            partialPlaintext.reserveCapacity(partialByteCount)

            for index in 0..<partialByteCount {
                partialPlaintext.append(partialCiphertext[index] ^ pad.bytes[index])
            }

            plaintext.append(contentsOf: partialPlaintext)
            checksum.xorInPlace(Block.padded(partialPlaintext))
            expectedTag = try self.blockCipher.encrypt(
                checksum
                    .xored(with: offsetStar)
                    .xored(with: self.lDollar)
            ).xored(with: hash)
        } else {
            expectedTag = try self.blockCipher.encrypt(
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
            let encrypted = try self.blockCipher.encrypt(associatedBlock.xored(with: offset))
            sum.xorInPlace(encrypted)
        }

        if partialByteCount > 0 {
            offset.xorInPlace(self.lStar)
            let partialStart = fullBlockCount * Self.blockSize
            let partial = Array(associatedData[partialStart...])
            let encrypted = try self.blockCipher.encrypt(Block.padded(partial).xored(with: offset))
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

        let kTop = try self.blockCipher.encrypt(Block(formattedNonce))
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

private struct AES128BlockCipher: Sendable {
    private let key: [UInt8]

    init(key: [UInt8]) throws {
        guard key.count == MoshSessionKey.byteCount else {
            throw MoshSessionKeyError.invalidRawByteCount(key.count)
        }
        self.key = key
    }

    func encrypt(_ block: Block) throws -> Block {
        try self.crypt(block, operation: CCOperation(kCCEncrypt))
    }

    func decrypt(_ block: Block) throws -> Block {
        try self.crypt(block, operation: CCOperation(kCCDecrypt))
    }

    private func crypt(_ block: Block, operation: CCOperation) throws -> Block {
        var output = [UInt8](repeating: 0, count: MoshAES128OCB.blockSize)
        var bytesMoved = 0

        let status = self.key.withUnsafeBytes { keyBuffer in
            block.bytes.withUnsafeBytes { inputBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBuffer.baseAddress,
                        self.key.count,
                        nil,
                        inputBuffer.baseAddress,
                        MoshAES128OCB.blockSize,
                        outputBuffer.baseAddress,
                        MoshAES128OCB.blockSize,
                        &bytesMoved
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw MoshAES128OCBError.commonCrypto(status: Int32(status))
        }

        return Block(output)
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
