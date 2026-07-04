// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCore
import TraversioMoshWire

/// Regression coverage for the host-state materialization / rationalization
/// rework: framebuffer adoption (no full-history replay), bounded client memory,
/// the receiver-queue quench cap, and diff-scoped terminal replies.
struct MoshHostStateAdoptionTests {
    private func hostDiff(_ operations: [MoshHostOperation]) -> [UInt8] {
        MoshHostOperation.message(from: operations).serializedBytes()
    }

    private func write(_ string: String) -> MoshHostOperation {
        .write(MoshTerminalOutput(bytes: Array(string.utf8)))
    }

    // MARK: - P0-1: rebased host state must not replay history

    @Test
    func rebasedHostStateAdoptsFramebufferWithoutReplayingHistory() throws {
        let dims = try MoshTerminalDimensions(columns: 5, rows: 1)

        // Receiver-style construction: each state is exactly its reference state
        // plus the one diff the server sent for it.
        let s0 = MoshTerminalHostState(dimensions: dims)
        var s3 = s0
        try s3.applyMoshDiff(hostDiff([write("AB")]))
        var s5 = s3
        try s5.applyMoshDiff(hostDiff([write("C")])) // normal chain s3 -> s5
        var s6 = s3
        try s6.applyMoshDiff(hostDiff([write("X")])) // re-based from s3 (ack of s5 lost)

        var engine = MoshTerminalStateEngine(hostState: s0)
        _ = engine.acceptHostState(s3)
        #expect(engine.hostState.screenSnapshot.lineStrings == ["AB   "])
        _ = engine.acceptHostState(s5)
        #expect(engine.hostState.screenSnapshot.lineStrings == ["ABC  "])

        // Accepting the re-based s6 must surface only s6's own diff ...
        let s6Operations = engine.acceptHostState(s6)
        #expect(s6Operations == [write("X")])

        // ... and the adopted framebuffer must equal s6 exactly (s3 + "X" = "ABX"),
        // never "ABC" corrupted by replaying the historical "AB" write.
        #expect(engine.hostState.screenSnapshot == s6.screenSnapshot)
        #expect(engine.hostState.screenSnapshot.lineStrings == ["ABX  "])
    }

    // MARK: - Bounded memory

    @Test
    func acknowledgedClientKeystrokesArePrunedByRationalize() throws {
        var scheduler = MoshSSPSendScheduler(
            initialState: MoshTerminalClientState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )

        // Three keystrokes accumulate in the sender-owned current state.
        scheduler.modifyCurrentState(nowMilliseconds: 0) { $0.append(.keystrokes([0x61])) }
        scheduler.modifyCurrentState(nowMilliseconds: 0) { $0.append(.keystrokes([0x62])) }
        scheduler.modifyCurrentState(nowMilliseconds: 0) { $0.append(.keystrokes([0x63])) }
        _ = try scheduler.tick(nowMilliseconds: 20) // sends state 1 = [a, b, c]

        #expect(scheduler.sender.currentSendState.operations.count == 3)

        // The peer acknowledges the sent state. The next housekeeping pass calls
        // rationalize_states, which cuts the acknowledged prefix.
        scheduler.processAcknowledgement(through: 1, nowMilliseconds: 21)
        _ = try scheduler.waitTime(nowMilliseconds: 22)

        #expect(scheduler.sender.currentSendState.operations.isEmpty)
        #expect(scheduler.sender.knownAcknowledgedStateNumber == 1)
    }

    @Test
    func receivedHostStatesRetainNoOperationHistory() throws {
        let dims = try MoshTerminalDimensions(columns: 40, rows: 1)
        var receiver = MoshSSPReceiver(initialState: MoshTerminalHostState(dimensions: dims))

        for number in 1...30 {
            let instruction = MoshTransportInstruction(
                protocolVersion: 2,
                oldNumber: UInt64(number - 1),
                newNumber: UInt64(number),
                acknowledgementNumber: 0,
                throwawayNumber: 0,
                diff: hostDiff([write("x")]),
                chaff: []
            )
            #expect(try receiver.receive(instruction) == .accepted(newNumber: UInt64(number)))
        }

        // After 30 chained diffs the framebuffer holds 30 characters, but the
        // state itself carries only the single most-recent diff -- no op-log grows
        // with history (contrast the old append-only model where this would be 30).
        let latest = receiver.latestState.state
        #expect(latest.lastAppliedOperations == [write("x")])
        #expect(latest.screenSnapshot.lineStrings.first?.hasPrefix(String(repeating: "x", count: 30)) == true)
    }

    // MARK: - Diff-scoped terminal replies (no historical DA/DSR resend)

    @Test
    func adoptingRebasedStateDoesNotResendHistoricalTerminalReplies() throws {
        let dims = try MoshTerminalDimensions(columns: 5, rows: 1)
        let s0 = MoshTerminalHostState(dimensions: dims)

        // s1 carries a DSR cursor-position request, generating a reply once.
        var s1 = s0
        try s1.applyMoshDiff(hostDiff([write("A\u{1b}[6n")]))
        #expect(s1.lastAppliedTerminalToHostBytes == Array("\u{1b}[1;2R".utf8))

        // s2, re-based from s1, carries only a plain write and no query.
        var s2 = s1
        try s2.applyMoshDiff(hostDiff([write("B")]))

        // Adopting s2 must not re-emit s1's historical DSR reply.
        #expect(s2.lastAppliedTerminalToHostBytes.isEmpty)
        #expect(s2.lastAppliedOperations == [write("B")])
    }

    // MARK: - Receiver queue cap (1024-state quench)

    @Test
    func receiverQueueQuenchesGrowthBeyondMaximum() throws {
        var receiver = MoshSSPReceiver(initialState: ByteState())
        let maximum = MoshSSPReceiver<ByteState>.maximumReceivedStateCount

        // Admit states 1...maximum+1 (all referencing state 0 so throwaway never
        // prunes them). The state that first pushes the queue past the cap arms
        // the quench timer but is still admitted.
        for number in 1...(maximum + 1) {
            let result = try receiver.receive(
                byteInstruction(old: 0, new: UInt64(number), diff: [UInt8(truncatingIfNeeded: number)]),
                nowMilliseconds: 0
            )
            #expect(result == .accepted(newNumber: UInt64(number)))
        }

        // Now the queue exceeds the cap and the quench window is open: a further
        // state is denied without being acknowledged.
        #expect(
            try receiver.receive(byteInstruction(old: 0, new: 5_000, diff: [1]), nowMilliseconds: 0)
                == .queueFull(newNumber: 5_000)
        )
        #expect(receiver.acknowledgementNumber == UInt64(maximum + 1))

        // Once the 15s quench window elapses, exactly one more state is admitted,
        // which re-arms the timer and quenches the next.
        #expect(
            try receiver.receive(byteInstruction(old: 0, new: 5_000, diff: [1]), nowMilliseconds: 15_000)
                == .accepted(newNumber: 5_000)
        )
        #expect(
            try receiver.receive(byteInstruction(old: 0, new: 5_001, diff: [1]), nowMilliseconds: 15_000)
                == .queueFull(newNumber: 5_001)
        )
    }

    private func byteInstruction(old: UInt64, new: UInt64, diff: [UInt8]) -> MoshTransportInstruction {
        MoshTransportInstruction(
            protocolVersion: 2,
            oldNumber: old,
            newNumber: new,
            acknowledgementNumber: 0,
            throwawayNumber: 0,
            diff: diff,
            chaff: []
        )
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
