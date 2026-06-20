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
    func terminalInputTranslatesSplitCursorKeySequenceBeforeClientState() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 3)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            try await fixture.session.sendTerminalInput([0x1b], applicationCursorKeysEnabled: false)
            try await fixture.session.sendTerminalInput([UInt8(ascii: "O")], applicationCursorKeysEnabled: false)
            try await fixture.session.sendTerminalInput([UInt8(ascii: "A")], applicationCursorKeysEnabled: false)

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let finalState = try #require(serverInstructions.last).instructionResult.latestState.state

            #expect(
                finalState.operations == [
                    .resize(try MoshTerminalDimensions(columns: 80, rows: 24)),
                    .keystrokes([0x1b]),
                    .keystrokes([UInt8(ascii: "["), UInt8(ascii: "A")]),
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
    func rawKeystrokesDoNotApplyTerminalInputTranslation() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 2)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            try await fixture.session.sendKeystrokes([0x1b, UInt8(ascii: "O"), UInt8(ascii: "A")])

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let finalState = try #require(serverInstructions.last).instructionResult.latestState.state

            #expect(
                finalState.operations == [
                    .resize(try MoshTerminalDimensions(columns: 80, rows: 24)),
                    .keystrokes([0x1b, UInt8(ascii: "O"), UInt8(ascii: "A")]),
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
    func renderOperationStreamFiltersProtocolOnlyHostOperations() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 3)
        let renderOperationTask = collectRenderOperations(from: fixture.session, count: 2)
        let hostDimensions = try MoshTerminalDimensions(columns: 100, rows: 32)
        let hostOperations: [MoshHostOperation] = [
            .write(MoshTerminalOutput(bytes: [0x48, 0x69])),
            .echoAcknowledgement(42),
            .resize(hostDimensions),
        ]

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            var hostState = MoshTerminalHostState()
            hostState.append(contentsOf: hostOperations)
            await fixture.serverRuntime.setCurrentState(hostState)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            let receivedHostOperations = try await withSessionTimeout {
                try await hostOperationTask.value
            }
            let receivedRenderOperations = try await withSessionTimeout {
                try await renderOperationTask.value
            }

            #expect(receivedHostOperations == hostOperations)
            #expect(receivedRenderOperations == [
                .write(MoshTerminalOutput(bytes: [0x48, 0x69])),
                .resize(hostDimensions),
            ])
            #expect(await fixture.session.snapshot.renderSnapshot == MoshTerminalRenderSnapshot(
                dimensions: hostDimensions,
                operations: receivedRenderOperations
            ))

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            hostOperationTask.cancel()
            renderOperationTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    @Test
    func screenSnapshotProjectsHostRenderOperations() async throws {
        let fixture = try await makeSessionFixture(columns: 3, rows: 2)
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 2)
        let hostDimensions = try MoshTerminalDimensions(columns: 4, rows: 2)
        let hostOperations: [MoshHostOperation] = [
            .write(MoshTerminalOutput(bytes: Array("ab\u{1b}[?1h".utf8))),
            .resize(hostDimensions),
        ]

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            var hostState = MoshTerminalHostState()
            hostState.append(contentsOf: hostOperations)
            await fixture.serverRuntime.setCurrentState(hostState)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            let receivedHostOperations = try await withSessionTimeout {
                try await hostOperationTask.value
            }
            let screenSnapshot = await fixture.session.screenSnapshot

            #expect(receivedHostOperations == hostOperations)
            #expect(screenSnapshot.dimensions == hostDimensions)
            #expect(screenSnapshot.lineStrings == ["ab  ", "    "])
            #expect(screenSnapshot.cursor == MoshTerminalCursor(row: 0, column: 2))
            #expect(screenSnapshot.isApplicationCursorKeysEnabled == true)

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
    func terminalInputWithoutExplicitModePreservesTerminalBytesForServerTranslation() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 2)
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 1)
        let hostOutput = MoshHostOperation.write(
            MoshTerminalOutput(bytes: Array("\u{1b}[?1h".utf8))
        )

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            var hostState = MoshTerminalHostState()
            hostState.append(hostOutput)
            await fixture.serverRuntime.setCurrentState(hostState)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            let hostOperations = try await withSessionTimeout {
                try await hostOperationTask.value
            }
            #expect(hostOperations == [hostOutput])
            #expect(await fixture.session.screenSnapshot.isApplicationCursorKeysEnabled == true)

            try await fixture.session.sendTerminalInput([0x1b, UInt8(ascii: "O"), UInt8(ascii: "A")])

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let finalState = try #require(serverInstructions.last).instructionResult.latestState.state

            #expect(
                finalState.operations == [
                    .resize(try MoshTerminalDimensions(columns: 80, rows: 24)),
                    .keystrokes([0x1b, UInt8(ascii: "O"), UInt8(ascii: "A")]),
                ]
            )

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            serverInstructionTask.cancel()
            hostOperationTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    @Test
    func localResizeDoesNotMutateScreenSnapshotBeforeHostResize() async throws {
        let fixture = try await makeSessionFixture(columns: 3, rows: 2)
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 2)
        let initialDimensions = try MoshTerminalDimensions(columns: 3, rows: 2)
        let resizedDimensions = try MoshTerminalDimensions(columns: 5, rows: 2)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            try await fixture.session.resize(resizedDimensions)

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let finalState = try #require(serverInstructions.last).instructionResult.latestState.state

            #expect(
                finalState.operations == [
                    .resize(try MoshTerminalDimensions(columns: 3, rows: 2)),
                    .resize(resizedDimensions),
                ]
            )
            #expect(await fixture.session.screenSnapshot.dimensions == initialDimensions)

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
    func screenProjectionFailureEmitsTypedDiagnosticAndFinishesStreams() async throws {
        let fixture = try await makeSessionFixture(columns: 3, rows: 2)
        let diagnosticEventTask = collectEvents(from: fixture.session, count: 4)
        let hostStreamFailureTask = collectStreamFailure(from: fixture.session.hostOperations)
        let renderStreamFailureTask = collectStreamFailure(from: fixture.session.renderOperations)
        let invalidOutput = MoshTerminalOutput(bytes: [0xff])
        let hostOperation = MoshHostOperation.write(invalidOutput)
        let expectedFailure = MoshSessionScreenProjectionFailure(
            stateNumber: 1,
            operationIndex: 0,
            operation: .write(invalidOutput),
            reason: .terminalInputParser(.invalidUTF8(offset: 0))
        )

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            var hostState = MoshTerminalHostState()
            hostState.append(hostOperation)
            await fixture.serverRuntime.setCurrentState(hostState)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            let diagnosticEvents = try await withSessionTimeout {
                await diagnosticEventTask.value
            }
            let hostStreamError = try #require(await hostStreamFailureTask.value)
            let hostFailure = try #require(hostStreamError as? MoshSessionScreenProjectionFailure)
            let renderStreamError = try #require(await renderStreamFailureTask.value)
            let renderFailure = try #require(renderStreamError as? MoshSessionScreenProjectionFailure)

            #expect(
                diagnosticEvents == [
                    .started(fixture.endpoint),
                    .datagramsSent(packetCount: 1),
                    .screenProjectionFailed(expectedFailure),
                    .stopped,
                ]
            )
            #expect(hostFailure == expectedFailure)
            #expect(renderFailure == expectedFailure)
            #expect(await fixture.session.screenSnapshot.lineStrings == ["   ", "   "])

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            diagnosticEventTask.cancel()
            hostStreamFailureTask.cancel()
            renderStreamFailureTask.cancel()
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
        await expectSessionError(.notStarted) {
            try await fixture.session.shutdown()
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
        await expectSessionError(.stopped) {
            try await fixture.session.shutdown()
        }

        await fixture.serverRuntime.stop()
    }

    @Test
    func maintenanceLoopSendsInitialResizeAfterMinimumDelay() async throws {
        let timing = MoshSSPSendTimingConfiguration(
            sendIntervalMilliseconds: 0,
            acknowledgementIntervalMilliseconds: 1_000,
            sendMinimumDelayMilliseconds: 25
        )
        let fixture = try await makeSessionFixture(columns: 80, rows: 24, timing: timing)
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 1)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            let waitMilliseconds = try await withSessionTimeout {
                await fixture.timer.nextSleepRequest()
            }
            #expect(waitMilliseconds == 25)

            await fixture.clock.advance(byMilliseconds: waitMilliseconds)
            await fixture.timer.resumeNextSleep()

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let instruction = try #require(serverInstructions.first)

            #expect(instruction.instructionResult.receiveResult == .accepted(newNumber: 1))
            #expect(
                instruction.instructionResult.latestState.state.operations == [
                    .resize(try MoshTerminalDimensions(columns: 80, rows: 24))
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
    func maintenanceLoopSendsDelayedAcknowledgementAfterHostState() async throws {
        let timing = MoshSSPSendTimingConfiguration(
            sendIntervalMilliseconds: 0,
            acknowledgementIntervalMilliseconds: 1_000,
            sendMinimumDelayMilliseconds: 0
        )
        let fixture = try await makeSessionFixture(columns: 80, rows: 24, timing: timing)
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 2)
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 1)
        let hostOperation = MoshHostOperation.write(MoshTerminalOutput(bytes: [0x48]))

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            let heartbeatWait = try await withSessionTimeout {
                await fixture.timer.nextSleepRequest()
            }
            #expect(heartbeatWait == 1_000)

            var hostState = MoshTerminalHostState()
            hostState.append(hostOperation)
            await fixture.serverRuntime.setCurrentState(hostState)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            let hostOperations = try await withSessionTimeout {
                try await hostOperationTask.value
            }
            #expect(hostOperations == [hostOperation])

            let delayedAckWait = try await withSessionTimeout {
                await fixture.timer.nextSleepRequest()
            }
            #expect(delayedAckWait == 100)

            await fixture.clock.advance(byMilliseconds: delayedAckWait)
            await fixture.timer.resumeNextSleep()

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let acknowledgement = try #require(serverInstructions.last)

            #expect(acknowledgement.instructionResult.instruction.acknowledgementNumber == 1)
            #expect(acknowledgement.instructionResult.instruction.diff == [])

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            serverInstructionTask.cancel()
            hostOperationTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    @Test
    func maintenanceLoopRetransmitsUnacknowledgedClientState() async throws {
        let timing = MoshSSPSendTimingConfiguration(
            sendIntervalMilliseconds: 20,
            acknowledgementIntervalMilliseconds: 1_000,
            activeRetryTimeoutMilliseconds: 1_000,
            sendMinimumDelayMilliseconds: 0,
            timeoutMilliseconds: 50
        )
        let fixture = try await makeSessionFixture(columns: 80, rows: 24, timing: timing)
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 3)
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 1)
        let hostOperation = MoshHostOperation.write(MoshTerminalOutput(bytes: [0x48]))

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            let initialWait = try await withSessionTimeout {
                await fixture.timer.nextSleepRequest()
            }
            #expect(initialWait == 20)
            await fixture.clock.advance(byMilliseconds: initialWait)
            await fixture.timer.resumeNextSleep()

            let postInitialWait = try await withSessionTimeout {
                await fixture.timer.nextSleepRequest()
            }
            #expect(postInitialWait == 1_000)

            var hostState = MoshTerminalHostState()
            hostState.append(hostOperation)
            await fixture.serverRuntime.setCurrentState(hostState)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            let hostOperations = try await withSessionTimeout {
                try await hostOperationTask.value
            }
            #expect(hostOperations == [hostOperation])

            let delayedAckWait = try await withSessionTimeout {
                await fixture.timer.nextSleepRequest()
            }
            #expect(delayedAckWait == 100)

            try await fixture.session.sendKeystrokes([0x61])

            let keystrokeWait = try await withSessionTimeout {
                await fixture.timer.nextSleepRequest()
            }
            #expect(keystrokeWait == 20)
            await fixture.clock.advance(byMilliseconds: keystrokeWait)
            await fixture.timer.resumeNextSleep()

            let activeRetryWait = try await withSessionTimeout {
                await fixture.timer.nextSleepRequest()
            }
            #expect(activeRetryWait == 150)
            await fixture.clock.advance(byMilliseconds: activeRetryWait)
            await fixture.timer.resumeNextSleep()

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let keystrokeState = serverInstructions[1].instructionResult
            let retransmission = serverInstructions[2].instructionResult

            #expect(keystrokeState.receiveResult == .accepted(newNumber: 2))
            #expect(retransmission.receiveResult == .duplicate(newNumber: 2))
            #expect(
                retransmission.latestState.state.operations == [
                    .resize(try MoshTerminalDimensions(columns: 80, rows: 24)),
                    .keystrokes([0x61]),
                ]
            )

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            serverInstructionTask.cancel()
            hostOperationTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    @Test
    func stopCancelsPendingMaintenanceSleepAndFinishesDiagnostics() async throws {
        let timing = MoshSSPSendTimingConfiguration(
            sendIntervalMilliseconds: 0,
            acknowledgementIntervalMilliseconds: 1_000,
            sendMinimumDelayMilliseconds: 25
        )
        let fixture = try await makeSessionFixture(columns: 80, rows: 24, timing: timing)
        let diagnosticEventTask = collectEvents(from: fixture.session, count: 2)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            let waitMilliseconds = try await withSessionTimeout {
                await fixture.timer.nextSleepRequest()
            }
            #expect(waitMilliseconds == 25)

            await fixture.session.stop()

            let diagnosticEvents = try await withSessionTimeout {
                await diagnosticEventTask.value
            }

            #expect(diagnosticEvents == [.started(fixture.endpoint), .stopped])
            #expect(await fixture.timer.pendingSleepCount() == 0)

            await fixture.serverRuntime.stop()
        } catch {
            diagnosticEventTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    @Test
    func shutdownSendsMaximumStateAndWaitsForAcknowledgement() async throws {
        let timing = MoshSSPSendTimingConfiguration(
            sendIntervalMilliseconds: 20,
            acknowledgementIntervalMilliseconds: 1_000,
            activeRetryTimeoutMilliseconds: 10_000,
            sendMinimumDelayMilliseconds: 0,
            timeoutMilliseconds: 1_000
        )
        let fixture = try await makeSessionFixture(columns: 80, rows: 24, timing: timing)
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 2)
        var shutdownTask: Task<Void, Error>?

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            let initialSendWait = try await withSessionTimeout {
                await fixture.timer.nextSleepRequest()
            }
            #expect(initialSendWait == 20)
            await fixture.clock.advance(byMilliseconds: initialSendWait)
            let resumedInitialSend = await fixture.timer.resumeNextSleep(milliseconds: initialSendWait)
            try #require(resumedInitialSend)

            shutdownTask = Task {
                try await fixture.session.shutdown()
            }

            let shutdownSendWait = try await nextSleepRequest(
                from: fixture.timer,
                matching: 20
            )
            await fixture.clock.advance(byMilliseconds: shutdownSendWait)
            let resumedShutdownSend = await fixture.timer.resumeNextSleep(milliseconds: shutdownSendWait)
            try #require(resumedShutdownSend)

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let initialInstruction = try #require(serverInstructions.first)
            let shutdownInstruction = try #require(serverInstructions.last)

            #expect(initialInstruction.instructionResult.receiveResult == .accepted(newNumber: 1))
            #expect(shutdownInstruction.instructionResult.receiveResult == .accepted(newNumber: UInt64.max))
            #expect(shutdownInstruction.instructionResult.instruction.newNumber == UInt64.max)
            #expect(
                shutdownInstruction.instructionResult.latestState.state.operations == [
                    .resize(try MoshTerminalDimensions(columns: 80, rows: 24))
                ]
            )

            await fixture.clock.advance(byMilliseconds: MoshSSPSender<MoshTerminalHostState>.acknowledgementDelayMilliseconds)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            let shutdownTask = try #require(shutdownTask)
            try await withSessionTimeout {
                try await shutdownTask.value
            }
            await expectSessionError(.stopped) {
                try await fixture.session.sendKeystrokes([0x61])
            }

            await fixture.serverRuntime.stop()
        } catch {
            shutdownTask?.cancel()
            serverInstructionTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }
}

