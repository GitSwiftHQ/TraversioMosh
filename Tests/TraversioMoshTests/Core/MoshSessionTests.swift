// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import TraversioMoshCore
import TraversioMoshCrypto
import TraversioMoshTransport

struct MoshSessionTests {
    @Test
    func startSendsInitialResizeThroughInjectedTransport() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 1)
        let diagnosticEventTask = collectEvents(from: fixture.session, count: 2)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let diagnosticEvents = try await withSessionTimeout {
                await diagnosticEventTask.value
            }

            let instruction = try #require(serverInstructions.first)
            #expect(instruction.instructionResult.receiveResult == .accepted(newNumber: 1))
            #expect(
                instruction.instructionResult.latestState.state.operations == [
                    .resize(try MoshTerminalDimensions(columns: 80, rows: 24))
                ]
            )
            #expect(
                diagnosticEvents == [
                    .started(fixture.endpoint),
                    .datagramsSent(packetCount: 1),
                ]
            )

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            serverInstructionTask.cancel()
            diagnosticEventTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    @Test
    func keystrokesAndResizeAdvanceClientOperationState() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 3)
        let resizedDimensions = try MoshTerminalDimensions(columns: 120, rows: 40)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            try await fixture.session.sendKeystrokes([0x61, 0x62])
            try await fixture.session.resize(resizedDimensions)

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let finalState = try #require(serverInstructions.last).instructionResult.latestState.state

            #expect(
                finalState.operations == [
                    .resize(try MoshTerminalDimensions(columns: 80, rows: 24)),
                    .keystrokes([0x61, 0x62]),
                    .resize(resizedDimensions),
                ]
            )

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            serverInstructionTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    @Test
    func hostOperationStreamYieldsServerStateOperations() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 2)
        let hostDimensions = try MoshTerminalDimensions(columns: 100, rows: 32)
        let hostOperations: [MoshHostOperation] = [
            .write(MoshTerminalOutput(bytes: [0x48, 0x69])),
            .resize(hostDimensions),
        ]

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            var hostState = MoshTerminalHostState()
            hostState.append(contentsOf: hostOperations)
            await fixture.serverRuntime.setCurrentState(hostState)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            let receivedOperations = try await withSessionTimeout {
                try await hostOperationTask.value
            }

            #expect(receivedOperations == hostOperations)
            #expect(await fixture.session.snapshot.dimensions == hostDimensions)

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            hostOperationTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    @Test
    func lifecycleRejectsInvalidStartAndStoppedOperations() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)

        await expectSessionError(.notStarted) {
            try await fixture.session.sendKeystrokes([0x61])
        }

        try await fixture.serverRuntime.start()
        try await fixture.session.start()

        await expectSessionError(.alreadyStarted) {
            try await fixture.session.start()
        }

        await fixture.session.stop()

        await expectSessionError(.stopped) {
            try await fixture.session.sendKeystrokes([0x62])
        }

        await fixture.serverRuntime.stop()
    }
}

private struct MoshSessionFixture: Sendable {
    let endpoint: MoshEndpoint
    let session: MoshSession
    let serverRuntime: MoshSSPDatagramRuntime<MoshTerminalHostState, MoshTerminalClientState>
}

private actor ManualMillisecondsClock: MoshMillisecondsClock {
    private var nowMillisecondsStorage: UInt64 = 0

    func nowMilliseconds() async -> UInt64 {
        self.nowMillisecondsStorage
    }
}

private struct FixedTransportFactory: MoshSessionTransportFactory {
    let link: MoshInMemoryDatagramLink

    func makeDatagramLink(for endpoint: MoshEndpoint) async throws -> any MoshDatagramLink {
        self.link
    }
}

