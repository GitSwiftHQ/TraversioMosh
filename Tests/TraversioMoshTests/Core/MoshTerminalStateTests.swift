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
    func dimensionsRejectValuesAboveMaximum() {
        let tooWide = MoshTerminalDimensions.maximumDimension + 1
        // Value at the cap is accepted; one above it is rejected (not clamped).
        #expect(throws: Never.self) {
            _ = try MoshTerminalDimensions(
                columns: MoshTerminalDimensions.maximumDimension,
                rows: MoshTerminalDimensions.maximumDimension
            )
        }
        #expect(throws: MoshTerminalOperationError.invalidColumnCount(tooWide)) {
            _ = try MoshTerminalDimensions(columns: tooWide, rows: 24)
        }
        #expect(throws: MoshTerminalOperationError.invalidRowCount(tooWide)) {
            _ = try MoshTerminalDimensions(columns: 80, rows: tooWide)
        }
    }

    @Test
    func operationDecodingRejectsOversizedWireResizeDimensions() {
        // A malicious server resize of 2^31-1 must be rejected before any
        // grid allocation, not accepted as an unbounded dimension.
        let hostMessage = MoshHostMessage(instructions: [
            MoshHostInstruction(resize: MoshTerminalSize(columns: Int32.max, rows: 24)),
        ])

        #expect(throws: MoshTerminalOperationError.invalidColumnCount(Int32.max)) {
            _ = try MoshHostOperation.operations(from: hostMessage)
        }
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
