// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCore
import TraversioMoshWire

struct MoshSSPReceiverTests {
    @Test
    func acceptsInstructionFromKnownReference() throws {
        var receiver = MoshSSPReceiver(initialState: ByteState())

        let result = try receiver.receive(instruction(old: 0, new: 1, diff: [1, 2]))

        #expect(result == .accepted(newNumber: 1))
        #expect(receiver.acknowledgementNumber == 1)
        #expect(receiver.latestState == MoshNumberedState(number: 1, state: ByteState([1, 2])))
        #expect(receiver.stateNumbers == [0, 1])
    }

    @Test
    func ignoresDuplicateStateNumber() throws {
        var receiver = MoshSSPReceiver(initialState: ByteState())
        let first = instruction(old: 0, new: 1, diff: [1])
        let duplicate = instruction(old: 0, new: 1, diff: [2])

        _ = try receiver.receive(first)
        let result = try receiver.receive(duplicate)

        #expect(result == .duplicate(newNumber: 1))
        #expect(receiver.latestState == MoshNumberedState(number: 1, state: ByteState([1])))
        #expect(receiver.stateNumbers == [0, 1])
    }

    @Test
    func ignoresInstructionWithMissingReferenceState() throws {
        var receiver = MoshSSPReceiver(initialState: ByteState())

        let result = try receiver.receive(instruction(old: 9, new: 10, diff: [1]))

        #expect(result == .missingReference(oldNumber: 9))
        #expect(receiver.acknowledgementNumber == 0)
        #expect(receiver.latestState == MoshNumberedState(number: 0, state: ByteState()))
        #expect(receiver.stateNumbers == [0])
    }

    @Test
    func acceptsOutOfOrderStateWithoutLoweringAcknowledgement() throws {
        var receiver = MoshSSPReceiver(initialState: ByteState())

        _ = try receiver.receive(instruction(old: 0, new: 2, diff: [2]))
        let result = try receiver.receive(instruction(old: 0, new: 1, diff: [1]))

        #expect(result == .accepted(newNumber: 1))
        #expect(receiver.acknowledgementNumber == 2)
        #expect(receiver.latestState == MoshNumberedState(number: 2, state: ByteState([2])))
        #expect(receiver.stateNumbers == [0, 1, 2])
    }

    @Test
    func throwawayPrunesStatesBelowAdvertisedNumber() throws {
        var receiver = MoshSSPReceiver(initialState: ByteState())

        _ = try receiver.receive(instruction(old: 0, new: 1, throwaway: 0, diff: [1]))
        _ = try receiver.receive(instruction(old: 1, new: 2, throwaway: 1, diff: [2]))

        #expect(receiver.acknowledgementNumber == 2)
        #expect(receiver.latestState == MoshNumberedState(number: 2, state: ByteState([1, 2])))
        #expect(receiver.stateNumbers == [1, 2])
    }

    @Test
    func rejectsThrowawayAfterReferenceState() throws {
        var receiver = MoshSSPReceiver(initialState: ByteState())

        #expect(throws: MoshSSPError.throwawayAfterReference(throwawayNumber: 1, oldNumber: 0)) {
            _ = try receiver.receive(instruction(old: 0, new: 1, throwaway: 1, diff: [1]))
        }
        #expect(receiver.stateNumbers == [0])
    }

    @Test
    func rejectsProtocolVersionMismatch() throws {
        var receiver = MoshSSPReceiver(initialState: ByteState())

        #expect(throws: MoshSSPError.protocolVersionMismatch(1)) {
            _ = try receiver.receive(instruction(protocolVersion: 1, old: 0, new: 1, diff: [1]))
        }
        #expect(receiver.stateNumbers == [0])
    }
}

private struct ByteState: MoshSynchronizedState {
    var bytes: [UInt8]

    init(_ bytes: [UInt8] = []) {
        self.bytes = bytes
    }

    func moshDiff(from base: ByteState) throws -> [UInt8] {
        Array(self.bytes.dropFirst(base.bytes.count))
    }

    mutating func applyMoshDiff(_ diff: [UInt8]) throws {
        self.bytes.append(contentsOf: diff)
    }

    mutating func subtractMoshState(_ base: ByteState) throws {
        if self.bytes.starts(with: base.bytes) {
            self.bytes.removeFirst(base.bytes.count)
        }
    }
}

private func instruction(
    protocolVersion: UInt32 = 2,
    old: UInt64,
    new: UInt64,
    throwaway: UInt64 = 0,
    diff: [UInt8]
) -> MoshTransportInstruction {
    MoshTransportInstruction(
        protocolVersion: protocolVersion,
        oldNumber: old,
        newNumber: new,
        acknowledgementNumber: 0,
        throwawayNumber: throwaway,
        diff: diff,
        chaff: []
    )
}
