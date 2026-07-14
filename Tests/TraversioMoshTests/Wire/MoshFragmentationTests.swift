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

    // Without a cumulative check, a fragment number bounded to 15 bits bounds
    // fragment COUNT but not retained bytes: an authenticated peer that never
    // sends a final fragment can otherwise force unbounded retention.
    @Test
    func assemblyRejectsCumulativeContentByteCountBeyondBudget() throws {
        var assembly = MoshFragmentAssembly()
        let halfBudget = MoshFragmentAssembly.maximumCumulativeCompressedByteCount / 2
        let first = try MoshFragment(
            instructionID: 9,
            fragmentNumber: 0,
            isFinal: false,
            contents: Array(repeating: 0xaa, count: halfBudget + 1)
        )
        let second = try MoshFragment(
            instructionID: 9,
            fragmentNumber: 1,
            isFinal: false,
            contents: Array(repeating: 0xbb, count: halfBudget + 1)
        )

        _ = try assembly.add(first)

        #expect(
            throws: MoshFragmentationError.cumulativeContentByteCountExceeded(
                instructionID: 9,
                byteCount: 2 * (halfBudget + 1)
            )
        ) {
            _ = try assembly.add(second)
        }
    }

    // The budget must not falsely reject a legitimate peer: a single fragment
    // exactly at the ceiling (matching an instruction that decompresses to at
    // most the compressor's own maximum) is accepted.
    @Test
    func assemblyAcceptsCumulativeContentByteCountAtExactBudget() throws {
        var assembly = MoshFragmentAssembly()
        let content = Array(
            repeating: UInt8(0xcc),
            count: MoshFragmentAssembly.maximumCumulativeCompressedByteCount
        )
        let fragment = try MoshFragment(
            instructionID: 9,
            fragmentNumber: 0,
            isFinal: false,
            contents: content
        )

        _ = try assembly.add(fragment)
    }

    // A fresh instruction ID must start a fresh budget rather than inheriting
    // the previous (possibly abandoned) instruction's cumulative byte count.
    @Test
    func assemblyResetsCumulativeContentByteCountOnNewInstructionID() throws {
        var assembly = MoshFragmentAssembly()
        let large = try MoshFragment(
            instructionID: 9,
            fragmentNumber: 0,
            isFinal: false,
            contents: Array(
                repeating: 0xaa,
                count: MoshFragmentAssembly.maximumCumulativeCompressedByteCount
            )
        )
        _ = try assembly.add(large)

        let next = try MoshFragment(
            instructionID: 10,
            fragmentNumber: 0,
            isFinal: false,
            contents: [0x01]
        )
        _ = try assembly.add(next)
    }

    // A successful completion resets `fragments`/`finalFragmentNumber` but,
    // before this fix, left the cumulative byte budget unreset. An ordinary
    // SSP retransmission of the SAME instruction ID (its ACK was lost, so the
    // sender resends unchanged — `MoshFragmenter` reuses `nextInstructionID`
    // for an unchanged identity, see `retransmissionReusesInstructionID`
    // above) is not requiring any adversarial peer, yet would add its bytes on
    // top of the already-completed total and eventually exceed the budget on
    // nothing but ordinary retransmission.
    @Test
    func assemblyResetsCumulativeContentByteCountAfterSuccessfulCompletion() throws {
        let compressor = MoshCompressor()
        var assembly = MoshFragmentAssembly(compressor: compressor)
        let instruction = sampleInstruction(diff: Array(repeating: 0xaa, count: 64))
        let compressedPayload = try compressor.compress(instruction.serializedBytes())
        let completingFragment = try MoshFragment(
            instructionID: 9,
            fragmentNumber: 0,
            isFinal: true,
            contents: compressedPayload
        )

        // First delivery completes successfully.
        let firstResult = try assembly.add(completingFragment)
        #expect(firstResult == instruction)

        // A retransmission of the SAME (unchanged) instruction ID must not be
        // charged against a stale leftover total from the completed delivery
        // above. Sized so a buggy (unreset) cumulative total would land
        // exactly one byte past the budget, while a correctly-reset total
        // stays one byte under it.
        let nearBudgetContent = Array(
            repeating: UInt8(0xee),
            count: MoshFragmentAssembly.maximumCumulativeCompressedByteCount - compressedPayload.count + 1
        )
        let retransmittedFragment = try MoshFragment(
            instructionID: 9,
            fragmentNumber: 5,
            isFinal: false,
            contents: nearBudgetContent
        )
        _ = try assembly.add(retransmittedFragment)
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
