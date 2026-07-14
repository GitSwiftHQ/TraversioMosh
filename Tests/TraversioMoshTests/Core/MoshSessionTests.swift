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

    // Behavior C: a host diff carrying a terminal query (here a DSR cursor-position
    // request, `ESC [ 6 n`) generates a reply on the client emulator, but the reply
    // is captured for observability ONLY and is NEVER transmitted. Official parity:
    // the server-side emulator answers such queries; `Complete::apply_string`
    // asserts the client produced none. Transmitting them would inject duplicate
    // bytes whenever a re-based diff re-applies the query and would hand a hostile
    // server a keystroke-injection channel. (Pre-behavior-C this test asserted the
    // reply WAS sent as a client keystroke.)
    @Test
    func terminalGeneratedRepliesAreCapturedButNeverTransmitted() async throws {
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

            // A genuine keystroke follows the DSR-bearing host output. If the
            // terminal reply were transmitted it would ride ahead of this keystroke
            // as an extra client operation, so asserting the server's operations are
            // exactly [resize, keystroke] (with no reply between them) pins that the
            // reply was never enqueued for transmission.
            try await fixture.session.sendKeystrokes([UInt8(ascii: "q")])

            let serverInstructions = try await withSessionTimeout {
                try await serverInstructionTask.value
            }
            let finalClientState = try #require(serverInstructions.last).instructionResult.latestState.state
            let screenSnapshot = await fixture.session.screenSnapshot

            #expect(hostOperations == [hostOutput])
            #expect(finalClientState.operations == [
                .resize(try MoshTerminalDimensions(columns: 4, rows: 2)),
                .keystrokes([UInt8(ascii: "q")]),
            ])
            #expect(screenSnapshot.lineStrings == ["AB  ", "    "])
            #expect(screenSnapshot.cursor == MoshTerminalCursor(row: 0, column: 2))

            // Observability preserved: applying the identical host diff on a fresh
            // received host state DOES capture the generated reply on
            // `lastAppliedTerminalToHostBytes` (ESC [ 1 ; 3 R for the cursor at
            // row 1, column 3), even though the session never transmits it.
            let dimensions = try MoshTerminalDimensions(columns: 4, rows: 2)
            var serverHostState = MoshTerminalHostState(dimensions: dimensions)
            serverHostState.append(hostOutput)
            var clientHostState = MoshTerminalHostState(dimensions: dimensions)
            try clientHostState.applyMoshDiff(
                serverHostState.moshDiff(from: MoshTerminalHostState(dimensions: dimensions))
            )
            #expect(clientHostState.lastAppliedTerminalToHostBytes == Array("\u{1b}[1;3R".utf8))

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
    func renderOperationBufferingCapacityMustBePositive() async {
        await #expect(processExitsWith: .failure) {
            let sessionKey = try! MoshSessionKey(rawBytes: sessionKeyBytes)
            let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
            _ = MoshSession(
                configuration: MoshSessionConfiguration(
                    endpoint: endpoint,
                    initialTerminalDimensions: try! MoshTerminalDimensions(columns: 80, rows: 24),
                    transportFactory: RecoverableSendTransportFactory(
                        link: RecoverableSendDatagramLink(initiallyFailing: false, sendError: .notConnected)
                    )
                ),
                renderOperationBufferingCapacity: 0
            )
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

    // A `stop()` that interleaves with an in-flight `start()` must not be
    // silently ignored: before this fix, `start()` re-checked nothing after its
    // suspension points, so a `stop()` that ran while `self.runtime` was still
    // nil (and so completed as a no-op against the runtime being built)
    // let the resuming `start()` unconditionally commit a runtime that could
    // then never be stopped again, because `isStopped` was already
    // (permanently) true and every later `stop()` call short-circuits on it.
    @Test
    func concurrentStopDuringStartFailsStartAndStopsTheOrphanedRuntime() async throws {
        let link = RecoverableSendDatagramLink(initiallyFailing: false, sendError: .notConnected)
        let factory = SequencedGatedTransportFactory(links: [link], gatingCallIndex: 0)
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let dimensions = try MoshTerminalDimensions(columns: 80, rows: 24)
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: dimensions,
                transportFactory: factory,
                clock: ManualMillisecondsClock(),
                timer: ManualSessionTimer()
            )
        )

        let startTask = Task {
            try await session.start()
        }

        try await withSessionTimeout {
            await factory.waitUntilGatedCallEntered()
        }

        // `self.runtime` is still nil here: the suspended `start()` has not
        // committed yet, so — without the fix — this `stop()` is a true no-op
        // against the runtime the suspended `start()` is building.
        await session.stop()

        await factory.openGate()

        await expectSessionError(.stopped) {
            try await startTask.value
        }

        // The orphaned runtime's link must have been stopped by `start()`
        // itself once it detected the race, not left running forever.
        #expect(await link.stopCount() == 1)

        // A second `stop()` remains a clean, idempotent no-op.
        await session.stop()
        #expect(await link.stopCount() == 1)
    }

    // A second concurrent `start()` must not let two runtimes race to become
    // `self.runtime`: the loser must detect it was superseded, stop the
    // runtime it built, and leave the winner's session state untouched.
    @Test
    func secondConcurrentStartSupersedesFirstAndStopsItsOrphanedRuntime() async throws {
        let firstLink = RecoverableSendDatagramLink(initiallyFailing: false, sendError: .notConnected)
        let secondLink = RecoverableSendDatagramLink(initiallyFailing: false, sendError: .notConnected)
        let factory = SequencedGatedTransportFactory(
            links: [firstLink, secondLink],
            gatingCallIndex: 0
        )
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let dimensions = try MoshTerminalDimensions(columns: 80, rows: 24)
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: dimensions,
                transportFactory: factory,
                clock: ManualMillisecondsClock(),
                timer: ManualSessionTimer()
            )
        )

        let firstStartTask = Task {
            try await session.start()
        }

        try await withSessionTimeout {
            await factory.waitUntilGatedCallEntered()
        }

        // The second call's `makeDatagramLink` is not the gated one, so it
        // proceeds uninterrupted and wins the race.
        try await session.start()

        await factory.openGate()

        await expectSessionError(.alreadyStarted) {
            try await firstStartTask.value
        }

        // The loser's runtime was stopped by `start()` once it detected the
        // supersession...
        #expect(await firstLink.stopCount() == 1)
        // ...and the winner's session state was left untouched.
        #expect(await secondLink.stopCount() == 0)

        await session.stop()
        #expect(await secondLink.stopCount() == 1)
    }

    // Behavior B: a transient `link.send` failure at start (here every send fails
    // until connectivity returns) must NOT tear the session down, and while the
    // outage lasts the session must NOT falsely claim `.datagramsSent` — the outage
    // is surfaced through `liveness.recordedSendErrorDescription` instead. Official
    // Mosh's `Connection::send` records the errno into `send_error` and returns; the
    // SSP retransmit timer re-sends once connectivity returns. (Rewritten: the test
    // no longer awaits `.datagramsSent` during the failure window — that event is now
    // suppressed while a send error is recorded, so awaiting it would hang.)
    @Test
    func transientSendFailureAtStartKeepsSessionAlive() async throws {
        let failingLink = RecoverableSendDatagramLink(initiallyFailing: true, sendError: .notConnected)
        let clock = ManualMillisecondsClock()
        let timer = ManualSessionTimer()
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                transportFactory: RecoverableSendTransportFactory(link: failingLink),
                clock: clock,
                timer: timer,
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
        let (recorder, recorderTask) = recordEvents(from: session)

        do {
            // The initial resize send fails transiently; start still succeeds and the
            // session stays alive. No `.datagramsSent` is claimed while the send fails.
            try await session.start()

            // (b) The outage is visible on the liveness signal during the failure.
            #expect(await session.liveness.recordedSendErrorDescription != nil)

            // (a) Still usable during the outage: a keystroke whose send also fails is
            // recorded and swallowed, not thrown.
            try await session.sendKeystrokes([0x61])
            #expect(await session.liveness.recordedSendErrorDescription != nil)

            // Connectivity returns; the next send succeeds.
            await failingLink.recover()
            try await session.sendKeystrokes([0x62])

            // (b) The outage signal clears after recovery, and (c) `.datagramsSent`
            // resumes (its first-ever emission is this post-recovery send).
            #expect(await session.liveness.recordedSendErrorDescription == nil)
            try await withSessionTimeout {
                await recorder.waitUntil { $0.contains(.datagramsSent(packetCount: 1)) }
            }

            // Still usable after recovery.
            try await session.sendKeystrokes([0x63])

            await session.stop()
            recorderTask.cancel()
        } catch {
            recorderTask.cancel()
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

    // Behavior B: a transient `link.send` failure while sending a keystroke must NOT
    // throw out of `sendKeystrokes` or tear the session down; it is recorded and
    // swallowed. `.datagramsSent` is suppressed for the failed send and resumes once
    // sends succeed again, and the outage is visible on
    // `liveness.recordedSendErrorDescription` in between. (Rewritten: previously this
    // asserted the pre-fix behavior that such a send error finished the streams and
    // stopped the runtime.)
    @Test
    func transientSendFailureDuringKeystrokesKeepsSessionAlive() async throws {
        let sendError = MoshDatagramTransportError.notConnected
        // Send #1 (the initial resize) succeeds; the link is then flipped to failing so
        // send #2 (the first keystroke) fails; it is healed so send #3 succeeds again.
        let link = RecoverableSendDatagramLink(initiallyFailing: false, sendError: sendError)
        let clock = ManualMillisecondsClock()
        let timer = ManualSessionTimer()
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                transportFactory: RecoverableSendTransportFactory(link: link),
                clock: clock,
                timer: timer,
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
        let (recorder, recorderTask) = recordEvents(from: session)

        do {
            // Send #1 (initial resize) succeeds: `.datagramsSent` is claimed and no
            // outage is recorded.
            try await session.start()
            try await withSessionTimeout {
                await recorder.waitUntil { $0.contains(.datagramsSent(packetCount: 1)) }
            }
            #expect(await session.liveness.recordedSendErrorDescription == nil)

            // Send #2 (this keystroke) fails at the link: recorded and swallowed, not
            // thrown. No `.datagramsSent` is claimed and the session does not stop.
            await link.fail()
            try await session.sendKeystrokes([0x61])
            #expect(await session.liveness.recordedSendErrorDescription != nil)
            #expect(await recorder.contains(.stopped) == false)

            // Send #3 (next keystroke) succeeds: the outage signal clears and
            // `.datagramsSent` resumes (a second such event is observed).
            await link.recover()
            try await session.sendKeystrokes([0x62])
            #expect(await session.liveness.recordedSendErrorDescription == nil)
            try await withSessionTimeout {
                await recorder.waitUntil { events in
                    events.filter { $0 == .datagramsSent(packetCount: 1) }.count >= 2
                }
            }

            // Still usable.
            try await session.sendKeystrokes([0x63])

            await session.stop()
            recorderTask.cancel()
        } catch {
            recorderTask.cancel()
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

    // Invariant A: an automatic link rebuild after a transport failure resumes the
    // SAME session on a fresh link, but `.reconnected` is emitted only when the
    // server is actually HEARD on the rebuilt link — never merely because the fresh
    // socket was installed (installing a socket against a dead network proves
    // nothing). This drives a genuine server instruction across the rebuilt link and
    // asserts `.reconnected` follows that contact, and that it is absent between the
    // rebuild attempt and the contact.
    @Test
    func linkFailureReconnectsOnlyWhenServerHeardOnFreshLink() async throws {
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let firstLink = IncomingFailureDatagramLink()
        // The rebuilt link is the client end of a connected pair, with a server
        // runtime on the other end so a real server instruction can be delivered.
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        try await pair.client.start()
        let factory = ReconnectingTransportFactory(links: [firstLink, pair.client])
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
        let serverRuntime = try makeServerRuntime(
            link: pair.server,
            clock: ManualMillisecondsClock(),
            timing: MoshSSPSendTimingConfiguration(
                sendIntervalMilliseconds: 0,
                acknowledgementIntervalMilliseconds: 1_000,
                sendMinimumDelayMilliseconds: 0
            )
        )
        let (recorder, recorderTask) = recordEvents(from: session)

        do {
            try await serverRuntime.start()
            try await session.start()

            // The initial link's incoming stream fails, driving the rebuild onto the
            // connected client link.
            await firstLink.failIncoming(throwing: MoshDatagramTransportError.notConnected)

            // The rebuild announces the attempt and installs the fresh link, but MUST
            // NOT yet announce reconnection: nothing has been heard from the server.
            try await withSessionTimeout {
                await recorder.waitUntil { $0.contains(.reconnecting(attempt: 1)) }
            }
            #expect(await recorder.contains(.reconnected) == false)

            // Drive a genuine server instruction across the rebuilt link. Only now is
            // the server HEARD, so `.reconnected` must be emitted.
            var hostState = MoshTerminalHostState()
            hostState.append(.write(MoshTerminalOutput(bytes: Array("R".utf8))))
            await serverRuntime.setCurrentState(hostState)
            _ = try await serverRuntime.sendDueDatagrams()

            try await withSessionTimeout {
                await recorder.waitUntil { $0.contains(.reconnected) }
            }

            // Order invariant: the rebuild attempt precedes the reconnection.
            let events = await recorder.snapshot()
            let reconnectingIndex = events.firstIndex(of: .reconnecting(attempt: 1))
            let reconnectedIndex = events.firstIndex(of: .reconnected)
            #expect(reconnectingIndex != nil)
            #expect(reconnectedIndex != nil)
            if let reconnectingIndex, let reconnectedIndex {
                #expect(reconnectingIndex < reconnectedIndex)
            }

            // The session is alive on the new link: a keystroke is accepted.
            try await session.sendKeystrokes([0x61])

            await session.stop()
            await serverRuntime.stop()
            recorderTask.cancel()
        } catch {
            recorderTask.cancel()
            await session.stop()
            await serverRuntime.stop()
            throw error
        }
    }

    // Behavior D: on peer-initiated shutdown (server sends the sentinel state number
    // UInt64.max), the session sends an acknowledgement datagram carrying
    // acknowledgementNumber == UInt64.max BEFORE stopping, so the server can stop
    // retransmitting its final state, then finishes cleanly (`.peerShutdown`,
    // `.stopped`). This mirrors official `counterparty_shutdown_ack_sent()`. The ack
    // is decoded wire-level by the server runtime, not read from session internals.
    @Test
    func serverShutdownIsAcknowledgedWithSentinelAckBeforeStop() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)
        let (recorder, recorderTask) = recordEvents(from: fixture.session)
        // Consume server-received instructions, looking for the sentinel-ack the
        // client sends in response to the shutdown.
        let sentinelAckTask = Task<Bool, Error> {
            for try await instruction in fixture.serverRuntime.incomingInstructions {
                if instruction.instructionResult.instruction.acknowledgementNumber == UInt64.max {
                    return true
                }
            }
            return false
        }

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            await fixture.serverRuntime.startShutdown()
            let shutdownBatch = try #require(try await fixture.serverRuntime.sendDueDatagrams())
            #expect(shutdownBatch.sspBatch.instruction.newNumber == UInt64.max)

            // The client transmits a real datagram whose acknowledgementNumber is the
            // shutdown sentinel; the server decodes it off the wire.
            let sentinelAckSeen = try await withSessionTimeout {
                try await sentinelAckTask.value
            }
            #expect(sentinelAckSeen)

            // Then the streams finish cleanly: peerShutdown followed by stopped last.
            try await withSessionTimeout {
                await recorder.waitUntil { $0.contains(.stopped) }
            }
            let events = await recorder.snapshot()
            #expect(events.contains(.peerShutdown))
            #expect(events.last == .stopped)

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            recorderTask.cancel()
        } catch {
            sentinelAckTask.cancel()
            recorderTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    // Fix G: the maintenance loop no longer strongly retains the session, so a
    // session whose last external reference is dropped WITHOUT an explicit stop must
    // deallocate — and its runtime's `deinit` must stop the link so the socket cannot
    // leak. (Pre-fix, the maintenance loop pinned an abandoned session forever, still
    // transmitting keepalives after the host released it.)
    @Test
    func abandonedSessionDeallocatesAndStopsItsLink() async throws {
        let link = RecoverableSendDatagramLink(initiallyFailing: false, sendError: .notConnected)
        weak var weakSession: MoshSession?

        do {
            let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
            let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
            let session = MoshSession(
                configuration: MoshSessionConfiguration(
                    endpoint: endpoint,
                    initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                    transportFactory: RecoverableSendTransportFactory(link: link),
                    clock: ManualMillisecondsClock(),
                    timer: ManualSessionTimer(),
                    timing: MoshSSPSendTimingConfiguration(
                        sendIntervalMilliseconds: 0,
                        acknowledgementIntervalMilliseconds: 1_000,
                        sendMinimumDelayMilliseconds: 0
                    ),
                    chaffSource: .none
                )
            )
            weakSession = session
            try await session.start()
            #expect(weakSession != nil)
            // The last strong reference to `session` is dropped at the end of this scope.
        }

        // The abandoned session must deallocate (bounded poll on the weak reference).
        var deallocated = false
        for _ in 0..<2_000 where deallocated == false {
            if weakSession == nil {
                deallocated = true
                break
            }
            await Task.yield()
        }
        #expect(deallocated)

        // Its link was stopped by the runtime's deinit (bounded poll for the async stop).
        var linkStopped = false
        for _ in 0..<2_000 where linkStopped == false {
            if await link.stopCount() > 0 {
                linkStopped = true
                break
            }
            await Task.yield()
        }
        #expect(linkStopped)
    }

    // Invariant A: links that install cleanly but immediately die again (a socket
    // that opens against a dead network and faults before any contact) must NOT
    // launder the rebuild counter. Attempts accumulate across install-then-die
    // cycles with GROWING numbers (no reset to 1), `.reconnected` is never emitted,
    // and after `maximumLinkRebuildAttempts` the session tears down with
    // `linkRebuildAttemptsExhausted`.
    @Test
    func installThenDieChurnWithoutContactExhaustsWithoutReconnecting() async throws {
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let maximumAttempts = 3
        let initialLink = IncomingFailureDatagramLink()
        let factory = ChurningRebuildTransportFactory(
            initialLink: initialLink,
            incomingError: .notConnected
        )
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                transportFactory: factory,
                chaffSource: .none,
                resilience: MoshSessionResilienceConfiguration(
                    maximumLinkRebuildAttempts: maximumAttempts,
                    initialRebuildBackoffMilliseconds: 1,
                    maximumRebuildBackoffMilliseconds: 2,
                    portHopIntervalMilliseconds: 0
                )
            )
        )
        let hostFailureTask = collectStreamFailure(from: session.hostOperations)
        let (recorder, recorderTask) = recordEvents(from: session)

        do {
            try await session.start()
            try await Task.sleep(for: .milliseconds(10))
            await initialLink.failIncoming(throwing: MoshDatagramTransportError.notConnected)

            let hostFailure = try await withSessionTimeout {
                await hostFailureTask.value
            }
            try await withSessionTimeout {
                await recorder.waitUntil { $0.contains(.stopped) }
            }
            let events = await recorder.snapshot()
            let reconnectingAttempts = events.compactMap { event -> Int? in
                if case .reconnecting(let attempt) = event {
                    return attempt
                }
                return nil
            }

            #expect(reconnectingAttempts == Array(1...maximumAttempts))
            #expect(events.contains(.reconnected) == false)
            #expect((hostFailure as? MoshSessionError) == .linkRebuildAttemptsExhausted)
            #expect(events.last == .stopped)
            recorderTask.cancel()
        } catch {
            hostFailureTask.cancel()
            recorderTask.cancel()
            await session.stop()
            throw error
        }
    }

    // Invariant A, reset path: heard contact on a rebuilt link resets the
    // consecutive-attempt counter. Churn install-then-die once (attempts 1, 2), then
    // a link that actually delivers a server instruction (contact) emits
    // `.reconnected` and resets the counter, so the NEXT link death restarts the
    // attempt numbering at 1 rather than continuing to 3.
    @Test
    func heardContactMidChurnResetsRebuildAttemptCounter() async throws {
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let contactDatagram = try await makeContactDatagram(sessionKey: sessionKey)
        let initialLink = IncomingFailureDatagramLink()
        let contactLink = ContactThenFailIncomingDatagramLink(contactDatagram: contactDatagram)
        let factory = ReconnectingTransportFactory(links: [
            initialLink,
            ImmediatelyFailingIncomingDatagramLink(incomingError: .notConnected),
            contactLink,
            ImmediatelyFailingIncomingDatagramLink(incomingError: .notConnected),
            ImmediatelyFailingIncomingDatagramLink(incomingError: .notConnected),
        ])
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                transportFactory: factory,
                chaffSource: .none,
                resilience: MoshSessionResilienceConfiguration(
                    maximumLinkRebuildAttempts: nil,
                    initialRebuildBackoffMilliseconds: 1,
                    maximumRebuildBackoffMilliseconds: 2,
                    portHopIntervalMilliseconds: 0
                )
            )
        )
        let (recorder, recorderTask) = recordEvents(from: session)

        do {
            try await session.start()
            try await Task.sleep(for: .milliseconds(10))
            await initialLink.failIncoming(throwing: MoshDatagramTransportError.notConnected)

            // Churn reaches the contact link and the server is heard: `.reconnected`.
            try await withSessionTimeout {
                await recorder.waitUntil { $0.contains(.reconnected) }
            }

            // Now fail the (previously healthy) contact link; the reset means the next
            // attempt is numbered 1, not 3.
            await contactLink.failIncoming(throwing: MoshDatagramTransportError.notConnected)
            try await withSessionTimeout {
                await recorder.waitUntil { events in
                    events.compactMap { event -> Int? in
                        if case .reconnecting(let attempt) = event { return attempt }
                        return nil
                    }.count >= 3
                }
            }

            let events = await recorder.snapshot()
            let reconnectingAttempts = events.compactMap { event -> Int? in
                if case .reconnecting(let attempt) = event {
                    return attempt
                }
                return nil
            }
            // Pre-contact churn grows 1, 2; post-contact death restarts at 1 (reset).
            #expect(Array(reconnectingAttempts.prefix(3)) == [1, 2, 1])
            #expect(events.filter { $0 == .reconnected }.count == 1)

            await session.stop()
            recorderTask.cancel()
        } catch {
            recorderTask.cancel()
            await session.stop()
            throw error
        }
    }

    // Invariant A, replay guard: an authentic but out-of-sequence (`.replayed`)
    // server datagram is valid state data but is NOT fresh connection-level
    // contact, so it must neither emit `.reconnected` nor reset the
    // consecutive-rebuild attempt counter — otherwise a captured/duplicated
    // datagram could mask an ongoing outage. This delivers the SAME sealed
    // datagram twice (the second arrival is `.replayed`) mid-churn and asserts
    // (a) no `.reconnected` fires for the replay, (b) the attempt counter keeps
    // growing across the replay (numbering continues rather than restarting at
    // 1), while (c) a genuinely NEW datagram afterward DOES emit `.reconnected`
    // and reset the counter so the next death restarts numbering at 1.
    @Test
    func replayedInstructionDoesNotCountAsContactButNewOneDoes() async throws {
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        // Two sealed datagrams from one server sequencer: [0] is sequence 0, [1]
        // is sequence 1. Delivering [0] a second time re-authenticates as
        // `.replayed` because the receive sequencer (preserved across link
        // rebuilds) has already advanced past sequence 0.
        let datagrams = try await makeSequentialContactDatagrams(count: 2)
        let firstContactDatagram = datagrams[0]
        let newDatagram = datagrams[1]

        // Scripted link schedule (installed link then one per rebuild):
        //   index0 first contact link  -> delivers seq0 (`.new`, initial contact)
        //   index1 immediate failure   -> reconnecting(attempt: 1)
        //   index2 replay link         -> reconnecting(attempt: 2), delivers seq0 REPLAY
        //   index3 immediate failure   -> reconnecting(attempt: 3)  (no reset by replay)
        //   index4 new-datagram link   -> reconnecting(attempt: 4), delivers seq1 (`.new`)
        //   index5 immediate failure   -> reconnecting(attempt: 1)  (reset by the new one)
        //   index6 immediate failure   -> reconnecting(attempt: 2)
        let firstContactLink = ContactThenFailIncomingDatagramLink(contactDatagram: firstContactDatagram)
        let replayLink = ContactThenFailIncomingDatagramLink(contactDatagram: firstContactDatagram)
        let newDatagramLink = ContactThenFailIncomingDatagramLink(contactDatagram: newDatagram)
        let factory = ReconnectingTransportFactory(links: [
            firstContactLink,
            ImmediatelyFailingIncomingDatagramLink(incomingError: .notConnected),
            replayLink,
            ImmediatelyFailingIncomingDatagramLink(incomingError: .notConnected),
            newDatagramLink,
            ImmediatelyFailingIncomingDatagramLink(incomingError: .notConnected),
            ImmediatelyFailingIncomingDatagramLink(incomingError: .notConnected),
        ])
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                transportFactory: factory,
                chaffSource: .none,
                resilience: MoshSessionResilienceConfiguration(
                    maximumLinkRebuildAttempts: 8,
                    initialRebuildBackoffMilliseconds: 1,
                    maximumRebuildBackoffMilliseconds: 2,
                    portHopIntervalMilliseconds: 0
                )
            )
        )
        let (recorder, recorderTask) = recordEvents(from: session)

        let hostStateReceivedCount: @Sendable ([MoshSessionEvent]) -> Int = { events in
            events.filter { event in
                if case .hostStateReceived = event { return true }
                return false
            }.count
        }
        let reconnectingAttempts: @Sendable ([MoshSessionEvent]) -> [Int] = { events in
            events.compactMap { event in
                if case .reconnecting(let attempt) = event { return attempt }
                return nil
            }
        }

        do {
            try await session.start()

            // The initial seq0 datagram is processed as in-sequence contact; wait
            // for it so the receive sequencer advances past sequence 0 (making the
            // later re-delivery a genuine `.replayed`).
            try await withSessionTimeout {
                await recorder.waitUntil { hostStateReceivedCount($0) >= 1 }
            }
            // No rebuild was pending, so initial contact emits no `.reconnected`.
            #expect(await recorder.contains(.reconnected) == false)

            // Fail the initial link; churn reaches the replay link on attempt 2.
            await firstContactLink.failIncoming(throwing: MoshDatagramTransportError.notConnected)
            try await withSessionTimeout {
                await recorder.waitUntil { $0.contains(.reconnecting(attempt: 2)) }
            }

            // The replay link installs while a rebuild is pending and re-delivers
            // the sequence-0 datagram (`.replayed`). Wait for it to be processed
            // (a second `.hostStateReceived`). It must NOT be credited as contact.
            try await withSessionTimeout {
                await recorder.waitUntil { hostStateReceivedCount($0) >= 2 }
            }
            #expect(await recorder.contains(.reconnected) == false)

            // Fail the replay link. If the replay had (wrongly) reset the counter
            // the next attempt would be 1; the guard keeps it growing to 3, then 4
            // when the new-datagram link installs and is HEARD in-sequence.
            await replayLink.failIncoming(throwing: MoshDatagramTransportError.notConnected)
            try await withSessionTimeout {
                await recorder.waitUntil { $0.contains(.reconnected) }
            }

            // Fail the (heard) new-datagram link; the reset means numbering
            // restarts at 1, so wait until at least six `.reconnecting` events land.
            await newDatagramLink.failIncoming(throwing: MoshDatagramTransportError.notConnected)
            try await withSessionTimeout {
                await recorder.waitUntil { reconnectingAttempts($0).count >= 6 }
            }

            let events = await recorder.snapshot()
            // (a)+(c) Exactly one `.reconnected`, emitted only by the fresh `.new`
            // datagram — never by the initial no-pending-rebuild contact nor the
            // replay.
            #expect(events.filter { $0 == .reconnected }.count == 1)
            // (b) Numbering grows 1,2,3,4 across the replay (no reset), then the
            // genuine new datagram resets it so the next death restarts at 1,2.
            #expect(Array(reconnectingAttempts(events).prefix(6)) == [1, 2, 3, 4, 1, 2])

            await session.stop()
            recorderTask.cancel()
        } catch {
            recorderTask.cancel()
            await session.stop()
            throw error
        }
    }

    // Behavior F: the time-driven client port hop. A NAT mapping that silently
    // expires or a blackholed path never faults the socket, so recovery must be
    // time-driven. When the server has been silent for at least the port-hop
    // interval AND the current link is at least that old, the maintenance loop
    // proactively rebuilds the link (`.reconnecting`) with NO link failure — but not
    // while the server was heard recently, even if the link itself is old.
    @Test
    func portHopRebuildsOnSilencePastIntervalButNotWhileHeardRecently() async throws {
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let clock = ManualMillisecondsClock()
        let timer = ManualSessionTimer()
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        let hopLink = IncomingFailureDatagramLink()
        let factory = ReconnectingTransportFactory(links: [pair.client, hopLink])
        let hopInterval: UInt64 = 10_000
        let timing = MoshSSPSendTimingConfiguration(
            sendIntervalMilliseconds: 0,
            acknowledgementIntervalMilliseconds: 1_000,
            sendMinimumDelayMilliseconds: 0,
            timeoutMilliseconds: 1_000
        )
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                transportFactory: factory,
                clock: clock,
                timer: timer,
                timing: timing,
                chaffSource: .none,
                resilience: MoshSessionResilienceConfiguration(
                    portHopIntervalMilliseconds: hopInterval
                )
            )
        )
        let serverRuntime = try makeServerRuntime(link: pair.server, clock: clock, timing: timing)
        let hostOperationTask = collectHostOperations(from: session, count: 1)
        let (recorder, recorderTask) = recordEvents(from: session)

        do {
            try await serverRuntime.start()
            try await session.start()

            // The server is heard at clock 8000.
            await clock.set(toMilliseconds: 8_000)
            var hostState = MoshTerminalHostState()
            hostState.append(.write(MoshTerminalOutput(bytes: Array("R".utf8))))
            await serverRuntime.setCurrentState(hostState)
            _ = try await serverRuntime.sendDueDatagrams()
            _ = try await withSessionTimeout {
                try await hostOperationTask.value
            }

            // At clock 10001 the link is old (installed at 0) but the server was heard
            // 2001 ms ago (< interval): no hop.
            await clock.set(toMilliseconds: 10_001)
            await pumpMaintenanceLoop(timer: timer, iterations: 5)
            #expect(await recorder.contains(.reconnecting(attempt: 1)) == false)

            // At clock 18001 the server has been silent for 10001 ms (>= interval) and
            // the link is 18001 ms old: the port hop rebuilds the link.
            await clock.set(toMilliseconds: 18_001)
            try await withSessionTimeout {
                while await recorder.contains(.reconnecting(attempt: 1)) == false {
                    await timer.resumeNextSleep()
                    _ = try? await withSessionTimeout(after: .seconds(1)) {
                        try await timer.nextSleepRequest()
                    }
                }
            }

            // The hop was time-driven, not failure-driven: no teardown occurred.
            #expect(await recorder.contains(.reconnecting(attempt: 1)))
            #expect(await recorder.contains(.stopped) == false)

            await session.stop()
            await serverRuntime.stop()
            recorderTask.cancel()
        } catch {
            hostOperationTask.cancel()
            recorderTask.cancel()
            await session.stop()
            await serverRuntime.stop()
            throw error
        }
    }

    // Behavior F, disabled: a zero port-hop interval disables the time-driven hop, so
    // arbitrarily long server silence never triggers a rebuild.
    @Test
    func portHopDisabledByZeroIntervalNeverRebuildsOnSilence() async throws {
        let sessionKey = try MoshSessionKey(rawBytes: sessionKeyBytes)
        let endpoint = MoshEndpoint(host: "localhost", port: 60_001, sessionKey: sessionKey)
        let clock = ManualMillisecondsClock()
        let timer = ManualSessionTimer()
        let initialLink = IncomingFailureDatagramLink()
        let hopLink = IncomingFailureDatagramLink()
        let factory = ReconnectingTransportFactory(links: [initialLink, hopLink])
        let session = MoshSession(
            configuration: MoshSessionConfiguration(
                endpoint: endpoint,
                initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
                transportFactory: factory,
                clock: clock,
                timer: timer,
                timing: MoshSSPSendTimingConfiguration(
                    sendIntervalMilliseconds: 0,
                    acknowledgementIntervalMilliseconds: 1_000,
                    sendMinimumDelayMilliseconds: 0
                ),
                chaffSource: .none,
                resilience: MoshSessionResilienceConfiguration(
                    portHopIntervalMilliseconds: 0
                )
            )
        )
        let (recorder, recorderTask) = recordEvents(from: session)

        do {
            try await session.start()

            // Advance far past any plausible interval and pump the maintenance loop.
            await clock.set(toMilliseconds: 1_000_000)
            await pumpMaintenanceLoop(timer: timer, iterations: 6)

            #expect(await recorder.contains(.reconnecting(attempt: 1)) == false)
            #expect(await recorder.contains(.stopped) == false)
            // Still usable.
            try await session.sendKeystrokes([0x61])

            await session.stop()
            recorderTask.cancel()
        } catch {
            recorderTask.cancel()
            await session.stop()
            throw error
        }
    }

    // Behavior E: a re-based host diff (wire oldNumber != the client's last adopted
    // state number, possible whenever an acknowledgement is lost) is relative to a
    // frame the stream consumer never rendered, so its operations must NOT be
    // forwarded incrementally. Instead renderOperations yields exactly one .resync of
    // the wholesale framebuffer and hostOperations yields nothing for that state; a
    // subsequent chained diff resumes incremental host/render operations.
    @Test
    func rebasedDiffYieldsResyncWhileChainedDiffsResumeIncrementalOperations() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)
        // Render ops: write("A") [chained], .resync [re-based], write("C") [chained].
        let renderTask = collectRenderOperations(from: fixture.session, count: 3)
        // Host ops: write("A") and write("C") only — the re-based state yields none.
        let hostTask = collectHostOperations(from: fixture.session, count: 2)
        // The wholesale framebuffer the re-base resync must carry: "AB" on 80x24.
        var expectedFrame = MoshTerminalHostState()
        expectedFrame.append(.write(MoshTerminalOutput(bytes: Array("A".utf8))))
        expectedFrame.append(.write(MoshTerminalOutput(bytes: Array("B".utf8))))
        let expectedResyncSnapshot = expectedFrame.screenSnapshot

        // Server states are built by appending operations (the wire diff between two
        // states is the operation-list suffix), so a chained diff is the single new op.
        let writeA = MoshHostOperation.write(MoshTerminalOutput(bytes: Array("A".utf8)))
        let writeB = MoshHostOperation.write(MoshTerminalOutput(bytes: Array("B".utf8)))
        let writeC = MoshHostOperation.write(MoshTerminalOutput(bytes: Array("C".utf8)))

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            // State 1 [write A] chains from the initial state: forwarded incrementally.
            await fixture.clock.set(toMilliseconds: 0)
            var stateA = MoshTerminalHostState()
            stateA.append(writeA)
            await fixture.serverRuntime.setCurrentState(stateA)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            // State 2 [write A, write B]: the client's maintenance loop is never pumped,
            // so it never acks state 1; after its send timeout the server re-bases
            // state 2 from the initial state (wire oldNumber 0 != client's adopted 1).
            // The client cannot apply that diff incrementally -> a single .resync.
            await fixture.clock.set(toMilliseconds: 2_000)
            var stateB = MoshTerminalHostState()
            stateB.append(writeA)
            stateB.append(writeB)
            await fixture.serverRuntime.setCurrentState(stateB)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            // State 3 [write A, write B, write C]: deliver the client's ack for state 2
            // (pump its maintenance loop) so the server chains state 3 from state 2 (wire
            // oldNumber 2 == client's adopted 2). The chained diff is the single new op.
            await fixture.clock.set(toMilliseconds: 2_100)
            try await withSessionTimeout {
                while await fixture.serverRuntime.knownAcknowledgedSendStateNumber() < 2 {
                    await fixture.timer.resumeNextSleep()
                    _ = try? await withSessionTimeout(after: .seconds(1)) {
                        try await fixture.timer.nextSleepRequest()
                    }
                }
            }
            var stateC = MoshTerminalHostState()
            stateC.append(writeA)
            stateC.append(writeB)
            stateC.append(writeC)
            await fixture.serverRuntime.setCurrentState(stateC)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            let renderOperations = try await withSessionTimeout {
                try await renderTask.value
            }
            let hostOperations = try await withSessionTimeout {
                try await hostTask.value
            }

            #expect(renderOperations.count == 3)
            #expect(renderOperations.first == .write(MoshTerminalOutput(bytes: Array("A".utf8))))
            guard renderOperations.count == 3, case .resync(let resyncSnapshot) = renderOperations[1] else {
                Issue.record("Expected the re-based diff to yield a single .resync; got \(renderOperations).")
                throw SessionTestError.timedOut
            }
            // The resync carries the wholesale adopted framebuffer, not incremental ops.
            #expect(resyncSnapshot == expectedResyncSnapshot)
            #expect(resyncSnapshot.lineStrings.first == "AB" + String(repeating: " ", count: 78))
            #expect(renderOperations[2] == .write(MoshTerminalOutput(bytes: Array("C".utf8))))

            // The re-based state contributed NO host operation: host ops are exactly
            // the two chained writes.
            #expect(hostOperations == [
                .write(MoshTerminalOutput(bytes: Array("A".utf8))),
                .write(MoshTerminalOutput(bytes: Array("C".utf8))),
            ])

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            renderTask.cancel()
            hostTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    // Once the bounded `renderOperations` buffer is full, a further yield
    // still succeeds for the value just passed in but silently evicts an
    // earlier, not-yet-consumed operation (reported as `.dropped`). Without a
    // resync, an incremental consumer that missed the evicted operation is
    // permanently out of sync with every later chained diff. This proves the
    // session detects the drop and repairs the consumer with a `.resync`
    // carrying the fully correct final state, the same repair already used
    // for a re-based diff above.
    @Test
    func renderStreamOverflowEmitsResyncInsteadOfSilentlyDroppingOperations() async throws {
        let fixture = try await makeSessionFixture(
            columns: 80,
            rows: 24,
            renderOperationBufferingCapacity: 1
        )
        // Recorded via `diagnosticEvents`, not `renderOperations`: an eagerly
        // awaiting `renderOperations` consumer would receive each yielded
        // operation directly (AsyncStream bypasses buffering entirely when a
        // consumer is already suspended in `next()`), so this test must not
        // start reading `renderOperations` until after the drop-triggering
        // yields already happened with nobody consuming them.
        let (recorder, recorderTask) = recordEvents(from: fixture.session)
        var state = MoshTerminalHostState()
        state.append(.write(MoshTerminalOutput(bytes: Array("A".utf8))))
        state.append(.write(MoshTerminalOutput(bytes: Array("B".utf8))))
        let expectedSnapshot = state.screenSnapshot

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            // A single instruction carrying two operations: with a
            // one-element render buffer, the second `renderOperations` yield
            // evicts the first (unconsumed) operation before this test ever
            // reads the stream.
            await fixture.serverRuntime.setCurrentState(state)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            // `.hostStateReceived` is emitted only after the render loop (and
            // any drop-triggered resync) has already run to completion.
            try await withSessionTimeout {
                await recorder.waitUntil { events in
                    events.contains { event in
                        if case .hostStateReceived = event { return true }
                        return false
                    }
                }
            }

            let renderOperations = try await withSessionTimeout {
                var iterator = fixture.session.renderOperations.makeAsyncIterator()
                guard let first = try await iterator.next() else {
                    return [MoshTerminalRenderOperation]()
                }
                return [first]
            }

            // The evicted write("A") is gone for good; a resync carrying the
            // correct A+B state is what actually survives in the buffer, not
            // a stale or missing frame.
            guard renderOperations.count == 1, case .resync(let snapshot) = renderOperations[0] else {
                Issue.record("Expected a .resync after the overflow drop; got \(renderOperations).")
                throw SessionTestError.timedOut
            }
            #expect(snapshot == expectedSnapshot)

            recorderTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            recorderTask.cancel()
            await fixture.session.stop()
            await fixture.serverRuntime.stop()
            throw error
        }
    }

    // Behavior C under re-base: a DSR query applied both by a chained diff and again
    // by a re-based diff that re-includes it must produce ZERO transmitted reply
    // bytes both times — the server-side emulator answers such queries; the client
    // asserts it produced none. Transmitting on re-apply would inject duplicate bytes.
    @Test
    func terminalReplyIsNeverTransmittedEvenWhenReappliedByRebasedDiff() async throws {
        let fixture = try await makeSessionFixture(columns: 80, rows: 24)
        // Render ops: write(DSR) [chained], .resync [re-based re-apply of the DSR].
        let renderTask = collectRenderOperations(from: fixture.session, count: 2)
        // The client's cumulative operation state once the genuine "q" keystroke is
        // received. If a terminal reply were ever transmitted it would appear here as
        // a keystrokes operation; collecting until "q" tolerates retransmits/acks.
        let clientStateAtKeystrokeTask = Task<[MoshClientOperation], Error> {
            for try await instruction in fixture.serverRuntime.incomingInstructions {
                let operations = instruction.instructionResult.latestState.state.operations
                if operations.contains(.keystrokes([UInt8(ascii: "q")])) {
                    return operations
                }
            }
            return []
        }

        do {
            try await fixture.serverRuntime.start()
            try await fixture.session.start()

            // A visible glyph precedes the DSR query so state 1 is a distinct
            // framebuffer that actually transmits (a query alone leaves the screen
            // unchanged and never becomes a new state).
            let queryWrite = MoshHostOperation.write(MoshTerminalOutput(bytes: Array("X\u{1b}[6n".utf8)))

            // State 1 carries a DSR cursor-position query, applied via a chained diff.
            await fixture.clock.set(toMilliseconds: 0)
            var stateQuery = MoshTerminalHostState()
            stateQuery.append(queryWrite)
            await fixture.serverRuntime.setCurrentState(stateQuery)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            // State 2 re-includes the DSR query (as the operation-list prefix) and is
            // re-based (oldNumber 0 != adopted 1), so the client re-applies the query
            // while reconstructing the wholesale framebuffer and emits a .resync.
            await fixture.clock.set(toMilliseconds: 2_000)
            var stateRebased = MoshTerminalHostState()
            stateRebased.append(queryWrite)
            stateRebased.append(.write(MoshTerminalOutput(bytes: Array("Y".utf8))))
            await fixture.serverRuntime.setCurrentState(stateRebased)
            _ = try await fixture.serverRuntime.sendDueDatagrams()

            // Confirm both DSR applications happened (chained write then re-based resync).
            let renderOperations = try await withSessionTimeout {
                try await renderTask.value
            }
            guard renderOperations.count == 2, case .resync = renderOperations[1] else {
                Issue.record("Expected the re-based diff to yield a .resync; got \(renderOperations).")
                throw SessionTestError.timedOut
            }

            // A genuine keystroke follows. If either DSR application had transmitted a
            // reply, it would appear as a client keystroke operation ahead of this one;
            // asserting the client's operations are exactly [resize, "q"] pins that no
            // reply was ever transmitted (both times).
            try await fixture.session.sendKeystrokes([UInt8(ascii: "q")])

            let clientOperations = try await withSessionTimeout {
                try await clientStateAtKeystrokeTask.value
            }
            // Exactly the resize and the "q" keystroke — no terminal reply was ever
            // transmitted, for either the chained or the re-based DSR application.
            #expect(clientOperations == [
                .resize(try MoshTerminalDimensions(columns: 80, rows: 24)),
                .keystrokes([UInt8(ascii: "q")]),
            ])

            await fixture.session.stop()
            await fixture.serverRuntime.stop()
        } catch {
            clientStateAtKeystrokeTask.cancel()
            renderTask.cancel()
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

private struct RecoverableSendTransportFactory: MoshSessionTransportFactory {
    let link: RecoverableSendDatagramLink

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

/// Vends `links` in order, one per `makeDatagramLink` call. The call at
/// `gatingCallIndex` (0-based) suspends until the test calls `openGate()`, so a
/// test can deterministically pause one `start()` attempt mid-flight while
/// driving another call (a concurrent `start()` or `stop()`) to completion,
/// without a wall-clock sleep.
private actor SequencedGatedTransportFactory: MoshSessionTransportFactory {
    private let links: [any MoshDatagramLink]
    private let gatingCallIndex: Int
    private var callCount = 0
    private var hasEnteredGatedCall = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var canProceed = false
    private var proceedContinuation: CheckedContinuation<Void, Never>?

    init(links: [any MoshDatagramLink], gatingCallIndex: Int) {
        self.links = links
        self.gatingCallIndex = gatingCallIndex
    }

    func makeDatagramLink(for endpoint: MoshEndpoint) async throws -> any MoshDatagramLink {
        let myCallIndex = self.callCount
        self.callCount += 1
        if myCallIndex == self.gatingCallIndex {
            self.hasEnteredGatedCall = true
            self.enteredContinuation?.resume()
            self.enteredContinuation = nil
            if self.canProceed == false {
                await withCheckedContinuation { continuation in
                    self.proceedContinuation = continuation
                }
            }
        }
        return self.links[myCallIndex]
    }

    func waitUntilGatedCallEntered() async {
        if self.hasEnteredGatedCall {
            return
        }
        await withCheckedContinuation { continuation in
            self.enteredContinuation = continuation
        }
    }

    func openGate() {
        self.canProceed = true
        self.proceedContinuation?.resume()
        self.proceedContinuation = nil
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

/// A link whose sends fail while `isFailing`, then succeed once `recover()` is
/// called — models a transient outbound outage that later heals.
private actor RecoverableSendDatagramLink: MoshDatagramLink {
    nonisolated let incomingDatagrams: MoshDatagramStream

    private let incomingContinuation: MoshDatagramStream.Continuation
    private let sendError: MoshDatagramTransportError
    private var isFailing: Bool
    private var stopCountStorage = 0

    init(initiallyFailing: Bool, sendError: MoshDatagramTransportError) {
        self.sendError = sendError
        self.isFailing = initiallyFailing
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
        if self.isFailing {
            throw self.sendError
        }
    }

    func fail() {
        self.isFailing = true
    }

    func recover() {
        self.isFailing = false
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

/// A link that installs cleanly but whose incoming stream is already faulted, so
/// the runtime's receive task faults immediately on install — modelling a socket
/// that "opens" against a dead network but dies before any contact.
private actor ImmediatelyFailingIncomingDatagramLink: MoshDatagramLink {
    nonisolated let incomingDatagrams: MoshDatagramStream

    init(incomingError: MoshDatagramTransportError) {
        var capturedContinuation: MoshDatagramStream.Continuation?
        self.incomingDatagrams = MoshDatagramStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }
        capturedContinuation.finish(throwing: incomingError)
    }

    func start() async throws {}

    func send(_ datagram: [UInt8]) async throws {
        _ = datagram
    }

    func stop() async {}
}

/// A link that installs cleanly, delivers one pre-sealed datagram on start (the
/// server being HEARD), then stays open until `failIncoming(throwing:)` faults it.
private actor ContactThenFailIncomingDatagramLink: MoshDatagramLink {
    nonisolated let incomingDatagrams: MoshDatagramStream

    private let incomingContinuation: MoshDatagramStream.Continuation
    private let contactDatagram: [UInt8]

    init(contactDatagram: [UInt8]) {
        self.contactDatagram = contactDatagram
        var capturedContinuation: MoshDatagramStream.Continuation?
        self.incomingDatagrams = MoshDatagramStream(
            bufferingPolicy: .bufferingNewest(8)
        ) { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }
        self.incomingContinuation = capturedContinuation
    }

    func start() async throws {
        self.incomingContinuation.yield(self.contactDatagram)
    }

    func send(_ datagram: [UInt8]) async throws {
        _ = datagram
    }

    func failIncoming(throwing error: Error) {
        self.incomingContinuation.finish(throwing: error)
    }

    func stop() async {
        self.incomingContinuation.finish()
    }
}

/// Vends the given initial link once, then an install-then-die link for every
/// subsequent rebuild request, so a bounded rebuild loop churns and eventually
/// exhausts WITHOUT the server ever being heard.
private actor ChurningRebuildTransportFactory: MoshSessionTransportFactory {
    private let initialLink: IncomingFailureDatagramLink
    private let incomingError: MoshDatagramTransportError
    private var hasVendedInitial = false

    init(initialLink: IncomingFailureDatagramLink, incomingError: MoshDatagramTransportError) {
        self.initialLink = initialLink
        self.incomingError = incomingError
    }

    func makeDatagramLink(for endpoint: MoshEndpoint) async throws -> any MoshDatagramLink {
        if self.hasVendedInitial == false {
            self.hasVendedInitial = true
            return self.initialLink
        }
        return ImmediatelyFailingIncomingDatagramLink(incomingError: self.incomingError)
    }
}

/// Produces a single real sealed server datagram (a `write` host state) that a
/// client session using `sessionKey` will authenticate and accept as first
/// contact (sequence 0). Built by running a throwaway server runtime over a
/// connected pair and capturing the one datagram it sends.
private func makeContactDatagram(sessionKey: MoshSessionKey) async throws -> [UInt8] {
    let pair = await MoshInMemoryDatagramLink.connectedPair()
    try await pair.client.start()
    let serverRuntime = try makeServerRuntime(
        link: pair.server,
        clock: ManualMillisecondsClock(),
        timing: MoshSSPSendTimingConfiguration(
            sendIntervalMilliseconds: 0,
            acknowledgementIntervalMilliseconds: 1_000,
            sendMinimumDelayMilliseconds: 0
        )
    )
    try await serverRuntime.start()

    var hostState = MoshTerminalHostState()
    hostState.append(.write(MoshTerminalOutput(bytes: Array("R".utf8))))
    await serverRuntime.setCurrentState(hostState)
    _ = try await serverRuntime.sendDueDatagrams()

    var iterator = pair.client.incomingDatagrams.makeAsyncIterator()
    let datagram = try await iterator.next()

    await serverRuntime.stop()
    await pair.client.stop()

    guard let datagram else {
        throw SessionTestError.timedOut
    }
    return datagram
}

/// Produces `count` real sealed server datagrams in ascending sequence order from
/// ONE server sequencer, so a client using `sessionKeyBytes` authenticates the
/// first as in-sequence (`.new`, sequence 0), and re-delivering an earlier
/// datagram authenticates as `.replayed` while a later one is a fresh `.new`.
/// Each carries a distinct host state so adoption advances.
private func makeSequentialContactDatagrams(count: Int) async throws -> [[UInt8]] {
    let pair = await MoshInMemoryDatagramLink.connectedPair()
    try await pair.client.start()
    let serverRuntime = try makeServerRuntime(
        link: pair.server,
        clock: ManualMillisecondsClock(),
        timing: MoshSSPSendTimingConfiguration(
            sendIntervalMilliseconds: 0,
            acknowledgementIntervalMilliseconds: 1_000,
            sendMinimumDelayMilliseconds: 0
        )
    )
    try await serverRuntime.start()

    var iterator = pair.client.incomingDatagrams.makeAsyncIterator()
    var hostState = MoshTerminalHostState()
    var datagrams: [[UInt8]] = []
    for index in 0..<count {
        hostState.append(.write(MoshTerminalOutput(bytes: Array("R\(index)".utf8))))
        await serverRuntime.setCurrentState(hostState)
        _ = try await serverRuntime.sendDueDatagrams()
        guard let datagram = try await iterator.next() else {
            throw SessionTestError.timedOut
        }
        datagrams.append(datagram)
    }

    await serverRuntime.stop()
    await pair.client.stop()
    return datagrams
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
    resilience: MoshSessionResilienceConfiguration = MoshSessionResilienceConfiguration(),
    renderOperationBufferingCapacity: Int = 512
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
        ),
        renderOperationBufferingCapacity: renderOperationBufferingCapacity
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

/// Records the ordered diagnostic-event history from a single stream consumer and
/// lets a test await a predicate over that history without a wall-clock sleep. A
/// waiter is resumed the moment a recorded event makes its predicate true, so a
/// regression fails via `withSessionTimeout` instead of hanging.
private actor SessionEventRecorder {
    private var events: [MoshSessionEvent] = []
    private var waiters: [(check: @Sendable ([MoshSessionEvent]) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ event: MoshSessionEvent) {
        self.events.append(event)
        let snapshot = self.events
        self.waiters.removeAll { waiter in
            if waiter.check(snapshot) {
                waiter.continuation.resume()
                return true
            }
            return false
        }
    }

    func snapshot() -> [MoshSessionEvent] {
        self.events
    }

    func contains(_ event: MoshSessionEvent) -> Bool {
        self.events.contains(event)
    }

    func waitUntil(_ check: @escaping @Sendable ([MoshSessionEvent]) -> Bool) async {
        if check(self.events) {
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append((check, continuation))
        }
    }
}

/// Drives the manual-timer maintenance loop `iterations` times: resume the pending
/// sleep, then wait for the loop to request its next sleep (proving the tick ran).
private func pumpMaintenanceLoop(timer: ManualSessionTimer, iterations: Int) async {
    for _ in 0..<iterations {
        await timer.resumeNextSleep()
        _ = try? await withSessionTimeout(after: .seconds(1)) {
            try await timer.nextSleepRequest()
        }
    }
}

private func recordEvents(
    from session: MoshSession
) -> (recorder: SessionEventRecorder, task: Task<Void, Never>) {
    let recorder = SessionEventRecorder()
    let task = Task {
        for await event in session.diagnosticEvents {
            await recorder.record(event)
            if event == .stopped {
                break
            }
        }
    }
    return (recorder, task)
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
