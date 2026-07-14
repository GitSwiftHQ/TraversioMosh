// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public enum MoshFragmentationError: Error, Equatable, Sendable {
    case fragmentCapacityTooSmall(Int)
    case instructionIDOverflow
    case inconsistentDiffForRepeatedState
    case fragmentCountOutOfRange(Int)
    case conflictingDuplicateFragment(instructionID: UInt64, fragmentNumber: UInt16)
    case fragmentBeyondFinal(instructionID: UInt64, fragmentNumber: UInt16, finalFragmentNumber: UInt16)
    case cumulativeContentByteCountExceeded(instructionID: UInt64, byteCount: Int)
}

public struct MoshFragmenter: Sendable {
    private let compressor: MoshCompressor
    private var nextInstructionID: UInt64
    private var lastIdentity: FragmentedInstructionIdentity?
    private var lastDiff: [UInt8]?
    private var lastContentCapacity: Int?

    public init(compressor: MoshCompressor = MoshCompressor()) {
        self.compressor = compressor
        self.nextInstructionID = 0
        self.lastIdentity = nil
        self.lastDiff = nil
        self.lastContentCapacity = nil
    }

    public mutating func makeFragments(
        for instruction: MoshTransportInstruction,
        maximumSerializedFragmentByteCount: Int
    ) throws -> [MoshFragment] {
        guard maximumSerializedFragmentByteCount > MoshFragment.headerByteCount else {
            throw MoshFragmentationError.fragmentCapacityTooSmall(maximumSerializedFragmentByteCount)
        }

        let identity = FragmentedInstructionIdentity(instruction)
        let contentCapacity = maximumSerializedFragmentByteCount - MoshFragment.headerByteCount

        if let lastIdentity,
           identity.oldNumber == lastIdentity.oldNumber,
           identity.newNumber == lastIdentity.newNumber,
           instruction.diff != self.lastDiff {
            throw MoshFragmentationError.inconsistentDiffForRepeatedState
        }

        let instructionID: UInt64
        if identity != self.lastIdentity || contentCapacity != self.lastContentCapacity {
            guard self.nextInstructionID < UInt64.max else {
                throw MoshFragmentationError.instructionIDOverflow
            }
            instructionID = self.nextInstructionID + 1
        } else {
            instructionID = self.nextInstructionID
        }

        let compressedPayload = try self.compressor.compress(instruction.serializedBytes())
        let fragmentCount = (compressedPayload.count + contentCapacity - 1) / contentCapacity
        guard fragmentCount <= Int(MoshFragment.maxFragmentNumber) + 1 else {
            throw MoshFragmentationError.fragmentCountOutOfRange(fragmentCount)
        }

        var fragments: [MoshFragment] = []
        fragments.reserveCapacity(fragmentCount)
        for index in 0..<fragmentCount {
            let start = index * contentCapacity
            let end = min(start + contentCapacity, compressedPayload.count)
            fragments.append(try MoshFragment(
                instructionID: instructionID,
                fragmentNumber: UInt16(index),
                isFinal: index == fragmentCount - 1,
                contents: Array(compressedPayload[start..<end])
            ))
        }

        self.nextInstructionID = instructionID
        self.lastIdentity = identity
        self.lastDiff = instruction.diff
        self.lastContentCapacity = contentCapacity

        return fragments
    }
}

public struct MoshFragmentAssembly: Sendable {
    /// Upper bound on the cumulative COMPRESSED byte count `add(_:)` retains for
    /// a single in-flight instruction, checked before every new fragment is
    /// stored — not only after the final fragment arrives and the fragments are
    /// concatenated for decompression. Without this, a fragment number bounded
    /// to 15 bits (`MoshFragment.maxFragmentNumber`) bounds fragment COUNT but
    /// not cumulative bytes, so an authenticated peer that withholds the final
    /// fragment can force retention of up to 32,768 near-UDP-sized fragments
    /// (~2 GiB) before the existing decompressed-output ceiling ever runs.
    ///
    /// zlib's compressed output can exceed its input size by a small, bounded
    /// margin for incompressible data — the same worst case `compressBound`
    /// accounts for: `sourceLength + (sourceLength >> 12) + (sourceLength >> 14)
    /// + (sourceLength >> 25) + 13`. Using that margin above
    /// `MoshCompressor.defaultMaximumOutputByteCount`, rather than the bare
    /// decompressed ceiling, means a legitimate peer whose instruction
    /// decompresses to at most that ceiling can never be rejected here no
    /// matter how incompressible its content is; only a peer that keeps
    /// exceeding it while withholding the final fragment is charged with
    /// resource exhaustion.
    public static let maximumCumulativeCompressedByteCount: Int = {
        let sourceLength = MoshCompressor.defaultMaximumOutputByteCount
        return sourceLength + (sourceLength >> 12) + (sourceLength >> 14) + (sourceLength >> 25) + 13
    }()

