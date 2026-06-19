// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCore
import TraversioMoshWire

struct MoshSSPSendSchedulerTests {
    @Test
    func localChangeWaitsForMinimumDelayAndSendInterval() throws {
        var scheduler = MoshSSPSendScheduler(
            initialState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )

        scheduler.setCurrentState(ByteState([1]), nowMilliseconds: 0)

        #expect(try scheduler.waitTime(nowMilliseconds: 0) == 20)
        #expect(try scheduler.tick(nowMilliseconds: 19) == nil)

        let instruction = try requireData(try scheduler.tick(nowMilliseconds: 20))

        #expect(instruction.oldNumber == 0)
        #expect(instruction.newNumber == 1)
        #expect(instruction.diff == [1])
    }

    @Test
    func delayedAcknowledgementSendsEmptyInstruction() throws {
        var scheduler = MoshSSPSendScheduler(
            initialState: ByteState(),
            chaffSource: .none
        )

        scheduler.noteReceivedState(number: 7, nowMilliseconds: 10)

        #expect(try scheduler.waitTime(nowMilliseconds: 10) == 100)
        #expect(try scheduler.tick(nowMilliseconds: 109) == nil)

        let instruction = try requireAcknowledgement(try scheduler.tick(nowMilliseconds: 110))

        #expect(instruction.oldNumber == 0)
        #expect(instruction.newNumber == 1)
        #expect(instruction.acknowledgementNumber == 7)
        #expect(instruction.throwawayNumber == 0)
        #expect(instruction.diff == [])
        #expect(scheduler.sender.lastSentStateNumber == 1)
    }

    @Test
    func idleAcknowledgementIntervalSendsHeartbeatInstruction() throws {
        var scheduler = MoshSSPSendScheduler(
            initialState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(acknowledgementIntervalMilliseconds: 3_000),
            chaffSource: .none
        )

        #expect(try scheduler.waitTime(nowMilliseconds: 0) == 3_000)
        #expect(try scheduler.tick(nowMilliseconds: 2_999) == nil)

        let instruction = try requireAcknowledgement(try scheduler.tick(nowMilliseconds: 3_000))

        #expect(instruction.oldNumber == 0)
        #expect(instruction.newNumber == 1)
        #expect(instruction.acknowledgementNumber == 0)
        #expect(instruction.diff == [])
    }

    @Test
    func dueAcknowledgementFlushesPendingDataBeforeSendInterval() throws {
        var scheduler = MoshSSPSendScheduler(
            initialState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 500),
            chaffSource: .none
        )

        scheduler.setCurrentState(ByteState([1]), nowMilliseconds: 0)
        scheduler.noteReceivedState(number: 9, nowMilliseconds: 50)

        #expect(try scheduler.tick(nowMilliseconds: 149) == nil)

        let instruction = try requireData(try scheduler.tick(nowMilliseconds: 150))

