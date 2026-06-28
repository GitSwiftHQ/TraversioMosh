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
    func localPredictionDisplaysTypeaheadAfterServerEchoConfirmsEpoch() async throws {
        let fixture = try await makeSessionFixture(
            columns: 4,
            rows: 1,
            predictionConfiguration: MoshPredictionConfiguration(displayPreference: .always)
        )
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 2)
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 2)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            try await fixture.session.sendKeystrokes(Array("a".utf8))

            #expect(await fixture.session.screenSnapshot.lineStrings == ["    "])

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let serverState = try #require(serverInstructions.last).instructionResult.latestState.state
            #expect(
                serverState.operations == [
                    .resize(try MoshTerminalDimensions(columns: 4, rows: 1)),
                    .keystrokes(Array("a".utf8)),
                ]
            )

            var hostState = MoshTerminalHostState()
            hostState.append(.write(MoshTerminalOutput(bytes: Array("a".utf8))))
            hostState.append(.echoAcknowledgement(2))
            await fixture.serverRuntime.setCurrentState(hostState)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            let hostOperations = try await withSessionTimeout {
                try await hostOperationTask.value
            }
            #expect(hostOperations == [
                .write(MoshTerminalOutput(bytes: Array("a".utf8))),
                .echoAcknowledgement(2),
            ])
            #expect(await fixture.session.screenSnapshot.lineStrings == ["a   "])

            try await fixture.session.sendKeystrokes(Array("b".utf8))

            #expect(await fixture.session.screenSnapshot.lineStrings == ["ab  "])

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
    func adaptivePredictionDisplaysDelayedPendingTypeaheadWithGlitchUnderline() async throws {
        let fixture = try await makeSessionFixture(
            columns: 4,
            rows: 1,
            predictionConfiguration: MoshPredictionConfiguration(displayPreference: .adaptive)
        )
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 2)
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 2)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            try await fixture.session.sendKeystrokes(Array("a".utf8))

            #expect(await fixture.session.screenSnapshot.lineStrings == ["    "])

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let serverState = try #require(serverInstructions.last).instructionResult.latestState.state
            #expect(
                serverState.operations == [
                    .resize(try MoshTerminalDimensions(columns: 4, rows: 1)),
                    .keystrokes(Array("a".utf8)),
                ]
            )

            var hostState = MoshTerminalHostState()
            hostState.append(.write(MoshTerminalOutput(bytes: Array("a".utf8))))
            hostState.append(.echoAcknowledgement(2))
            await fixture.serverRuntime.setCurrentState(hostState)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            _ = try await withSessionTimeout {
                try await hostOperationTask.value
            }
            #expect(await fixture.session.screenSnapshot.lineStrings == ["a   "])

            try await fixture.session.sendKeystrokes(Array("b".utf8))
            #expect(await fixture.session.screenSnapshot.lineStrings == ["a   "])

            await fixture.clock.advance(byMilliseconds: 249)
            #expect(await fixture.session.screenSnapshot.lineStrings == ["a   "])

            await fixture.clock.advance(byMilliseconds: 1)
            let delayedSnapshot = await fixture.session.screenSnapshot
            #expect(delayedSnapshot.lineStrings == ["ab  "])
            #expect(delayedSnapshot.rows[0][1].attributes.isUnderlined == false)

            await fixture.clock.advance(byMilliseconds: 4_750)
            let underlinedSnapshot = await fixture.session.screenSnapshot
            #expect(underlinedSnapshot.lineStrings == ["ab  "])
            #expect(underlinedSnapshot.rows[0][1].attributes.isUnderlined == true)

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
    func disabledPredictionKeepsScreenAtConfirmedHostState() async throws {
        let fixture = try await makeSessionFixture(
            columns: 4,
            rows: 1,
            predictionConfiguration: MoshPredictionConfiguration(displayPreference: .never)
        )
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 2)
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 2)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            try await fixture.session.sendKeystrokes(Array("a".utf8))

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let serverState = try #require(serverInstructions.last).instructionResult.latestState.state
            #expect(
                serverState.operations == [
                    .resize(try MoshTerminalDimensions(columns: 4, rows: 1)),
                    .keystrokes(Array("a".utf8)),
                ]
            )

            var hostState = MoshTerminalHostState()
            hostState.append(.write(MoshTerminalOutput(bytes: Array("a".utf8))))
            hostState.append(.echoAcknowledgement(2))
            await fixture.serverRuntime.setCurrentState(hostState)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            _ = try await withSessionTimeout {
                try await hostOperationTask.value
            }

            try await fixture.session.sendKeystrokes(Array("b".utf8))

            #expect(await fixture.session.screenSnapshot.lineStrings == ["a   "])

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
    func localPredictionDoesNotRenderUnsupportedEscapeFinalAsPrintable() async throws {
        let fixture = try await makeSessionFixture(
            columns: 4,
            rows: 1,
            predictionConfiguration: MoshPredictionConfiguration(displayPreference: .always)
        )
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 2)
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 2)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            try await fixture.session.sendKeystrokes(Array("a".utf8))

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let serverState = try #require(serverInstructions.last).instructionResult.latestState.state
            #expect(
                serverState.operations == [
                    .resize(try MoshTerminalDimensions(columns: 4, rows: 1)),
                    .keystrokes(Array("a".utf8)),
                ]
            )

            var hostState = MoshTerminalHostState()
            hostState.append(.write(MoshTerminalOutput(bytes: Array("a".utf8))))
            hostState.append(.echoAcknowledgement(2))
            await fixture.serverRuntime.setCurrentState(hostState)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            _ = try await withSessionTimeout {
                try await hostOperationTask.value
            }
            #expect(await fixture.session.screenSnapshot.lineStrings == ["a   "])

            try await fixture.session.sendKeystrokes([0x1b, UInt8(ascii: "x")])

            #expect(await fixture.session.screenSnapshot.lineStrings == ["a   "])

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
    func terminalGeneratedRepliesAreSentAsClientKeystrokes() async throws {
        let fixture = try await makeSessionFixture(columns: 4, rows: 2)
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 2)
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 1)
        let hostOutput = MoshHostOperation.write(
            MoshTerminalOutput(bytes: Array("AB\u{1b}[6n".utf8))
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
            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let finalClientState = try #require(serverInstructions.last).instructionResult.latestState.state
            let screenSnapshot = await fixture.session.screenSnapshot

            #expect(hostOperations == [hostOutput])
            #expect(finalClientState.operations == [
                .resize(try MoshTerminalDimensions(columns: 4, rows: 2)),
                .keystrokes(Array("\u{1b}[1;3R".utf8)),
            ])
            #expect(screenSnapshot.lineStrings == ["AB  ", "    "])
            #expect(screenSnapshot.cursor == MoshTerminalCursor(row: 0, column: 2))

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
    func invalidUTF8HostOutputUsesReplacementWithoutProjectionFailure() async throws {
        let fixture = try await makeSessionFixture(columns: 3, rows: 2)
        let diagnosticEventTask = collectEvents(from: fixture.session, count: 2)
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 1)
        let renderOperationTask = collectRenderOperations(from: fixture.session, count: 1)
        let invalidOutput = MoshTerminalOutput(bytes: [0xff, 0x58])
        let hostOperation = MoshHostOperation.write(invalidOutput)

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
            let hostOperations = try await withSessionTimeout {
                try await hostOperationTask.value
            }
            let renderOperations = try await withSessionTimeout {
                try await renderOperationTask.value
            }

            #expect(
                diagnosticEvents == [
                    .started(fixture.endpoint),
                    .datagramsSent(packetCount: 1),
                ]
            )
            #expect(hostOperations == [hostOperation])
            #expect(renderOperations == [.write(invalidOutput)])
            #expect(await fixture.session.screenSnapshot.lineStrings == ["\u{fffd}X ", "   "])

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            diagnosticEventTask.cancel()
            hostOperationTask.cancel()
            renderOperationTask.cancel()
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
    func startFailureAfterRuntimeStartStopsSessionAndFinishesStreams() async throws {
        let failingLink = FailingSendDatagramLink(sendError: .notConnected)
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                transportFactory: FailingSendTransportFactory(link: failingLink),
                timing: MoshSSPSendTimingConfiguration(
                    sendIntervalMilliseconds: 0,
                    acknowledgementIntervalMilliseconds: 1_000,
                    activeRetryTimeoutMilliseconds: 10_000,
                    sendMinimumDelayMilliseconds: 0,
                    timeoutMilliseconds: 1_000,
                    shutdownMaximumAttempts: 16
                ),
                chaffSource: .none
            )
        )
        let hostFailureTask = collectStreamFailure(from: session.hostOperations)
        let renderFailureTask = collectStreamFailure(from: session.renderOperations)
        let diagnosticEventTask = collectEvents(from: session, count: 2)

        do {
            try await session.start()
            Issue.record("Expected start to fail after the datagram link rejected send.")
        } catch let error as MoshDatagramTransportError {
            #expect(error == .notConnected)
        } catch {
            Issue.record("Expected MoshDatagramTransportError.notConnected, received \(error).")
        }

        let diagnosticEvents = try await withSessionTimeout {
            await diagnosticEventTask.value
        }
        let hostFailure = try await withSessionTimeout {
            await hostFailureTask.value
        }
        let renderFailure = try await withSessionTimeout {
            await renderFailureTask.value
        }

        #expect(diagnosticEvents == [.started(endpoint), .stopped])
        #expect((hostFailure as? MoshDatagramTransportError) == .notConnected)
        #expect((renderFailure as? MoshDatagramTransportError) == .notConnected)
        #expect(await failingLink.stopCount() == 1)
        await expectSessionError(.stopped) {
            try await session.sendKeystrokes([0x61])
        }
    }

    @Test
    func receiveTaskFailureStopsRuntimeAndFinishesStreams() async throws {
        let incomingError = MoshDatagramTransportError.notConnected
        let link = IncomingFailureDatagramLink()
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                transportFactory: IncomingFailureTransportFactory(link: link),
                chaffSource: .none
            )
        )
        let hostFailureTask = collectStreamFailure(from: session.hostOperations)
        let renderFailureTask = collectStreamFailure(from: session.renderOperations)
        let diagnosticEventTask = collectEvents(from: session, count: 2)

        do {
            try await session.start()
            try await Task.sleep(for: .milliseconds(10))
            await link.failIncoming(throwing: incomingError)

            let hostFailure = try await withSessionTimeout {
                await hostFailureTask.value
            }
            let renderFailure = try await withSessionTimeout {
                await renderFailureTask.value
            }
            let diagnosticEvents = try await withSessionTimeout {
                await diagnosticEventTask.value
            }

            #expect((hostFailure as? MoshDatagramTransportError) == incomingError)
            #expect((renderFailure as? MoshDatagramTransportError) == incomingError)
            #expect(
                diagnosticEvents == [
                    .started(endpoint),
                    .stopped,
                ]
            )
            #expect(await link.stopCount() == 1)
            await expectSessionError(.stopped) {
                try await session.sendKeystrokes([0x61])
            }
        } catch {
            hostFailureTask.cancel()
            renderFailureTask.cancel()
            diagnosticEventTask.cancel()
            await session.stop()
            throw error
        }
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
                try await fixture.timer.nextSleepRequest()
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
                try await fixture.timer.nextSleepRequest()
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
                try await fixture.timer.nextSleepRequest()
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
                try await fixture.timer.nextSleepRequest()
            }
            #expect(initialWait == 20)
            await fixture.clock.advance(byMilliseconds: initialWait)
            await fixture.timer.resumeNextSleep()

            let postInitialWait = try await withSessionTimeout {
                try await fixture.timer.nextSleepRequest()
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
                try await fixture.timer.nextSleepRequest()
            }
            #expect(delayedAckWait == 100)

            try await fixture.session.sendKeystrokes([0x61])

            let keystrokeWait = try await withSessionTimeout {
                try await fixture.timer.nextSleepRequest()
            }
            #expect(keystrokeWait == 20)
            await fixture.clock.advance(byMilliseconds: keystrokeWait)
            await fixture.timer.resumeNextSleep()

            let activeRetryWait = try await withSessionTimeout {
                try await fixture.timer.nextSleepRequest()
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
                try await fixture.timer.nextSleepRequest()
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
        let initialInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 1)
        var shutdownInstructionTask: Task<[MoshSSPDatagramIncomingInstruction<MoshTerminalClientState>], Error>?
        var shutdownTask: Task<Void, Error>?

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            let initialSendWait = try await withSessionTimeout {
                try await fixture.timer.nextSleepRequest()
            }
            #expect(initialSendWait == 20)
            await fixture.clock.advance(byMilliseconds: initialSendWait)
            let resumedInitialSend = await fixture.timer.resumeNextSleep(milliseconds: initialSendWait)
            try #require(resumedInitialSend)

            let initialInstructions = try await withSessionTimeout {
                try await initialInstructionTask.value
            }
            let initialInstruction = try #require(initialInstructions.first)
            #expect(initialInstruction.instructionResult.receiveResult == .accepted(newNumber: 1))

            shutdownInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 1)
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

            let shutdownInstructionTask = try #require(shutdownInstructionTask)
            let shutdownInstructions = try await withSessionTimeout {
                try await shutdownInstructionTask.value
            }
            let shutdownInstruction = try #require(shutdownInstructions.first)

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
            initialInstructionTask.cancel()
            shutdownInstructionTask?.cancel()
            shutdownTask?.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    @Test
    func cancelledShutdownWaiterLeavesSessionRunningUntilExplicitStop() async throws {
        let timing = MoshSSPSendTimingConfiguration(
            sendIntervalMilliseconds: 20,
            acknowledgementIntervalMilliseconds: 1_000,
            activeRetryTimeoutMilliseconds: 10_000,
            sendMinimumDelayMilliseconds: 0,
            timeoutMilliseconds: 1_000
        )
        let fixture = try await makeSessionFixture(columns: 80, rows: 24, timing: timing)
        let initialInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 1)
        let hostCompletionTask = collectStreamFailure(from: fixture.session.hostOperations)
        let renderCompletionTask = collectStreamFailure(from: fixture.session.renderOperations)
        let diagnosticEventTask = collectEvents(from: fixture.session, count: 4)
        var shutdownInstructionTask: Task<[MoshSSPDatagramIncomingInstruction<MoshTerminalClientState>], Error>?
        var shutdownTask: Task<Void, Error>?

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            let initialSendWait = try await withSessionTimeout {
                try await fixture.timer.nextSleepRequest()
            }
            #expect(initialSendWait == 20)
            await fixture.clock.advance(byMilliseconds: initialSendWait)
            let resumedInitialSend = await fixture.timer.resumeNextSleep(milliseconds: initialSendWait)
            try #require(resumedInitialSend)

            let initialInstructions = try await withSessionTimeout {
                try await initialInstructionTask.value
            }
            let initialInstruction = try #require(initialInstructions.first)
            #expect(initialInstruction.instructionResult.receiveResult == .accepted(newNumber: 1))

            shutdownInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 1)
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

            let shutdownInstructionTask = try #require(shutdownInstructionTask)
            let shutdownInstructions = try await withSessionTimeout {
                try await shutdownInstructionTask.value
            }
            let shutdownInstruction = try #require(shutdownInstructions.first)
            #expect(shutdownInstruction.instructionResult.receiveResult == .accepted(newNumber: UInt64.max))

            let shutdownTask = try #require(shutdownTask)
            shutdownTask.cancel()
            do {
                try await withSessionTimeout {
                    try await shutdownTask.value
                }
                Issue.record("Expected cancelled shutdown to throw CancellationError.")
            } catch is CancellationError {
            } catch {
                Issue.record("Expected CancellationError from cancelled shutdown, received \(error).")
            }

            await fixture.session.stop()

            let diagnosticEvents = try await withSessionTimeout {
                await diagnosticEventTask.value
            }
            let hostCompletion = try await withSessionTimeout {
                await hostCompletionTask.value
            }
            let renderCompletion = try await withSessionTimeout {
                await renderCompletionTask.value
            }

            #expect(diagnosticEvents == [
                .started(fixture.endpoint),
                .datagramsSent(packetCount: 1),
                .datagramsSent(packetCount: 1),
                .stopped,
            ])
            #expect(hostCompletion == nil)
            #expect(renderCompletion == nil)
            #expect(await fixture.timer.pendingSleepCount() == 0)
            await expectSessionError(.stopped) {
                try await fixture.session.sendKeystrokes([0x61])
            }

            await fixture.serverRuntime.stop()
        } catch {
            initialInstructionTask.cancel()
            shutdownInstructionTask?.cancel()
            shutdownTask?.cancel()
            hostCompletionTask.cancel()
            renderCompletionTask.cancel()
            diagnosticEventTask.cancel()
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
    private var nextSleepRequestWaiterID = 0
    private var pendingSleepOrder: [Int] = []
    private var pendingSleepMilliseconds: [Int: UInt64] = [:]
    private var pendingSleepContinuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var cancelledSleepIDs: Set<Int> = []
    private var sleepRequests: [UInt64] = []
    private var sleepRequestWaiters: [(id: Int, continuation: CheckedContinuation<UInt64, Error>)] = []
    private var cancelledSleepRequestWaiterIDs: Set<Int> = []

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

    func nextSleepRequest() async throws -> UInt64 {
        if self.sleepRequests.isEmpty == false {
            return self.sleepRequests.removeFirst()
        }

        let waiterID = self.nextSleepRequestWaiterID
        self.nextSleepRequestWaiterID += 1

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.storeSleepRequestWaiter(id: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task {
                await self.cancelSleepRequestWaiter(id: waiterID)
            }
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

    private func storeSleepRequestWaiter(
        id: Int,
        continuation: CheckedContinuation<UInt64, Error>
    ) {
        if self.sleepRequests.isEmpty == false {
            continuation.resume(returning: self.sleepRequests.removeFirst())
            return
        }

        if self.cancelledSleepRequestWaiterIDs.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }

        self.sleepRequestWaiters.append((id: id, continuation: continuation))
    }

    private func cancelSleepRequestWaiter(id: Int) {
        guard let index = self.sleepRequestWaiters.firstIndex(where: { $0.id == id }) else {
            self.cancelledSleepRequestWaiterIDs.insert(id)
            return
        }

        let waiter = self.sleepRequestWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func publishSleepRequest(_ milliseconds: UInt64) {
        if self.sleepRequestWaiters.isEmpty == false {
            self.sleepRequestWaiters.removeFirst().continuation.resume(returning: milliseconds)
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

private struct FailingSendTransportFactory: MoshSessionTransportFactory {
    let link: FailingSendDatagramLink

    func makeDatagramLink(for endpoint: MoshEndpoint) async throws -> any MoshDatagramLink {
        self.link
    }
}

private struct IncomingFailureTransportFactory: MoshSessionTransportFactory {
    let link: IncomingFailureDatagramLink

    func makeDatagramLink(for endpoint: MoshEndpoint) async throws -> any MoshDatagramLink {
        self.link
    }
}

private actor FailingSendDatagramLink: MoshDatagramLink {
    nonisolated let incomingDatagrams: MoshDatagramStream

    private let incomingContinuation: MoshDatagramStream.Continuation
    private let sendError: MoshDatagramTransportError
    private var stopCountStorage = 0

    init(sendError: MoshDatagramTransportError) {
        self.sendError = sendError
        var capturedContinuation: MoshDatagramStream.Continuation?
        self.incomingDatagrams = MoshDatagramStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }
        self.incomingContinuation = capturedContinuation
    }

    func start() async throws {}

    func send(_ datagram: [UInt8]) async throws {
        throw self.sendError
    }

    func stop() async {
        self.stopCountStorage += 1
        self.incomingContinuation.finish()
    }

    func stopCount() -> Int {
        self.stopCountStorage
    }
}

private actor IncomingFailureDatagramLink: MoshDatagramLink {
    nonisolated let incomingDatagrams: MoshDatagramStream

    private let incomingContinuation: MoshDatagramStream.Continuation
    private var stopCountStorage = 0

    init() {
        var capturedContinuation: MoshDatagramStream.Continuation?
        self.incomingDatagrams = MoshDatagramStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }
        self.incomingContinuation = capturedContinuation
    }

    func start() async throws {}

    func send(_ datagram: [UInt8]) async throws {
        _ = datagram
    }

    func stop() async {
        self.stopCountStorage += 1
        self.incomingContinuation.finish()
    }

    func failIncoming(throwing error: Error) {
        self.incomingContinuation.finish(throwing: error)
    }

    func stopCount() -> Int {
        self.stopCountStorage
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
    ),
    predictionConfiguration: MoshPredictionConfiguration = MoshPredictionConfiguration()
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
            chaffSource: .none,
            predictionConfiguration: predictionConfiguration
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
            let milliseconds = try await timer.nextSleepRequest()
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
