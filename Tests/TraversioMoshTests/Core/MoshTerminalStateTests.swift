// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCore
import TraversioMoshWire

struct MoshTerminalStateTests {
    @Test
    func hostMessageProjectsTypedOperationsAndSnapshot() throws {
        let dimensions = try MoshTerminalDimensions(columns: 100, rows: 40)
        let message = MoshHostMessage(instructions: [
            MoshHostInstruction(
                hostBytes: Array("ok".utf8),
                resize: MoshTerminalSize(columns: 100, rows: 40),
                echoAcknowledgementNumber: 300
            ),
        ])

        let operations = try MoshHostOperation.operations(from: message)
        var engine = MoshTerminalStateEngine()
        let emitted = try engine.applyHostMessage(message)

        #expect(operations == [
            .write(MoshTerminalOutput(bytes: Array("ok".utf8))),
            .resize(dimensions),
            .echoAcknowledgement(300),
        ])
        #expect(emitted == operations)
        #expect(engine.snapshot.dimensions == dimensions)
        #expect(engine.snapshot.latestEchoAcknowledgementNumber == 300)
        #expect(engine.snapshot.operations == operations)
    }

    @Test
    func renderSnapshotFiltersProtocolOnlyHostOperations() throws {
        let dimensions = try MoshTerminalDimensions(columns: 120, rows: 50)
        let hostOperations: [MoshHostOperation] = [
            .write(MoshTerminalOutput(bytes: Array("hello".utf8))),
            .echoAcknowledgement(12),
            .resize(dimensions),
            .echoAcknowledgement(13),
        ]
        let snapshot = MoshTerminalSnapshot(
            dimensions: dimensions,
            operations: hostOperations,
            latestEchoAcknowledgementNumber: 13
        )

        #expect(snapshot.renderOperations == [
            .write(MoshTerminalOutput(bytes: Array("hello".utf8))),
            .resize(dimensions),
        ])
        #expect(
            snapshot.renderSnapshot == MoshTerminalRenderSnapshot(
                dimensions: dimensions,
                operations: [
                    .write(MoshTerminalOutput(bytes: Array("hello".utf8))),
                    .resize(dimensions),
                ]
            )
        )
    }

    @Test
    func clientStateDiffCarriesOperationSuffix() throws {
        let initial = MoshTerminalClientState(operations: [
            .keystrokes(Array("a".utf8)),
        ])
        let expected = MoshTerminalClientState(operations: [
            .keystrokes(Array("a".utf8)),
            .resize(try MoshTerminalDimensions(columns: 80, rows: 24)),
        ])

        let diff = try expected.moshDiff(from: initial)
        var reconstructed = initial
        try reconstructed.applyMoshDiff(diff)

        #expect(reconstructed == expected)

        var suffix = expected
        try suffix.subtractMoshState(initial)

        #expect(suffix.operations == [
            .resize(try MoshTerminalDimensions(columns: 80, rows: 24)),
        ])
    }

    @Test
    func hostStateDiffAdoptsFramebufferAndEmitsOnlyAppliedDiff() throws {
        // Host states are now materialized framebuffers. A diff is applied onto
        // the framebuffer (not appended to a log), so two states built by the
        // same operation sequence are framebuffer-equal, and applying a diff
        // reports exactly the operations that diff carried.
        let initial = MoshTerminalHostState(operations: [
            .write(MoshTerminalOutput(bytes: Array("hi".utf8))),
        ])
        let resized = try MoshTerminalDimensions(columns: 132, rows: 43)
        let expected = MoshTerminalHostState(operations: [
            .write(MoshTerminalOutput(bytes: Array("hi".utf8))),
            .resize(resized),
            .echoAcknowledgement(7),
        ])

        let diff = try expected.moshDiff(from: initial)
        var reconstructed = initial
        try reconstructed.applyMoshDiff(diff)
        var engine = MoshTerminalStateEngine(hostState: initial)
        let emitted = try engine.applyHostDiff(diff)

        // Framebuffer + echo-ack equality (Terminal::Complete::operator==).
        #expect(reconstructed == expected)
        #expect(reconstructed.screenSnapshot == expected.screenSnapshot)

        // Only the operations this diff carried are surfaced; no full-history log.
        #expect(emitted == [
            .resize(resized),
            .echoAcknowledgement(7),
        ])
        #expect(reconstructed.lastAppliedOperations == [
            .resize(resized),
            .echoAcknowledgement(7),
        ])

        #expect(engine.snapshot.dimensions == resized)
        #expect(engine.snapshot.latestEchoAcknowledgementNumber == 7)
        #expect(engine.snapshot.operations == [
            .resize(resized),
            .echoAcknowledgement(7),
        ])
        #expect(reconstructed.dimensions == resized)
        #expect(reconstructed.latestEchoAcknowledgementNumber == 7)
    }

    @Test
    func sspLoopSupportsDifferentClientAndHostStateTypes() throws {
        var client = MoshSSPInMemoryLoop(
            initialSendState: MoshTerminalClientState(),
            initialReceiveState: MoshTerminalHostState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )
        var server = MoshSSPInMemoryLoop(
            initialSendState: MoshTerminalHostState(),
            initialReceiveState: MoshTerminalClientState(),
            timing: MoshSSPSendTimingConfiguration(sendIntervalMilliseconds: 20),
            chaffSource: .none
        )
        let clientState = MoshTerminalClientState(operations: [
            .keystrokes(Array("a".utf8)),
            .resize(try MoshTerminalDimensions(columns: 80, rows: 24)),
        ])

        client.setCurrentState(clientState, nowMilliseconds: 0)
        let clientBatch = try #require(try client.tick(nowMilliseconds: 20))
        let serverReceive = try deliver(clientBatch.packets, to: &server, nowMilliseconds: 21)

        #expect(serverReceive.receiveResult == .accepted(newNumber: 1))
        #expect(serverReceive.latestState.state == clientState)

        let hostDimensions = try MoshTerminalDimensions(columns: 100, rows: 40)
        let hostState = MoshTerminalHostState(operations: [
            .write(MoshTerminalOutput(bytes: Array("ok".utf8))),
            .resize(hostDimensions),
            .echoAcknowledgement(1),
        ])

        server.setCurrentState(hostState, nowMilliseconds: 21)
        let serverBatch = try #require(try server.tick(nowMilliseconds: 41))
        let clientReceive = try deliver(serverBatch.packets, to: &client, nowMilliseconds: 42)

        #expect(clientReceive.receiveResult == .accepted(newNumber: 1))
        #expect(clientReceive.latestState.state == hostState)
        #expect(client.latestReceivedState.state.snapshot.dimensions == hostDimensions)
        #expect(client.latestReceivedState.state.snapshot.latestEchoAcknowledgementNumber == 1)
    }

    @Test
    func dimensionsRejectNonPositiveValues() {
        #expect(throws: MoshTerminalOperationError.invalidColumnCount(0)) {
            _ = try MoshTerminalDimensions(columns: 0, rows: 24)
        }
        #expect(throws: MoshTerminalOperationError.invalidRowCount(-1)) {
            _ = try MoshTerminalDimensions(columns: 80, rows: -1)
        }
    }

    @Test
    func dimensionsClampValuesAboveMaximum() throws {
        // Values within both the per-dimension cap and the combined
        // cell-count budget pass through unchanged; oversized values clamp
        // instead of throwing, because a wire resize that throws tears down
        // the whole session.
        let within = try MoshTerminalDimensions(columns: 300, rows: 100)
        #expect(within.columns == 300)
        #expect(within.rows == 100)

        let expectedClampedDimension = Int32(
            MoshTerminalDimensions.maximumCellCount / Int(MoshTerminalDimensions.maximumDimension)
        )

        let atCap = try MoshTerminalDimensions(
            columns: MoshTerminalDimensions.maximumDimension,
            rows: MoshTerminalDimensions.maximumDimension
        )
        // Both dimensions are individually at the per-dimension cap, but their
        // product (4,194,304) exceeds `maximumCellCount`, so one dimension
        // (tied here, so columns) shrinks to bring the total into budget while
        // the other is preserved.
        #expect(atCap.rows == MoshTerminalDimensions.maximumDimension)
        #expect(atCap.columns == expectedClampedDimension)
        #expect(Int(atCap.columns) * Int(atCap.rows) <= MoshTerminalDimensions.maximumCellCount)

        let oversized = try MoshTerminalDimensions(columns: 5000, rows: 5000)
        #expect(oversized.rows == MoshTerminalDimensions.maximumDimension)
        #expect(oversized.columns == expectedClampedDimension)
    }

    @Test
    func dimensionsClampCombinedCellCountEvenWhenEachDimensionIsIndividuallyWithinBounds() throws {
        // Finding: independent per-dimension clamping alone is insufficient —
        // two dimensions can each pass the per-dimension cap while their
        // product still reaches OOM-scale allocation. 2000 x 2000 is under
        // `maximumDimension` (2048) on both axes, but its product (4,000,000)
        // is far beyond `maximumCellCount`.
        let dimensions = try MoshTerminalDimensions(columns: 2000, rows: 2000)

        #expect(dimensions.columns < 2000)
        #expect(dimensions.rows == 2000)
        #expect(Int(dimensions.columns) * Int(dimensions.rows) <= MoshTerminalDimensions.maximumCellCount)
    }

    @Test
    func dimensionsClampPreservesTheSmallerDimensionWhenShrinkingForCombinedBudget() throws {
        // The asymmetric case: the smaller dimension (columns) is preserved
        // and the larger one (rows) is the one shrunk.
        let dimensions = try MoshTerminalDimensions(columns: 200, rows: 2040)

        #expect(dimensions.columns == 200)
        #expect(dimensions.rows == 1250)
        #expect(Int(dimensions.columns) * Int(dimensions.rows) <= MoshTerminalDimensions.maximumCellCount)
    }

    @Test
    func operationDecodingClampsOversizedWireResizeDimensions() throws {
        // A hostile or buggy peer resize of 2^31-1 must not throw (a throw
        // here is classified non-packet-local and tears down the session) and
        // must not reach grid allocation unclamped.
        let hostMessage = MoshHostMessage(instructions: [
            MoshHostInstruction(resize: MoshTerminalSize(columns: Int32.max, rows: 5000)),
        ])

        let operations = try MoshHostOperation.operations(from: hostMessage)

        #expect(operations == [
            .resize(try MoshTerminalDimensions(
                columns: MoshTerminalDimensions.maximumDimension,
                rows: MoshTerminalDimensions.maximumDimension
            )),
        ])
    }

    @Test
    func operationDecodingAcceptsLargeButRealisticWireResize() throws {
        // Regression: a large, asymmetric resize used to work, then an
        // overly aggressive cap rejected it and killed the session. 1000x200
        // (200,000 cells) is comfortably under `maximumCellCount` and must
        // decode unchanged.
        let hostMessage = MoshHostMessage(instructions: [
            MoshHostInstruction(resize: MoshTerminalSize(columns: 1000, rows: 200)),
        ])

        let operations = try MoshHostOperation.operations(from: hostMessage)

        #expect(operations == [.resize(try MoshTerminalDimensions(columns: 1000, rows: 200))])
    }

    @Test
    func operationDecodingRejectsInvalidWireResizeDimensions() {
        let clientMessage = MoshClientMessage(instructions: [
            MoshClientInstruction(resize: MoshTerminalSize(columns: 0, rows: 24)),
        ])
        let hostMessage = MoshHostMessage(instructions: [
            MoshHostInstruction(resize: MoshTerminalSize(columns: 80, rows: -1)),
        ])

        #expect(throws: MoshTerminalOperationError.invalidColumnCount(0)) {
            _ = try MoshClientOperation.operations(from: clientMessage)
        }
        #expect(throws: MoshTerminalOperationError.invalidRowCount(-1)) {
            _ = try MoshHostOperation.operations(from: hostMessage)
        }
    }
}

private func deliver<Packets: Sequence, SendState: MoshSynchronizedState, ReceiveState: MoshSynchronizedState>(
    _ packets: Packets,
    to loop: inout MoshSSPInMemoryLoop<SendState, ReceiveState>,
    nowMilliseconds: UInt64,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> MoshSSPIncomingInstructionResult<ReceiveState> where Packets.Element == MoshSSPOutgoingPacket {
    var completed: MoshSSPIncomingInstructionResult<ReceiveState>?
    for packet in packets {
        let result = try loop.receive(packet.plaintext, nowMilliseconds: nowMilliseconds)
        switch result {
        case .incompleteFragment:
            break
        case .instruction(let instructionResult):
            completed = instructionResult
        }
    }

    return try #require(completed, sourceLocation: sourceLocation)
}
