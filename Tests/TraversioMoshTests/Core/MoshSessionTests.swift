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
                    .started(host: fixture.endpoint.host, port: fixture.endpoint.port),
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

    // A server-initiated shutdown (the server sends the shutdown-sentinel state
    // number) must be detected so the session finishes its host/render streams
    // cleanly and emits a distinguishable `.peerShutdown` event, rather than
    // hanging `hostOperations` consumers.
    @Test
    func serverInitiatedShutdownFinishesStreamsCleanly() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 1_000)
        let renderOperationTask = collectRenderOperations(from: fixture.session, count: 1_000)
        let diagnosticEventTask = collectEvents(from: fixture.session, count: 1_000)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            // The server initiates shutdown, sending the shutdown-sentinel state
            // number (`UInt64.max`) to the client.
            await fixture.serverRuntime.startShutdown()
            let shutdownBatch = try #require(try await fixture.serverRuntime.sendDueDatagrams())
            #expect(shutdownBatch.sspBatch.instruction.newNumber == UInt64.max)

            // Both terminal streams must complete (not hang). withSessionTimeout
            // turns a hang into a test failure.
            let hostOperations = try await withSessionTimeout {
                try await hostOperationTask.value
            }
            _ = try await withSessionTimeout {
                try await renderOperationTask.value
            }
            _ = hostOperations

            let diagnosticEvents = try await withSessionTimeout {
                await diagnosticEventTask.value
            }
            #expect(diagnosticEvents.contains(.peerShutdown))
            #expect(diagnosticEvents.last == .stopped)

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            hostOperationTask.cancel()
            renderOperationTask.cancel()
            diagnosticEventTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    // The session key must never ride the diagnostic event stream, and an endpoint
    // must redact its key in string/reflected forms.
    @Test
    func diagnosticEventsAndEndpointNeverExposeSessionKey() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)
        let diagnosticEventTask = collectEvents(from: fixture.session, count: 1_000)
        let encodedKey = fixture.endpoint.sessionKey.encodedRepresentation
        let rawKeyBytes = fixture.endpoint.sessionKey.rawBytes
        let rawKeyByteListForms = [
            rawKeyBytes.map(String.init).joined(separator: ", "),
            rawKeyBytes.map { String($0, radix: 16) }.joined(),
        ]

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()

            let diagnosticEvents = await diagnosticEventTask.value
            #expect(diagnosticEvents.isEmpty == false)

            for event in diagnosticEvents {
                for rendered in [String(describing: event), String(reflecting: event)] {
                    #expect(rendered.contains(encodedKey) == false)
                    for byteForm in rawKeyByteListForms {
                        #expect(rendered.contains(byteForm) == false)
                    }
                }
                // Beyond string rendering: the event must not carry a live
                // MoshSessionKey value at any depth, so a consumer can never hold
                // (or wipe) key material off the diagnostic stream.
                #expect(reflectedValueContainsSessionKey(event) == false)
            }

            // The endpoint itself redacts its key in both string forms.
            let endpointDescription = String(describing: fixture.endpoint)
            let endpointDebugDescription = String(reflecting: fixture.endpoint)
            #expect(endpointDescription.contains("<redacted>"))
            #expect(endpointDescription.contains(encodedKey) == false)
            #expect(endpointDebugDescription.contains(encodedKey) == false)
            for byteForm in rawKeyByteListForms {
                #expect(endpointDescription.contains(byteForm) == false)
                #expect(endpointDebugDescription.contains(byteForm) == false)
            }
        } catch {
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
    func rapidResizeThenKeystrokeAfterHostOutputReachesServer() async throws {
        let timing = MoshSSPSendTimingConfiguration(
            sendIntervalMilliseconds: 20,
            acknowledgementIntervalMilliseconds: 1_000,
            activeRetryTimeoutMilliseconds: 1_000,
            sendMinimumDelayMilliseconds: 0,
            timeoutMilliseconds: 50
        )
        let fixture = try await makeSessionFixture(columns: 80, rows: 24, timing: timing)
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 3)
        let renderOperationTask = collectRenderOperations(from: fixture.session, count: 1)
        let resizedDimensions = try MoshTerminalDimensions(columns: 100, rows: 30)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            let initialSendWait = try await withSessionTimeout {
                try await fixture.timer.nextSleepRequest()
            }
            #expect(initialSendWait == 20)
            await fixture.clock.advance(byMilliseconds: initialSendWait)
            await fixture.timer.resumeNextSleep()

            let idleWait = try await withSessionTimeout {
                try await fixture.timer.nextSleepRequest()
            }
            #expect(idleWait == 1_000)

            var hostState = MoshTerminalHostState()
            hostState.append(.write(MoshTerminalOutput(bytes: Array("READY".utf8))))
            await fixture.serverRuntime.setCurrentState(hostState)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            let renderOperations = try await withSessionTimeout {
                try await renderOperationTask.value
            }
            #expect(renderOperations == [.write(MoshTerminalOutput(bytes: Array("READY".utf8)))])

            await fixture.clock.advance(byMilliseconds: 20)
            try await fixture.session.resize(resizedDimensions)
            try await fixture.session.sendKeystrokes([UInt8(ascii: "q")])

            let delayedAckWait = try await withSessionTimeout {
                try await fixture.timer.nextSleepRequest()
            }
            #expect(delayedAckWait == 100)
            await fixture.clock.advance(byMilliseconds: delayedAckWait)
            await fixture.timer.resumeNextSleep()

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let finalState = try #require(serverInstructions.last).instructionResult.latestState.state

            #expect(
                finalState.operations == [
                    .resize(try MoshTerminalDimensions(columns: 80, rows: 24)),
                    .resize(resizedDimensions),
                    .keystrokes([UInt8(ascii: "q")]),
                ]
            )

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            serverInstructionTask.cancel()
            renderOperationTask.cancel()
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
                    .started(host: fixture.endpoint.host, port: fixture.endpoint.port),
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

    // A transient `link.send` failure during start (here every send fails) must
    // NOT tear the session down. This asserts defect-A send tolerance: official
    // Mosh's `Connection::send` records the error and returns, and the SSP
    // retransmit timer re-sends once connectivity returns. (Rewritten: this test
    // previously encoded the pre-fix behavior in which a `NWConnection.send` error
    // on a network transition killed the whole session.)
    @Test
    func transientSendFailureAtStartKeepsSessionAlive() async throws {
        let failingLink = FailingSendDatagramLink(sendError: .notConnected)
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                transportFactory: FailingSendTransportFactory(link: failingLink),
                timing: MoshSSPSendTimingConfiguration(
                    sendIntervalMilliseconds: 20,
                    acknowledgementIntervalMilliseconds: 1_000,
                    activeRetryTimeoutMilliseconds: 10_000,
                    sendMinimumDelayMilliseconds: 0,
                    timeoutMilliseconds: 1_000,
                    shutdownMaximumAttempts: 16
                ),
                chaffSource: .none
            )
        )
        let diagnosticEventTask = collectEvents(from: session, count: 2)

        do {
            // The initial resize send fails transiently, but start must succeed and
            // the session must stay alive.
            try await session.start()

            let diagnosticEvents = try await withSessionTimeout {
                await diagnosticEventTask.value
            }
            // The batch was still produced and accounted (SSP will retransmit); the
            // failure is recorded, not fatal.
            #expect(diagnosticEvents == [
                .started(host: endpoint.host, port: endpoint.port),
                .datagramsSent(packetCount: 1),
            ])

            // The session is not stopped: a further keystroke is accepted (it does
            // not throw `.stopped`), proving the session survived the send failure.
            try await session.sendKeystrokes([0x61])

            await session.stop()
        } catch {
            diagnosticEventTask.cancel()
            await session.stop()
            throw error
        }
    }

    // A transport (incoming stream) failure must NOT immediately finish the
    // session; it must drive the bounded automatic link-rebuild policy. When the
    // replacement links are unavailable (their `start` keeps failing), the session
    // reconnects up to the configured attempt limit and only then tears down.
    // (Rewritten: previously a single incoming failure finished the streams; that
    // is exactly the transport-death fragility defect B removes.)
    @Test
    func receiveFailureDrivesBoundedRebuildThenTearsDownWhenUnavailable() async throws {
        let incomingError = MoshDatagramTransportError.notConnected
        let initialLink = IncomingFailureDatagramLink()
        let factory = SequencedRebuildTransportFactory(
            initialLink: initialLink,
            rebuildError: .notConnected
        )
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                transportFactory: factory,
                chaffSource: .none,
                resilience: MoshSessionResilienceConfiguration(
                    maximumLinkRebuildAttempts: 2,
                    initialRebuildBackoffMilliseconds: 1,
                    maximumRebuildBackoffMilliseconds: 2
                )
            )
        )
        let hostFailureTask = collectStreamFailure(from: session.hostOperations)
        let renderFailureTask = collectStreamFailure(from: session.renderOperations)
        let diagnosticEventTask = collectEvents(from: session, count: 5)

        do {
            try await session.start()
            try await Task.sleep(for: .milliseconds(10))
            await initialLink.failIncoming(throwing: incomingError)

            let hostFailure = try await withSessionTimeout {
                await hostFailureTask.value
            }
            let renderFailure = try await withSessionTimeout {
                await renderFailureTask.value
            }
            let diagnosticEvents = try await withSessionTimeout {
                await diagnosticEventTask.value
            }

            // The two bounded rebuild attempts are surfaced before teardown.
            #expect(diagnosticEvents.contains(.reconnecting(attempt: 1)))
            #expect(diagnosticEvents.contains(.reconnecting(attempt: 2)))
            #expect(diagnosticEvents.last == .stopped)
            // Both attempts asked the factory for a fresh link.
            #expect(await factory.rebuildRequestCount() == 2)
            // Streams finish with the exhausting error.
            #expect((hostFailure as? MoshDatagramTransportError) == .notConnected)
            #expect((renderFailure as? MoshDatagramTransportError) == .notConnected)
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

    // A transient `link.send` failure while sending a keystroke must NOT throw out
    // of `sendKeystrokes` or tear the session down. (Rewritten: previously this
    // asserted the pre-fix behavior that such a send error finished the streams and
    // stopped the runtime.)
    @Test
    func transientSendFailureDuringKeystrokesKeepsSessionAlive() async throws {
        let sendError = MoshDatagramTransportError.notConnected
        let link = FailingAfterSendDatagramLink(failOnSendNumber: 2, sendError: sendError)
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                transportFactory: FailingAfterSendTransportFactory(link: link),
                timing: MoshSSPSendTimingConfiguration(
                    sendIntervalMilliseconds: 20,
                    acknowledgementIntervalMilliseconds: 1_000,
                    activeRetryTimeoutMilliseconds: 10_000,
                    sendMinimumDelayMilliseconds: 0,
                    timeoutMilliseconds: 1_000,
                    shutdownMaximumAttempts: 16
                ),
                chaffSource: .none
            )
        )
        let diagnosticEventTask = collectEvents(from: session, count: 2)

        do {
            try await session.start()

            // The second send (this keystroke) fails at the link; it must be
            // recorded and swallowed, not thrown.
            try await session.sendKeystrokes([0x61])

            let diagnosticEvents = try await withSessionTimeout {
                await diagnosticEventTask.value
            }
            #expect(diagnosticEvents.first == .started(host: endpoint.host, port: endpoint.port))
            // No `.stopped` yet: the session survived the failed keystroke send.
            #expect(diagnosticEvents.contains(.stopped) == false)

            // Still usable.
            try await session.sendKeystrokes([0x62])

            await session.stop()
        } catch {
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

            #expect(diagnosticEvents == [.started(host: fixture.endpoint.host, port: fixture.endpoint.port), .stopped])
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
                .started(host: fixture.endpoint.host, port: fixture.endpoint.port),
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

    // Defect D: the host-visible liveness API reports last-heard and round-trip
    // estimates and updates as datagrams arrive; crossing the no-contact threshold
    // emits a single informational `.noContact` diagnostic without tearing the
    // session down.
    @Test
    func livenessReportsLastHeardAndEmitsNoContactAfterThreshold() async throws {
        let timing = MoshSSPSendTimingConfiguration(
            sendIntervalMilliseconds: 0,
            acknowledgementIntervalMilliseconds: 1_000,
            sendMinimumDelayMilliseconds: 0
        )
        let fixture = try await makeSessionFixture(
            columns: 80,
            rows: 24,
            timing: timing,
            resilience: MoshSessionResilienceConfiguration(noContactThresholdMilliseconds: 5_000)
        )
        let hostOperationTask = collectHostOperations(from: fixture.session, count: 1)
        let noContactEventTask = Task<MoshSessionEvent?, Never> {
            for await event in fixture.session.diagnosticEvents {
                if case .noContact = event {
                    return event
                }
                if event == .stopped {
                    return nil
                }
            }
            return nil
        }

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            // Before any contact, liveness reports never-heard.
            let initialLiveness = await fixture.session.liveness
            #expect(initialLiveness.lastHeardFromServerMilliseconds == nil)

            // Server sends a state at clock 0; the client hears it.
            var hostState = MoshTerminalHostState()
            hostState.append(.write(MoshTerminalOutput(bytes: [0x48])))
            await fixture.serverRuntime.setCurrentState(hostState)
            _ = try await fixture.serverRuntime.sendDueDatagrams()
            _ = try await withSessionTimeout {
                try await hostOperationTask.value
            }

            // Liveness now reflects the contact at clock 0.
            let heardLiveness = await fixture.session.liveness
            #expect(heardLiveness.lastHeardFromServerMilliseconds == 0)
            #expect(heardLiveness.millisecondsSinceLastHeard == 0)
            #expect(heardLiveness.smoothedRoundTripMilliseconds >= 0)

            // Advance well past the no-contact threshold with no further contact and
            // pump the maintenance loop; it must emit `.noContact`.
            await fixture.clock.advance(byMilliseconds: 6_000)
            for _ in 0..<4 {
                await fixture.timer.resumeNextSleep()
                _ = try? await withSessionTimeout(after: .seconds(1)) {
                    try await fixture.timer.nextSleepRequest()
                }
            }

            let noContactEvent = try await withSessionTimeout {
                await noContactEventTask.value
            }
            #expect(noContactEvent == .noContact(millisecondsSinceLastHeard: 6_000))

            // Liveness now reports the elapsed no-contact interval, and the session
            // is still alive (a keystroke is accepted).
            let staleLiveness = await fixture.session.liveness
            #expect(staleLiveness.lastHeardFromServerMilliseconds == 0)
            #expect(staleLiveness.millisecondsSinceLastHeard == 6_000)
            try await fixture.session.sendKeystrokes([0x61])

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            hostOperationTask.cancel()
            noContactEventTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    // Defect 2 at the session layer: a momentary backward clock skew across two send
    // paths must not tear the session down. A user keystroke reads the clock behind an
    // `await` and feeds it to the SSP loop; if that read momentarily returns a value
    // below the last-applied send time (actor-reentrancy / clock-read skew), the sender's
    // clock-moved-backward guard fired on the ungenerationed user-send path and finished
    // the streams. The runtime now clamps the applied time to be monotonic, so the send
    // succeeds and the session stays alive and usable. (Pre-fix, the second
    // `sendKeystrokes` threw `clockMovedBackward` and the session stopped.)
    @Test
    func backwardClockSkewOnUserSendKeepsSessionAlive() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)
        let serverInstructionTask = collectServerInstructions(from: fixture.serverRuntime, count: 3)

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            // First keystroke lands at clock 100, fixing the sender's last-sent time.
            await fixture.clock.set(toMilliseconds: 100)
            try await fixture.session.sendKeystrokes([0x61])

            // The clock momentarily steps backward to 99. The user-send path applies it
            // to the SSP loop; without the monotonic clamp this violated `now >=
            // lastSentAt(100)` and tore the session down.
            await fixture.clock.set(toMilliseconds: 99)
            try await fixture.session.sendKeystrokes([0x62])

            // The session survived and both keystrokes reached the server in order.
            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let finalState = try #require(serverInstructions.last).instructionResult.latestState.state
            #expect(
                finalState.operations == [
                    .resize(try MoshTerminalDimensions(columns: 80, rows: 24)),
                    .keystrokes([0x61]),
                    .keystrokes([0x62]),
                ]
            )

            // Still usable: time recovers and a further keystroke is accepted.
            await fixture.clock.set(toMilliseconds: 200)
            try await fixture.session.sendKeystrokes([0x63])

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            serverInstructionTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    // Defect B at the session layer: an automatic link rebuild after a transport
    // failure resumes the SAME session on a fresh link and surfaces `.reconnected`.
    @Test
    func linkFailureAutomaticallyReconnectsOnFreshLink() async throws {
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let firstLink = IncomingFailureDatagramLink()
        let secondLink = MoshInMemoryDatagramLink()
        try await secondLink.start()
        let factory = ReconnectingTransportFactory(links: [firstLink, secondLink])
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                transportFactory: factory,
                chaffSource: .none,
                resilience: MoshSessionResilienceConfiguration(
                    maximumLinkRebuildAttempts: 4,
                    initialRebuildBackoffMilliseconds: 1,
                    maximumRebuildBackoffMilliseconds: 2
                )
            )
        )
        let reconnectedEventTask = Task<Bool, Never> {
            for await event in session.diagnosticEvents {
                if event == .reconnected {
                    return true
                }
                if event == .stopped {
                    return false
                }
            }
            return false
        }

        do {
            try await session.start()
            try await Task.sleep(for: .milliseconds(10))
            await firstLink.failIncoming(throwing: MoshDatagramTransportError.notConnected)

            let reconnected = try await withSessionTimeout {
                await reconnectedEventTask.value
            }
            #expect(reconnected)
            // The session is alive on the new link: a keystroke is accepted.
            try await session.sendKeystrokes([0x61])

            await session.stop()
        } catch {
            reconnectedEventTask.cancel()
            await session.stop()
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

    /// Sets the clock to an absolute value, which may be LOWER than the current value
    /// so a test can construct a momentary backward clock skew.
    func set(toMilliseconds milliseconds: UInt64) {
        self.nowMillisecondsStorage = milliseconds
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

private struct FailingAfterSendTransportFactory: MoshSessionTransportFactory {
    let link: FailingAfterSendDatagramLink

    func makeDatagramLink(for endpoint: MoshEndpoint) async throws -> any MoshDatagramLink {
        self.link
    }
}

/// Vends the given initial link once, then vends `StartFailingDatagramLink`s for
/// every subsequent rebuild request, so a bounded rebuild loop is exercised and
/// eventually exhausts.
private actor SequencedRebuildTransportFactory: MoshSessionTransportFactory {
    private let initialLink: IncomingFailureDatagramLink
    private let rebuildError: MoshDatagramTransportError
    private var hasVendedInitial = false
    private var rebuildRequestCountStorage = 0

    init(initialLink: IncomingFailureDatagramLink, rebuildError: MoshDatagramTransportError) {
        self.initialLink = initialLink
        self.rebuildError = rebuildError
    }

    func makeDatagramLink(for endpoint: MoshEndpoint) async throws -> any MoshDatagramLink {
        if self.hasVendedInitial == false {
            self.hasVendedInitial = true
            return self.initialLink
        }
        self.rebuildRequestCountStorage += 1
        return StartFailingDatagramLink(startError: self.rebuildError)
    }

    func rebuildRequestCount() -> Int {
        self.rebuildRequestCountStorage
    }
}

/// Vends a fixed sequence of links: the first for `start()`, the rest for each
/// subsequent rebuild request.
private actor ReconnectingTransportFactory: MoshSessionTransportFactory {
    private var links: [any MoshDatagramLink]

    init(links: [any MoshDatagramLink]) {
        self.links = links
    }

    func makeDatagramLink(for endpoint: MoshEndpoint) async throws -> any MoshDatagramLink {
        guard self.links.isEmpty == false else {
            throw MoshDatagramTransportError.notConnected
        }
        return self.links.removeFirst()
    }
}

private actor StartFailingDatagramLink: MoshDatagramLink {
    nonisolated let incomingDatagrams: MoshDatagramStream

    private let incomingContinuation: MoshDatagramStream.Continuation
    private let startError: MoshDatagramTransportError

    init(startError: MoshDatagramTransportError) {
        self.startError = startError
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

    func start() async throws {
        throw self.startError
    }

    func send(_ datagram: [UInt8]) async throws {
        _ = datagram
    }

    func stop() async {
        self.incomingContinuation.finish()
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

private actor FailingAfterSendDatagramLink: MoshDatagramLink {
    nonisolated let incomingDatagrams: MoshDatagramStream

    private let continuation: MoshDatagramStream.Continuation
    private let failOnSendNumber: Int
    private let sendError: MoshDatagramTransportError
    private var sendCountStorage = 0
    private var stopCountStorage = 0

    init(failOnSendNumber: Int, sendError: MoshDatagramTransportError) {
        var capturedContinuation: MoshDatagramStream.Continuation?
        let stream = MoshDatagramStream { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }
        self.incomingDatagrams = stream
        self.continuation = capturedContinuation
        self.failOnSendNumber = failOnSendNumber
        self.sendError = sendError
    }

    func start() async throws {}

    func send(_ datagram: [UInt8]) async throws {
        _ = datagram
        self.sendCountStorage += 1
        if self.sendCountStorage >= self.failOnSendNumber {
            throw self.sendError
        }
    }

    func stop() async {
        self.stopCountStorage += 1
        self.continuation.finish()
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
    predictionConfiguration: MoshPredictionConfiguration = MoshPredictionConfiguration(),
    resilience: MoshSessionResilienceConfiguration = MoshSessionResilienceConfiguration()
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
            predictionConfiguration: predictionConfiguration,
            resilience: resilience
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

/// Recursively walks a value's reflection to detect whether any child (at any
/// depth) is a `MoshSessionKey`. Used to prove a diagnostic event does not carry
/// key material as a live value.
private func reflectedValueContainsSessionKey(_ value: Any, depth: Int = 0) -> Bool {
    if value is MoshSessionKey {
        return true
    }
    guard depth < 8 else {
        return false
    }
    for child in Mirror(reflecting: value).children {
        if reflectedValueContainsSessionKey(child.value, depth: depth + 1) {
            return true
        }
    }
    return false
}