private struct MoshSessionFixture: Sendable {
    let endpoint: MoshEndpoint
    let session: MoshSession
    let serverRuntime: MoshSSPDatagramRuntime<MoshTerminalHostState, MoshTerminalClientState>
    let clock: ManualMillisecondsClock
    let timer: ManualSessionTimer
}

private actor ManualMillisecondsClock: MoshMillisecondsClock {
    private var nowMillisecondsStorage: UInt64 = 0

    func advance(byMilliseconds milliseconds: UInt64) {
        self.nowMillisecondsStorage += milliseconds
    }

    func nowMilliseconds() async -> UInt64 {
        self.nowMillisecondsStorage
    }
}

private actor ManualSessionTimer: MoshSessionTimer {
    private var nextSleepID = 0
    private var pendingSleepOrder: [Int] = []
    private var pendingSleepMilliseconds: [Int: UInt64] = [:]
    private var pendingSleepContinuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var cancelledSleepIDs: Set<Int> = []
    private var sleepRequests: [UInt64] = []
    private var sleepRequestWaiters: [CheckedContinuation<UInt64, Never>] = []

    func sleep(forMilliseconds milliseconds: UInt64) async throws {
        let sleepID = self.nextSleepID
        self.nextSleepID += 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.storeSleep(
                    id: sleepID,
                    milliseconds: milliseconds,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelSleep(id: sleepID)
            }
        }
    }

    func nextSleepRequest() async -> UInt64 {
        if self.sleepRequests.isEmpty == false {
            return self.sleepRequests.removeFirst()
        }

        return await withCheckedContinuation { continuation in
            self.sleepRequestWaiters.append(continuation)
        }
    }

    func resumeNextSleep() {
        guard self.pendingSleepOrder.isEmpty == false else {
            return
        }

        let sleepID = self.pendingSleepOrder.removeFirst()
        self.pendingSleepMilliseconds.removeValue(forKey: sleepID)
        self.pendingSleepContinuations.removeValue(forKey: sleepID)?.resume()
    }

    func resumeNextSleep(milliseconds: UInt64) -> Bool {
        guard let index = self.pendingSleepOrder.firstIndex(where: { sleepID in
            self.pendingSleepMilliseconds[sleepID] == milliseconds
        }) else {
            return false
        }

        let sleepID = self.pendingSleepOrder.remove(at: index)
        self.pendingSleepMilliseconds.removeValue(forKey: sleepID)
        self.pendingSleepContinuations.removeValue(forKey: sleepID)?.resume()
        return true
    }

    func pendingSleepCount() -> Int {
        self.pendingSleepContinuations.count
    }

    private func storeSleep(
        id: Int,
        milliseconds: UInt64,
        continuation: CheckedContinuation<Void, Error>
    ) {
        if self.cancelledSleepIDs.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }

        self.pendingSleepOrder.append(id)
        self.pendingSleepMilliseconds[id] = milliseconds
        self.pendingSleepContinuations[id] = continuation
        self.publishSleepRequest(milliseconds)
    }

    private func cancelSleep(id: Int) {
        if let continuation = self.pendingSleepContinuations.removeValue(forKey: id) {
            self.pendingSleepOrder.removeAll { $0 == id }
            self.pendingSleepMilliseconds.removeValue(forKey: id)
            continuation.resume(throwing: CancellationError())
        } else {
            self.cancelledSleepIDs.insert(id)
        }
    }

    private func publishSleepRequest(_ milliseconds: UInt64) {
        if self.sleepRequestWaiters.isEmpty == false {
            self.sleepRequestWaiters.removeFirst().resume(returning: milliseconds)
            return
        }

        self.sleepRequests.append(milliseconds)
    }
}