private func makeSessionFixture(columns: Int32, rows: Int32) async throws -> MoshSessionFixture {
    let pair = await MoshInMemoryDatagramLink.connectedPair()
    let clock = ManualMillisecondsClock()
    let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
    let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
    let initialTerminalDimensions = try MoshTerminalDimensions(columns: columns, rows: rows)
    let timing = MoshSSPSendTimingConfiguration(
        sendIntervalMilliseconds: 0,
        acknowledgementIntervalMilliseconds: 1_000,
        activeRetryTimeoutMilliseconds: 10_000,
        sendMinimumDelayMilliseconds: 0,
        timeoutMilliseconds: 1_000,
        shutdownMaximumAttempts: 16
    )
    let session = MoshSession(
        configuration: MoshSessionConfiguration(
            endpoint: endpoint,
            initialTerminalDimensions: initialTerminalDimensions,
            transportFactory: FixedTransportFactory(link: pair.client),
            clock: clock,
            timing: timing,
            chaffSource: .none
        )
    )
    let serverRuntime = try makeServerRuntime(
        link: pair.server,
        clock: clock,
        timing: timing
    )

    return MoshSessionFixture(
        endpoint: endpoint,
        session: session,
        serverRuntime: serverRuntime
    )
}

private func makeServerRuntime(
    link: MoshInMemoryDatagramLink,
    clock: ManualMillisecondsClock,
    timing: MoshSSPSendTimingConfiguration
) throws -> MoshSSPDatagramRuntime<MoshTerminalHostState, MoshTerminalClientState> {
    let loop = MoshSSPInMemoryLoop(
        initialSendState: MoshTerminalHostState(),
        initialReceiveState: MoshTerminalClientState(),
        timing: timing,
        chaffSource: .none
    )
    let sequencer = try MoshDatagramSequencer(
        sessionKey: MoshSessionKey(rawBytes: sessionKeyBytes),
        sendDirection: .toClient,
        receiveDirection: .toServer
    )
    return MoshSSPDatagramRuntime(
        loop: loop,
        sequencer: sequencer,
        link: link,
        clock: clock
    )
}

private func collectServerInstructions(
    from runtime: MoshSSPDatagramRuntime<MoshTerminalHostState, MoshTerminalClientState>,
    count: Int
) -> Task<[MoshSSPDatagramIncomingInstruction<MoshTerminalClientState>], Error> {
    Task {
        var iterator = runtime.incomingInstructions.makeAsyncIterator()
        var instructions: [MoshSSPDatagramIncomingInstruction<MoshTerminalClientState>] = []
        while instructions.count < count {
            guard let instruction = try await iterator.next() else {
                break
            }
            instructions.append(instruction)
        }
        return instructions
    }
}

private func collectHostOperations(
    from session: MoshSession,
    count: Int
) -> Task<[MoshHostOperation], Error> {
    Task {
        var iterator = session.hostOperations.makeAsyncIterator()
        var operations: [MoshHostOperation] = []
        while operations.count < count {
            guard let operation = try await iterator.next() else {
                break
            }
            operations.append(operation)
        }
        return operations
    }
}

private func collectEvents(
    from session: MoshSession,
    count: Int
) -> Task<[MoshSessionEvent], Never> {
    Task {
        var iterator = session.diagnosticEvents.makeAsyncIterator()
        var events: [MoshSessionEvent] = []
        while events.count < count {
            guard let event = await iterator.next() else {
                break
            }
            events.append(event)
        }
        return events
    }
}

private enum SessionTestError: Error, Equatable {
    case timedOut
}

private func withSessionTimeout<T: Sendable>(
    after duration: Duration = .seconds(2),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: duration)
            throw SessionTestError.timedOut
        }

        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}

private func expectSessionError(
    _ expected: MoshSessionError,
    operation: @escaping () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected), but operation succeeded.", sourceLocation: sourceLocation)
    } catch let error as MoshSessionError {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected \(expected), but received \(error).", sourceLocation: sourceLocation)
    }
}

private let sessionKeyBytes = Array(UInt8(0)..<UInt8(16))
