// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshWire

struct MoshFragmentationTests {
    @Test
    func fragmenterSplitsCompressedInstructionWithinCapacity() throws {
        var fragmenter = MoshFragmenter()
        let instruction = sampleInstruction(diff: Array(repeating: 0xaa, count: 64))
        let maximumFragmentSize = MoshFragment.headerByteCount + 8

        let fragments = try fragmenter.makeFragments(
            for: instruction,
            maximumSerializedFragmentByteCount: maximumFragmentSize
        )

        #expect(fragments.count > 1)
        #expect(fragments.allSatisfy { $0.serializedBytes().count <= maximumFragmentSize })
        #expect(fragments.map(\.fragmentNumber) == Array(UInt16(0)..<UInt16(fragments.count)))
        #expect(fragments.dropLast().allSatisfy { $0.isFinal == false })
        #expect(fragments.last?.isFinal == true)
    }

    @Test
    func assemblyReconstructsOutOfOrderFragments() throws {
        var fragmenter = MoshFragmenter()
        var assembly = MoshFragmentAssembly()
        let instruction = sampleInstruction(diff: Array(repeating: 0xbb, count: 80))
        let fragments = try fragmenter.makeFragments(
            for: instruction,
            maximumSerializedFragmentByteCount: MoshFragment.headerByteCount + 7
        )

        var assembled: MoshTransportInstruction?
        for fragment in fragments.reversed() {
            assembled = try assembly.add(fragment)
        }

        #expect(assembled == instruction)
    }

    @Test
    func retransmissionReusesInstructionID() throws {
        var fragmenter = MoshFragmenter()
        let instruction = sampleInstruction(diff: Array("same".utf8))

        let first = try fragmenter.makeFragments(
            for: instruction,
            maximumSerializedFragmentByteCount: 256
        )
        let second = try fragmenter.makeFragments(
            for: instruction,
            maximumSerializedFragmentByteCount: 256
        )

        #expect(first.map(\.instructionID) == [1])
        #expect(second.map(\.instructionID) == [1])
    }

    @Test
    func instructionIDAdvancesWhenCapacityChanges() throws {
        var fragmenter = MoshFragmenter()
        let instruction = sampleInstruction(diff: Array("same".utf8))

        let first = try fragmenter.makeFragments(
            for: instruction,
            maximumSerializedFragmentByteCount: 256
        )
        let second = try fragmenter.makeFragments(
            for: instruction,
            maximumSerializedFragmentByteCount: 128
        )

        #expect(first.map(\.instructionID) == [1])
        #expect(second.map(\.instructionID) == [2])
    }

    @Test
    func instructionIDAdvancesWhenAcknowledgementChanges() throws {
        var fragmenter = MoshFragmenter()
        let firstInstruction = sampleInstruction(acknowledgementNumber: 1, diff: Array("same".utf8))
        let secondInstruction = sampleInstruction(acknowledgementNumber: 2, diff: Array("same".utf8))

        let first = try fragmenter.makeFragments(
            for: firstInstruction,
            maximumSerializedFragmentByteCount: 256
        )
        let second = try fragmenter.makeFragments(
            for: secondInstruction,
            maximumSerializedFragmentByteCount: 256
        )

        #expect(first.map(\.instructionID) == [1])
        #expect(second.map(\.instructionID) == [2])
    }

    @Test
    func rejectsRepeatedOldNewStateWithDifferentDiff() throws {
        var fragmenter = MoshFragmenter()
        let firstInstruction = sampleInstruction(diff: Array("one".utf8))
        let secondInstruction = sampleInstruction(diff: Array("two".utf8))

        _ = try fragmenter.makeFragments(
            for: firstInstruction,
            maximumSerializedFragmentByteCount: 256
        )

        #expect(throws: MoshFragmentationError.inconsistentDiffForRepeatedState) {
            _ = try fragmenter.makeFragments(
                for: secondInstruction,
                maximumSerializedFragmentByteCount: 256
            )
        }
    }

    @Test
    func failedFragmentationDoesNotConsumeInstructionID() throws {
        var fragmenter = MoshFragmenter()
        let firstInstruction = sampleInstruction(diff: Array("one".utf8))
        let invalidInstruction = sampleInstruction(diff: Array("two".utf8))

        _ = try fragmenter.makeFragments(
            for: firstInstruction,
            maximumSerializedFragmentByteCount: 256
        )
        #expect(throws: MoshFragmentationError.inconsistentDiffForRepeatedState) {
            _ = try fragmenter.makeFragments(
                for: invalidInstruction,
                maximumSerializedFragmentByteCount: 128
            )
        }

        let fragments = try fragmenter.makeFragments(
            for: firstInstruction,
            maximumSerializedFragmentByteCount: 128
        )

        #expect(fragments.map(\.instructionID) == [2])
    }

    @Test
    func rejectsFragmentCapacityThatCannotFitHeaderAndContents() {
        var fragmenter = MoshFragmenter()

        #expect(throws: MoshFragmentationError.fragmentCapacityTooSmall(MoshFragment.headerByteCount)) {
            _ = try fragmenter.makeFragments(
                for: sampleInstruction(diff: []),
                maximumSerializedFragmentByteCount: MoshFragment.headerByteCount
            )
        }
    }

    @Test
    func assemblyRejectsConflictingDuplicateFragment() throws {
        var assembly = MoshFragmentAssembly()
        let first = try MoshFragment(
            instructionID: 9,
            fragmentNumber: 0,
            isFinal: false,
            contents: [1]
        )
        let duplicate = try MoshFragment(
            instructionID: 9,
            fragmentNumber: 0,
            isFinal: false,
            contents: [2]
        )

        _ = try assembly.add(first)

        #expect(throws: MoshFragmentationError.conflictingDuplicateFragment(instructionID: 9, fragmentNumber: 0)) {
            _ = try assembly.add(duplicate)
        }
    }

    @Test
    func assemblyRejectsExistingFragmentBeyondFinal() throws {
        var assembly = MoshFragmentAssembly()
        let later = try MoshFragment(
            instructionID: 9,
            fragmentNumber: 2,
            isFinal: false,
            contents: [1]
        )
        let final = try MoshFragment(
            instructionID: 9,
            fragmentNumber: 1,
            isFinal: true,
            contents: [2]
        )

        _ = try assembly.add(later)

        #expect(
            throws: MoshFragmentationError.fragmentBeyondFinal(
                instructionID: 9,
                fragmentNumber: 2,
                finalFragmentNumber: 1
            )
        ) {
            _ = try assembly.add(final)
        }
    }
}

private func sampleInstruction(
    acknowledgementNumber: UInt64 = 1,
    diff: [UInt8]
) -> MoshTransportInstruction {
    MoshTransportInstruction(
        protocolVersion: 2,
        oldNumber: 1,
        newNumber: 2,
        acknowledgementNumber: acknowledgementNumber,
        throwawayNumber: 1,
        diff: diff,
        chaff: [0x00]
    )
}