private struct FixedTransportFactory: MoshSessionTransportFactory {
    let link: MoshInMemoryDatagramLink

    func makeDatagramLink(for endpoint: MoshEndpoint) async throws -> any MoshDatagramLink {
        self.link
    }
}

private func makeSessionFixture(
    columns: Int32,
    rows: Int32,
    timing: MoshSSPSendTimingConfiguration = MoshSSPSendTimingConfiguration(
        sendIntervalMilliseconds: 0,
        acknowledgementIntervalMilliseconds: 1_000,
        activeRetryTimeoutMilliseconds: 10_000,
        sendMinimumDelayMilliseconds: 0,
        timeoutMilliseconds: 1_000,
        shutdownMaximumAttempts: 16
    )
) async throws -> MoshSessionFixture {
    let pair = await MoshInMemoryDatagramLink.connectedPair()
    let clock = ManualMillisecondsClock()
    let timer = ManualSessionTimer()
    let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
    let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
    let initialTerminalDimensions = try MoshTerminalDimensions(columns: columns, rows: rows)
    let session = MoshSession(
        configuration: MoshSessionConfiguration(
            endpoint: endpoint,
            initialTerminalDimensions: initialTerminalDimensions,
            transportFactory: FixedTransportFactory(link: pair.client),
            clock: clock,
            timer: timer,
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
        serverRuntime: serverRuntime,
        clock: clock,
        timer: timer
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

private func collectRenderOperations(
    from session: MoshSession,
    count: Int
) -> Task<[MoshTerminalRenderOperation], Error> {
    Task {
        var iterator = session.renderOperations.makeAsyncIterator()
        var operations: [MoshTerminalRenderOperation] = []
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

private func collectStreamFailure<Element: Sendable>(
    from stream: AsyncThrowingStream<Element, Error>
) -> Task<Error?, Never> {
    Task {
        var iterator = stream.makeAsyncIterator()
        do {
            while try await iterator.next() != nil {}
            return nil
        } catch {
            return error
        }
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

private func nextSleepRequest(
    from timer: ManualSessionTimer,
    matching expectedMilliseconds: UInt64
) async throws -> UInt64 {
    try await withSessionTimeout {
        while true {
            let milliseconds = await timer.nextSleepRequest()
            if milliseconds == expectedMilliseconds {
                return milliseconds
            }
        }
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