        #expect(instruction.oldNumber == 0)
        #expect(instruction.newNumber == 1)
        #expect(instruction.acknowledgementNumber == 9)
        #expect(instruction.diff == [1])
    }

    @Test
    func activeRetryRetransmitsAfterAssumptionExpires() throws {
        var scheduler = MoshSSPSendScheduler(
            initialState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(
                sendIntervalMilliseconds: 20,
                timeoutMilliseconds: 50
            ),
            chaffSource: .none
        )

        scheduler.setCurrentState(ByteState([1]), nowMilliseconds: 0)
        _ = try scheduler.tick(nowMilliseconds: 20)
        scheduler.noteRemoteHeard(nowMilliseconds: 21)

        #expect(try scheduler.waitTime(nowMilliseconds: 169) == 1)
        #expect(try scheduler.tick(nowMilliseconds: 169) == nil)

        let retransmission = try requireData(try scheduler.tick(nowMilliseconds: 170))

        #expect(retransmission.oldNumber == 0)
        #expect(retransmission.newNumber == 1)
        #expect(retransmission.diff == [1])
    }

    @Test
    func activeRetryStopsAfterRemoteSilenceWindow() throws {
        var scheduler = MoshSSPSendScheduler(
            initialState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(
                sendIntervalMilliseconds: 20,
                activeRetryTimeoutMilliseconds: 100,
                timeoutMilliseconds: 50
            ),
            chaffSource: .none
        )

        scheduler.setCurrentState(ByteState([1]), nowMilliseconds: 0)
        _ = try scheduler.tick(nowMilliseconds: 20)
        scheduler.noteRemoteHeard(nowMilliseconds: 21)

        #expect(try scheduler.tick(nowMilliseconds: 200) == nil)
    }

    @Test
    func shutdownSendsMaximumStateNumberAtSendInterval() throws {
        var scheduler = MoshSSPSendScheduler(
            initialState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )

        scheduler.startShutdown(nowMilliseconds: 0)

        #expect(scheduler.shutdownInProgress)
        #expect(try scheduler.waitTime(nowMilliseconds: 0) == 20)
        #expect(try scheduler.tick(nowMilliseconds: 19) == nil)

        let instruction = try requireAcknowledgement(try scheduler.tick(nowMilliseconds: 20))

        #expect(instruction.newNumber == UInt64.max)
        #expect(instruction.diff == [])
        #expect(scheduler.shutdownAttemptCount == 1)
        #expect(scheduler.shutdownTimedOut(nowMilliseconds: 20) == false)
    }

    @Test
    func shutdownWithPendingDataSendsDataAtMaximumStateNumber() throws {
        var scheduler = MoshSSPSendScheduler(
            initialState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )

        scheduler.setCurrentState(ByteState([1, 2, 3]), nowMilliseconds: 0)
        scheduler.startShutdown(nowMilliseconds: 0)

        let instruction = try requireData(try scheduler.tick(nowMilliseconds: 20))

        #expect(instruction.oldNumber == 0)
        #expect(instruction.newNumber == UInt64.max)
        #expect(instruction.diff == [1, 2, 3])
        #expect(scheduler.shutdownAttemptCount == 1)
    }

    @Test
    func shutdownTimesOutAfterMaximumAttempts() throws {
        var scheduler = MoshSSPSendScheduler(
            initialState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(
                sendIntervalMilliseconds: 20,
                activeRetryTimeoutMilliseconds: 10_000,
                shutdownMaximumAttempts: 2
            ),
            chaffSource: .none
        )

        scheduler.startShutdown(nowMilliseconds: 0)

        _ = try scheduler.tick(nowMilliseconds: 20)
        #expect(scheduler.shutdownTimedOut(nowMilliseconds: 20) == false)

        _ = try scheduler.tick(nowMilliseconds: 40)

        #expect(scheduler.shutdownAttemptCount == 2)
        #expect(scheduler.shutdownTimedOut(nowMilliseconds: 40))
    }

    @Test
    func shutdownTimesOutAfterActiveRetryWindow() throws {
        var scheduler = MoshSSPSendScheduler(
            initialState: ByteState(),
            timing: MoshSSPSendTimingConfiguration(
                sendIntervalMilliseconds: 20,
                activeRetryTimeoutMilliseconds: 100
            ),
            chaffSource: .none
        )

        scheduler.startShutdown(nowMilliseconds: 10)

        #expect(scheduler.shutdownTimedOut(nowMilliseconds: 109) == false)
        #expect(scheduler.shutdownTimedOut(nowMilliseconds: 110))
    }
}

private func requireData(
    _ event: MoshSSPSendEvent?
) throws -> MoshTransportInstruction {
    let event = try #require(event)
    guard case .data(let instruction) = event else {
        Issue.record("Expected data event.")
        throw TestFailure()
    }
    return instruction
}

private func requireAcknowledgement(
    _ event: MoshSSPSendEvent?
) throws -> MoshTransportInstruction {
    let event = try #require(event)
    guard case .acknowledgement(let instruction) = event else {
        Issue.record("Expected acknowledgement event.")
        throw TestFailure()
    }
    return instruction
}

private struct TestFailure: Error {}

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
