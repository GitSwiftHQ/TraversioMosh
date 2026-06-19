// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCore
import TraversioMoshWire

struct MoshSSPSenderTests {
    @Test
    func newStateProducesTransportInstructionFromKnownState() throws {
        var sender = MoshSSPSender(
            initialState: ByteState(),
            chaffSource: .testing([0xca])
        )
        sender.setCurrentState(ByteState([1, 2]))
        sender.setAcknowledgementNumber(7)

        let instruction = try #require(try sender.makeDataInstruction(
            nowMilliseconds: 10,
            timeoutMilliseconds: 1000
        ))

        #expect(instruction.protocolVersion == 2)
        #expect(instruction.oldNumber == 0)
        #expect(instruction.newNumber == 1)
        #expect(instruction.acknowledgementNumber == 7)
        #expect(instruction.throwawayNumber == 0)
        #expect(instruction.diff == [1, 2])
        #expect(instruction.chaff == [0xca])
        #expect(sender.sentStateNumbers == [0, 1])
        #expect(sender.assumedReceiverStateNumber == 1)
    }

    @Test
    func initialUnchangedStateProducesNoDataInstruction() throws {
        var sender = MoshSSPSender(initialState: ByteState(), chaffSource: .none)

        let instruction = try sender.makeDataInstruction(nowMilliseconds: 20, timeoutMilliseconds: 1000)

        #expect(instruction == nil)
        #expect(sender.sentStateNumbers == [0])
    }

    @Test
    func expiredAssumptionRetransmitsLastStateNumberFromKnownState() throws {
        var sender = MoshSSPSender(initialState: ByteState(), chaffSource: .none)
        sender.setCurrentState(ByteState([1, 2]))

        _ = try sender.makeDataInstruction(nowMilliseconds: 10, timeoutMilliseconds: 50)
        let retransmission = try #require(try sender.makeDataInstruction(
            nowMilliseconds: 200,
            timeoutMilliseconds: 50
        ))

        #expect(retransmission.oldNumber == 0)
        #expect(retransmission.newNumber == 1)
        #expect(retransmission.diff == [1, 2])
        #expect(sender.sentStateNumbers == [0, 1])
    }

    @Test
    func acknowledgementPrunesOlderSentStatesAndUpdatesThrowaway() throws {
        var sender = MoshSSPSender(initialState: ByteState(), chaffSource: .none)
        sender.setCurrentState(ByteState([1]))
        _ = try sender.makeDataInstruction(nowMilliseconds: 10, timeoutMilliseconds: 1000)

        sender.processAcknowledgement(through: 1)
        sender.setCurrentState(ByteState([1, 2]))
        let instruction = try #require(try sender.makeDataInstruction(
            nowMilliseconds: 20,
            timeoutMilliseconds: 1000
        ))

        #expect(sender.knownAcknowledgedStateNumber == 1)
        #expect(sender.sentStateNumbers == [1, 2])
        #expect(instruction.oldNumber == 1)
        #expect(instruction.newNumber == 2)
        #expect(instruction.throwawayNumber == 1)
        #expect(instruction.diff == [2])
    }

    @Test
    func unknownAcknowledgementDoesNotPruneSentStates() throws {
        var sender = MoshSSPSender(initialState: ByteState(), chaffSource: .none)
        sender.setCurrentState(ByteState([1]))
        _ = try sender.makeDataInstruction(nowMilliseconds: 10, timeoutMilliseconds: 1000)

        sender.processAcknowledgement(through: 9)

        #expect(sender.sentStateNumbers == [0, 1])
        #expect(sender.knownAcknowledgedStateNumber == 0)
    }

    @Test
    func queuePrunesMiddleStatesWhilePreservingFirstAndLast() throws {
        var sender = MoshSSPSender(initialState: ByteState(), chaffSource: .none)

        for value in UInt8(1)...UInt8(35) {
            sender.setCurrentState(ByteState(Array(1...value)))
            _ = try sender.makeDataInstruction(
                nowMilliseconds: UInt64(value),
                timeoutMilliseconds: 1000
            )
        }

        #expect(sender.sentStateNumbers.count == MoshSSPSender<ByteState>.maximumSentStateCount)
        #expect(sender.sentStateNumbers.first == 0)
        #expect(sender.sentStateNumbers.last == 35)
        #expect(sender.sentStateNumbers.contains(17) == false)
        #expect(sender.sentStateNumbers.contains(18) == false)
        #expect(sender.sentStateNumbers.contains(19) == false)
        #expect(sender.sentStateNumbers.contains(20) == false)
    }

    @Test
    func prospectiveResendUsesKnownStateWhenItIsNearlyAsSmall() throws {
        var sender = MoshSSPSender(initialState: ByteState(), chaffSource: .none)
        sender.setCurrentState(ByteState([1, 2, 3]))
        _ = try sender.makeDataInstruction(nowMilliseconds: 10, timeoutMilliseconds: 1000)
        sender.setCurrentState(ByteState([1, 2, 3, 4]))

        let instruction = try #require(try sender.makeDataInstruction(
            nowMilliseconds: 20,
            timeoutMilliseconds: 1000
        ))

        #expect(instruction.oldNumber == 0)
        #expect(instruction.newNumber == 2)
        #expect(instruction.diff == [1, 2, 3, 4])
    }

    @Test
    func rejectsClockMovingBackwardAcrossSentState() throws {
        var sender = MoshSSPSender(initialState: ByteState(), chaffSource: .none)
        sender.setCurrentState(ByteState([1]))

        _ = try sender.makeDataInstruction(nowMilliseconds: 10, timeoutMilliseconds: 1000)

        #expect(throws: MoshSSPError.clockMovedBackward(nowMilliseconds: 9, sentAtMilliseconds: 10)) {
            _ = try sender.makeDataInstruction(nowMilliseconds: 9, timeoutMilliseconds: 1000)
        }
    }

    @Test
    func rejectsClockMovingBackwardEvenWhenEarlierStateExpired() throws {
        var sender = MoshSSPSender(initialState: ByteState(), chaffSource: .none)
        sender.setCurrentState(ByteState([1]))
        _ = try sender.makeDataInstruction(nowMilliseconds: 10, timeoutMilliseconds: 1000)
        sender.setCurrentState(ByteState([1, 2]))
        _ = try sender.makeDataInstruction(nowMilliseconds: 200, timeoutMilliseconds: 1000)

        #expect(throws: MoshSSPError.clockMovedBackward(nowMilliseconds: 150, sentAtMilliseconds: 200)) {
            _ = try sender.makeDataInstruction(nowMilliseconds: 150, timeoutMilliseconds: 0)
        }
    }
}

private extension MoshSSPChaffSource {
    static func testing(_ bytes: [UInt8]) -> MoshSSPChaffSource {
        MoshSSPChaffSource {
            bytes
        }
    }
}

private struct ByteState: MoshSynchronizedState {
    var bytes: [UInt8]

    init(_ bytes: [UInt8] = []) {
        self.bytes = bytes
    }

    func moshDiff(from base: ByteState) throws -> [UInt8] {
        guard self.bytes.starts(with: base.bytes) else {
            return self.bytes
        }
        return Array(self.bytes.dropFirst(base.bytes.count))
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
