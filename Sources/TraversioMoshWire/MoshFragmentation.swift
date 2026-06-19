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
    private let compressor: MoshCompressor
    private var currentInstructionID: UInt64?
    private var finalFragmentNumber: UInt16?
    private var fragments: [UInt16: MoshFragment]

    public init(compressor: MoshCompressor = MoshCompressor()) {
        self.compressor = compressor
        self.currentInstructionID = nil
        self.finalFragmentNumber = nil
        self.fragments = [:]
    }

    public mutating func add(_ fragment: MoshFragment) throws -> MoshTransportInstruction? {
        if self.currentInstructionID != fragment.instructionID {
            self.currentInstructionID = fragment.instructionID
            self.finalFragmentNumber = nil
            self.fragments.removeAll(keepingCapacity: true)
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