    private let compressor: MoshCompressor
    private var currentInstructionID: UInt64?
    private var finalFragmentNumber: UInt16?
    private var fragments: [UInt16: MoshFragment]
    private var cumulativeContentByteCount: Int

    public init(compressor: MoshCompressor = MoshCompressor()) {
        self.compressor = compressor
        self.currentInstructionID = nil
        self.finalFragmentNumber = nil
        self.fragments = [:]
        self.cumulativeContentByteCount = 0
    }

    public mutating func add(_ fragment: MoshFragment) throws -> MoshTransportInstruction? {
        if self.currentInstructionID != fragment.instructionID {
            self.currentInstructionID = fragment.instructionID
            self.finalFragmentNumber = nil
            self.fragments.removeAll(keepingCapacity: true)
            self.cumulativeContentByteCount = 0
        }

        if let finalFragmentNumber, fragment.fragmentNumber > finalFragmentNumber {
            throw MoshFragmentationError.fragmentBeyondFinal(
                instructionID: fragment.instructionID,
                fragmentNumber: fragment.fragmentNumber,
                finalFragmentNumber: finalFragmentNumber
            )
        }

        if let existing = self.fragments[fragment.fragmentNumber] {
            guard existing == fragment else {
                throw MoshFragmentationError.conflictingDuplicateFragment(
                    instructionID: fragment.instructionID,
                    fragmentNumber: fragment.fragmentNumber
                )
            }
            return try self.completeInstructionIfReady()
        }

        let projectedByteCount = self.cumulativeContentByteCount + fragment.contents.count
        guard projectedByteCount <= Self.maximumCumulativeCompressedByteCount else {
            throw MoshFragmentationError.cumulativeContentByteCountExceeded(
                instructionID: fragment.instructionID,
                byteCount: projectedByteCount
            )
        }

        if fragment.isFinal {
            if let highestFragmentNumber = self.fragments.keys.max(),
               highestFragmentNumber > fragment.fragmentNumber {
                throw MoshFragmentationError.fragmentBeyondFinal(
                    instructionID: fragment.instructionID,
                    fragmentNumber: highestFragmentNumber,
                    finalFragmentNumber: fragment.fragmentNumber
                )
            }
            self.finalFragmentNumber = fragment.fragmentNumber
        }

        self.fragments[fragment.fragmentNumber] = fragment
        self.cumulativeContentByteCount = projectedByteCount
        return try self.completeInstructionIfReady()
    }

    private mutating func completeInstructionIfReady() throws -> MoshTransportInstruction? {
        guard let finalFragmentNumber else {
            return nil
        }

        let expectedFragmentCount = Int(finalFragmentNumber) + 1
        guard self.fragments.count == expectedFragmentCount else {
            return nil
        }

        var compressedPayload: [UInt8] = []
        for number in UInt16(0)...finalFragmentNumber {
            guard let fragment = self.fragments[number] else {
                return nil
            }
            compressedPayload.append(contentsOf: fragment.contents)
        }

        let serializedInstruction = try self.compressor.decompress(compressedPayload)
        let instruction = try MoshTransportInstruction(serializedBytes: serializedInstruction)

        self.finalFragmentNumber = nil
        self.fragments.removeAll(keepingCapacity: true)

        return instruction
    }
}

private struct FragmentedInstructionIdentity: Equatable, Sendable {
    let protocolVersion: UInt32?
    let oldNumber: UInt64?
    let newNumber: UInt64?
    let acknowledgementNumber: UInt64?
    let throwawayNumber: UInt64?
    let chaff: [UInt8]?

    init(_ instruction: MoshTransportInstruction) {
        self.protocolVersion = instruction.protocolVersion
        self.oldNumber = instruction.oldNumber
        self.newNumber = instruction.newNumber
        self.acknowledgementNumber = instruction.acknowledgementNumber
        self.throwawayNumber = instruction.throwawayNumber
        self.chaff = instruction.chaff
    }
}
