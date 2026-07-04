// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import TraversioMoshCrypto
import TraversioMoshTransport

public struct MoshEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let sessionKey: MoshSessionKey

    public init(host: String, port: UInt16, sessionKey: MoshSessionKey) {
        self.host = host
        self.port = port
        self.sessionKey = sessionKey
    }
}

extension MoshEndpoint: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never renders the session key. Only the non-secret host and port are shown
    /// so that logging or string interpolation of an endpoint cannot leak key
    /// material. Complements `MoshSessionKey`'s own redaction.
    public var description: String {
        "MoshEndpoint(host: \(self.host), port: \(self.port), sessionKey: <redacted>)"
    }

    /// Never renders the session key, including via `String(reflecting:)`.
    public var debugDescription: String {
        self.description
    }
}

public protocol MoshSessionTransportFactory: Sendable {
    func makeDatagramLink(for endpoint: MoshEndpoint) async throws -> any MoshDatagramLink
}

public protocol MoshSessionTimer: Sendable {
    func sleep(forMilliseconds milliseconds: UInt64) async throws
}

/// Policy governing automatic link rebuild (transport-death resilience) and the
/// informational no-contact liveness signal.
public struct MoshSessionResilienceConfiguration: Sendable {
    /// Maximum number of consecutive link-rebuild attempts after a transport
    /// failure before the session gives up and tears down with the last error.
    /// `nil` retries indefinitely (bounded only by backoff), matching Mosh's
    /// promise that a session survives arbitrarily long outages. A genuinely-down
    /// network never tight-loops because each attempt is separated by backoff.
    public var maximumLinkRebuildAttempts: Int?
    /// Backoff before the first rebuild attempt (ms). Doubles each attempt.
    public var initialRebuildBackoffMilliseconds: UInt64
    /// Upper bound on the exponential backoff interval (ms).
    public var maximumRebuildBackoffMilliseconds: UInt64
    /// When the time since the server was last heard from crosses this threshold,
    /// the session emits a single informational `.noContact` diagnostic (reset once
    /// contact resumes). Purely informational — it NEVER tears the session down;
    /// recovery is via link rebuild. Defaults to 60s, matching official Mosh's
    /// overlay message threshold (`frontend/terminaloverlay.cc` ~318).
    public var noContactThresholdMilliseconds: UInt64

    public init(
        maximumLinkRebuildAttempts: Int? = nil,
        initialRebuildBackoffMilliseconds: UInt64 = 200,
        maximumRebuildBackoffMilliseconds: UInt64 = 10_000,
        noContactThresholdMilliseconds: UInt64 = 60_000
    ) {
        self.maximumLinkRebuildAttempts = maximumLinkRebuildAttempts
        self.initialRebuildBackoffMilliseconds = initialRebuildBackoffMilliseconds
        self.maximumRebuildBackoffMilliseconds = max(
            initialRebuildBackoffMilliseconds,
            maximumRebuildBackoffMilliseconds
        )
        self.noContactThresholdMilliseconds = noContactThresholdMilliseconds
    }
}

/// Host-visible liveness snapshot. Lets a host app render "last contact Ns ago"
/// and surface latency, mirroring official Mosh's `last_word_from_server` /
/// `SRTT` reporting (`frontend/terminaloverlay.cc`). Informational only.
public struct MoshSessionLiveness: Equatable, Sendable {
    /// Clock time (ms) the server was last heard from, or `nil` before first
    /// contact.
    public let lastHeardFromServerMilliseconds: UInt64?
    /// Elapsed time (ms) since the server was last heard from (or since session
    /// start if never heard), for direct "last contact Ns ago" rendering.
    public let millisecondsSinceLastHeard: UInt64
    /// Smoothed round-trip time estimate (ms).
    public let smoothedRoundTripMilliseconds: Double
    /// Round-trip time variation estimate (ms).
    public let roundTripVariationMilliseconds: Double

    public init(
        lastHeardFromServerMilliseconds: UInt64?,
        millisecondsSinceLastHeard: UInt64,
        smoothedRoundTripMilliseconds: Double,
        roundTripVariationMilliseconds: Double
    ) {
        self.lastHeardFromServerMilliseconds = lastHeardFromServerMilliseconds
        self.millisecondsSinceLastHeard = millisecondsSinceLastHeard
        self.smoothedRoundTripMilliseconds = smoothedRoundTripMilliseconds
        self.roundTripVariationMilliseconds = roundTripVariationMilliseconds
    }
}

public struct MoshTaskSessionTimer: MoshSessionTimer {
    public init() {}

    public func sleep(forMilliseconds milliseconds: UInt64) async throws {
        let clampedMilliseconds = min(milliseconds, UInt64(Int64.max))
        try await Task.sleep(for: .milliseconds(Int64(clampedMilliseconds)))
    }
}

public struct MoshSessionConfiguration: Sendable {
    public var endpoint: MoshEndpoint
    public var initialTerminalDimensions: MoshTerminalDimensions
    public var transportFactory: any MoshSessionTransportFactory
    public var clock: any MoshMillisecondsClock
    public var timer: any MoshSessionTimer
    public var timing: MoshSSPSendTimingConfiguration
    public var maximumSerializedFragmentByteCount: Int
    public var chaffSource: MoshSSPChaffSource
    public var predictionConfiguration: MoshPredictionConfiguration
    public var resilience: MoshSessionResilienceConfiguration

    public init(
        endpoint: MoshEndpoint,
        initialTerminalDimensions: MoshTerminalDimensions,
        transportFactory: any MoshSessionTransportFactory,
        clock: any MoshMillisecondsClock = MoshSystemMillisecondsClock(),
        timer: any MoshSessionTimer = MoshTaskSessionTimer(),
        timing: MoshSSPSendTimingConfiguration = MoshSSPSendTimingConfiguration(),
        maximumSerializedFragmentByteCount: Int = MoshSSPDatagramBudget.defaultMaximumSerializedFragmentByteCount,
        chaffSource: MoshSSPChaffSource = .random,
        predictionConfiguration: MoshPredictionConfiguration = MoshPredictionConfiguration(),
        resilience: MoshSessionResilienceConfiguration = MoshSessionResilienceConfiguration()
    ) {
        self.endpoint = endpoint
        self.initialTerminalDimensions = initialTerminalDimensions
        self.transportFactory = transportFactory
        self.clock = clock
        self.timer = timer
        self.timing = timing
        self.maximumSerializedFragmentByteCount = maximumSerializedFragmentByteCount
        self.chaffSource = chaffSource
        self.predictionConfiguration = predictionConfiguration
        self.resilience = resilience
    }
}

public enum MoshSessionError: Error, Equatable, Sendable {
    case alreadyStarted
    case notStarted
    case stopped
    case shutdownTimedOut
}

public enum MoshSessionScreenProjectionFailureReason: Equatable, Sendable {
    case terminalInputParser(MoshTerminalInputParserError)
    case unclassified(String)

    init(error: Error) {
        if let parserError = error as? MoshTerminalInputParserError {
            self = .terminalInputParser(parserError)
        } else {
            self = .unclassified(String(describing: error))
        }
    }
}

public struct MoshSessionScreenProjectionFailure: Error, Equatable, Sendable {
    public let stateNumber: UInt64
    public let operationIndex: Int
    public let operation: MoshTerminalRenderOperation
    public let reason: MoshSessionScreenProjectionFailureReason

    public init(
        stateNumber: UInt64,
        operationIndex: Int,
        operation: MoshTerminalRenderOperation,
        reason: MoshSessionScreenProjectionFailureReason
    ) {
        self.stateNumber = stateNumber
        self.operationIndex = operationIndex
        self.operation = operation
        self.reason = reason
    }
}

public enum MoshSessionEvent: Equatable, Sendable {
    /// The session started against the given host and port. Deliberately carries
    /// only the non-secret endpoint summary (not the live `MoshSessionKey`), so a
    /// diagnostic-stream consumer never holds or renders key material.
    case started(host: String, port: UInt16)
    case datagramsSent(packetCount: Int)
    case hostStateReceived(number: UInt64, operationCount: Int)
    case screenProjectionFailed(MoshSessionScreenProjectionFailure)
    /// The peer (server) initiated shutdown: it sent the shutdown-sentinel state
    /// number and we have adopted it as our latest received state. The session
    /// then finishes its streams cleanly. Distinct from `.stopped`, which is the
    /// generic terminal event for any stop path.
    case peerShutdown
    /// The underlying transport failed and the session is attempting to rebuild the
    /// datagram link (new local socket / port hop) while preserving the same crypto
    /// session and SSP state. `attempt` counts from 1. Recovery is automatic; the
    /// session is NOT torn down while reconnecting.
    case reconnecting(attempt: Int)
    /// A fresh datagram link was successfully installed after a transport failure;
    /// unacknowledged state will be retransmitted over it.
    case reconnected
    /// The server has not been heard from for at least the configured no-contact
    /// threshold. Informational (for "last contact Ns ago" rendering); emitted once
    /// per outage and does NOT tear the session down.
    case noContact(millisecondsSinceLastHeard: UInt64)
    case stopped
}

public actor MoshSession {
    public typealias HostOperationStream = AsyncThrowingStream<MoshHostOperation, Error>
    public typealias RenderOperationStream = AsyncThrowingStream<MoshTerminalRenderOperation, Error>
    public typealias DiagnosticEventStream = AsyncStream<MoshSessionEvent>

    public nonisolated let hostOperations: HostOperationStream
    public nonisolated let renderOperations: RenderOperationStream
    public nonisolated let diagnosticEvents: DiagnosticEventStream

    private let configuration: MoshSessionConfiguration
    private let hostOperationContinuation: HostOperationStream.Continuation
    private let renderOperationContinuation: RenderOperationStream.Continuation
    private let diagnosticEventContinuation: DiagnosticEventStream.Continuation

    private var terminalEngine: MoshTerminalStateEngine
    private var terminalScreen: MoshTerminalScreen
    private var userInputTranslator: MoshTerminalUserInputTranslator
    private var predictionEngine: MoshTerminalPredictionEngine
    private var runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>?
    private var receiveTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var linkEventTask: Task<Void, Never>?
    private var maintenanceGeneration: UInt64 = 0
    private var lastAdoptedHostStateNumber: UInt64 = 0
    private var startedAtMilliseconds: UInt64 = 0
    private var isRebuildingLink = false
    private var hasEmittedNoContact = false
    private var nextStopWaiterID: UInt64 = 0
    private var stopWaiters: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var cancelledStopWaiterIDs: Set<UInt64> = []
    private var isStarted = false
    private var isStopped = false

    public init(
        configuration: MoshSessionConfiguration,
        hostOperationBufferingPolicy: HostOperationStream.Continuation.BufferingPolicy = .bufferingNewest(512),
        renderOperationBufferingPolicy: RenderOperationStream.Continuation.BufferingPolicy = .bufferingNewest(512),
        diagnosticEventBufferingPolicy: DiagnosticEventStream.Continuation.BufferingPolicy = .bufferingNewest(512)
    ) {
        let hostOperationStream = Self.makeHostOperationStream(bufferingPolicy: hostOperationBufferingPolicy)
        let renderOperationStream = Self.makeRenderOperationStream(bufferingPolicy: renderOperationBufferingPolicy)
        let diagnosticEventStream = Self.makeDiagnosticEventStream(bufferingPolicy: diagnosticEventBufferingPolicy)

        self.configuration = configuration
        self.hostOperations = hostOperationStream.stream
        self.hostOperationContinuation = hostOperationStream.continuation
        self.renderOperations = renderOperationStream.stream
        self.renderOperationContinuation = renderOperationStream.continuation
        self.diagnosticEvents = diagnosticEventStream.stream
        self.diagnosticEventContinuation = diagnosticEventStream.continuation

        self.terminalEngine = MoshTerminalStateEngine(
            hostState: MoshTerminalHostState(
                dimensions: configuration.initialTerminalDimensions
            )
        )
        self.terminalScreen = MoshTerminalScreen(
            dimensions: configuration.initialTerminalDimensions
        )
        self.userInputTranslator = MoshTerminalUserInputTranslator()
        self.predictionEngine = MoshTerminalPredictionEngine(
            configuration: configuration.predictionConfiguration
        )
    }

    deinit {
        self.receiveTask?.cancel()
        self.maintenanceTask?.cancel()
        self.linkEventTask?.cancel()
        self.hostOperationContinuation.finish()
        self.renderOperationContinuation.finish()
        self.diagnosticEventContinuation.finish()
    }

    public var snapshot: MoshTerminalSnapshot {
        self.terminalEngine.snapshot
    }

    /// Host-visible liveness: when the server was last heard from, how long ago,
    /// and the current round-trip estimates. Lets a host render "last contact Ns
    /// ago" and latency. Informational — reading it never affects the session.
    public var liveness: MoshSessionLiveness {
        get async {
            let nowMilliseconds = await self.configuration.clock.nowMilliseconds()
            let lastHeard = await self.runtime?.lastHeardAtMilliseconds()
            let reference = lastHeard ?? self.startedAtMilliseconds
            let sinceLastHeard = nowMilliseconds >= reference ? nowMilliseconds - reference : 0
            let smoothedRoundTrip = await self.runtime?.smoothedRoundTripMilliseconds() ?? 0
            let roundTripVariation = await self.runtime?.roundTripVariationMilliseconds() ?? 0
            return MoshSessionLiveness(
                lastHeardFromServerMilliseconds: lastHeard,
                millisecondsSinceLastHeard: sinceLastHeard,
                smoothedRoundTripMilliseconds: smoothedRoundTrip,
                roundTripVariationMilliseconds: roundTripVariation
            )
        }
    }

    public var screenSnapshot: MoshTerminalScreenSnapshot {
        get async {
            let baseSnapshot = self.terminalScreen.snapshot
            self.predictionEngine.cull(
                baseSnapshot: baseSnapshot,
                nowMilliseconds: await self.configuration.clock.nowMilliseconds()
            )
            return self.predictionEngine.projectedSnapshot(
                baseSnapshot: baseSnapshot
            )
        }
    }

    public func start() async throws {
        guard self.isStopped == false else {
            throw MoshSessionError.stopped
        }
        guard self.isStarted == false else {
            throw MoshSessionError.alreadyStarted
        }

        let link = try await self.configuration.transportFactory.makeDatagramLink(
            for: self.configuration.endpoint
        )
        let initialNowMilliseconds = await self.configuration.clock.nowMilliseconds()
        let loop = MoshSSPInMemoryLoop(
            initialSendState: MoshTerminalClientState(),
            initialReceiveState: MoshTerminalHostState(
                dimensions: self.configuration.initialTerminalDimensions
            ),
            initialNowMilliseconds: initialNowMilliseconds,
            timing: self.configuration.timing,
            maximumSerializedFragmentByteCount: self.configuration.maximumSerializedFragmentByteCount,
            chaffSource: self.configuration.chaffSource
        )
        let sequencer = try MoshDatagramSequencer(
            sessionKey: self.configuration.endpoint.sessionKey,
            sendDirection: .toServer,
            receiveDirection: .toClient
        )
        let runtime = MoshSSPDatagramRuntime(
            loop: loop,
            sequencer: sequencer,
            link: link,
            clock: self.configuration.clock
        )

        do {
            try await runtime.start()
            let initialDimensions = self.configuration.initialTerminalDimensions
            await runtime.modifyCurrentState { state in
                state.append(.resize(initialDimensions))
            }

            self.runtime = runtime
            self.isStarted = true
            self.startedAtMilliseconds = initialNowMilliseconds
            self.hasEmittedNoContact = false
            self.startReceiveTask(runtime: runtime)
            self.startLinkEventTask(runtime: runtime)
            self.diagnosticEventContinuation.yield(
                .started(
                    host: self.configuration.endpoint.host,
                    port: self.configuration.endpoint.port
                )
            )
            _ = try await self.sendDueDatagrams()
            self.restartMaintenanceTask(runtime: runtime)
        } catch {
            await self.finishFromStartFailure(runtime: runtime, throwing: error)
            throw error
        }
    }

    public func stop() async {
        guard self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.isStarted = false
        self.maintenanceGeneration &+= 1
        self.receiveTask?.cancel()
        self.receiveTask = nil
        self.maintenanceTask?.cancel()
        self.maintenanceTask = nil
        self.linkEventTask?.cancel()
        self.linkEventTask = nil
        await self.runtime?.stop()
        self.runtime = nil
        self.hostOperationContinuation.finish()
        self.renderOperationContinuation.finish()
        self.finishStopWaiters(throwing: nil)
        self.diagnosticEventContinuation.yield(.stopped)
        self.diagnosticEventContinuation.finish()
    }

    public func shutdown() async throws {
        try self.requireStarted()
        guard let runtime = self.runtime else {
            throw MoshSessionError.notStarted
        }

        self.cancelMaintenanceTask()
        do {
            await runtime.startShutdown()
            _ = try await self.sendDueDatagrams()
            guard self.isStarted, self.isStopped == false else {
                return
            }
            self.restartMaintenanceTask(runtime: runtime)
            try await self.waitUntilStopped()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await self.finishFromMaintenanceTask(
                throwing: error,
                generation: self.maintenanceGeneration
            )
            throw error
        }
    }

    public func sendKeystrokes(_ bytes: [UInt8]) async throws {
        guard bytes.isEmpty == false else {
            return
        }

        try self.requireStarted()
        await self.registerUserPrediction(bytes)
        try await self.updateClientState(.keystrokes(bytes))
    }

    public func sendTerminalInput(
        _ bytes: [UInt8],
        applicationCursorKeysEnabled: Bool
    ) async throws {
        guard bytes.isEmpty == false else {
            return
        }

        try self.requireStarted()
        let translatedBytes = self.userInputTranslator.translate(
            bytes,
            applicationCursorKeysEnabled: applicationCursorKeysEnabled
        )
        await self.registerUserPrediction(bytes)
        guard translatedBytes.isEmpty == false else {
            return
        }

        try await self.updateClientState(.keystrokes(translatedBytes))
    }

    public func sendTerminalInput(_ bytes: [UInt8]) async throws {
        try await self.sendKeystrokes(bytes)
    }

    public func resize(columns: Int32, rows: Int32) async throws {
        try await self.resize(MoshTerminalDimensions(columns: columns, rows: rows))
    }

    public func resize(_ dimensions: MoshTerminalDimensions) async throws {
        try await self.updateClientState(.resize(dimensions))
    }

    private func updateClientState(_ operation: MoshClientOperation) async throws {
        try self.requireStarted()
        guard let runtime = self.runtime else {
            throw MoshSessionError.notStarted
        }

        self.cancelMaintenanceTask()
        await runtime.modifyCurrentState { state in
            state.append(operation)
        }
        do {
            _ = try await self.sendDueDatagrams()
        } catch is CancellationError {
            if self.isStarted, self.isStopped == false {
                self.restartMaintenanceTask(runtime: runtime)
            }
            throw CancellationError()
        } catch {
            await self.finishFromClientUpdateFailure(throwing: error)
            throw error
        }
        guard self.isStarted, self.isStopped == false else {
            return
        }
        self.restartMaintenanceTask(runtime: runtime)
    }

    @discardableResult
    private func sendDueDatagrams() async throws -> Bool {
        try self.requireStarted()
        guard let runtime = self.runtime else {
            throw MoshSessionError.notStarted
        }
        guard let batch = try await runtime.sendDueDatagrams() else {
            return false
        }
        guard self.isStarted, self.isStopped == false else {
            return false
        }

        self.diagnosticEventContinuation.yield(
            .datagramsSent(packetCount: batch.packets.count)
        )
        return true
    }

    private func handleIncomingInstruction(
        _ instruction: MoshSSPDatagramIncomingInstruction<MoshTerminalHostState>
    ) async throws {
        // Any received instruction is fresh contact with the server: clear the
        // no-contact latch so a subsequent outage re-emits the diagnostic.
        self.hasEmittedNoContact = false
        let state = instruction.instructionResult.latestState
        // Adopt the newest received framebuffer wholesale (mirrors stmclient.cc's
        // `new_state = network->get_latest_remote_state().state.get_fb()`) instead
        // of replaying operations. Only advance when a strictly newer state
        // arrives, so a duplicate/heartbeat never re-yields host operations.
        var operations: [MoshHostOperation] = []
        if state.number > self.lastAdoptedHostStateNumber {
            self.lastAdoptedHostStateNumber = state.number
            operations = self.terminalEngine.acceptHostState(state.state)
            self.terminalScreen = state.state.terminalScreen
            for operation in operations {
                self.hostOperationContinuation.yield(operation)
                if let renderOperation = MoshTerminalRenderOperation(operation) {
                    self.renderOperationContinuation.yield(renderOperation)
                }
            }
            let generatedTerminalToHostBytes = state.state.lastAppliedTerminalToHostBytes
            if generatedTerminalToHostBytes.isEmpty == false {
                try await self.updateClientState(.keystrokes(generatedTerminalToHostBytes))
            }
        }
        await self.updatePredictionHints(runtime: self.runtime, hostState: state.state)
        self.predictionEngine.cull(
            baseSnapshot: self.terminalScreen.snapshot,
            nowMilliseconds: await self.configuration.clock.nowMilliseconds()
        )
        self.diagnosticEventContinuation.yield(
            .hostStateReceived(number: state.number, operationCount: operations.count)
        )
        // Detect a counterparty (server) shutdown. Official Mosh recognizes this
        // when the server sends the shutdown-sentinel state number (`uint64_t(-1)`),
        // which the receiver adopts as its latest state so `sender.set_ack_num`
        // records `uint64_t(-1)`; the client then acknowledges once and exits
        // cleanly (`stmclient.cc` ~531-533, `counterparty_shutdown_ack_sent`). We
        // mirror this without inventing wire behavior: the receiver's
        // acknowledgement number becoming `UInt64.max` means our latest received
        // state IS that shutdown sentinel. We render the final adopted state above
        // first (as official does before breaking its loop), then finish the
        // host/render streams cleanly so `hostOperations` consumers do not hang.
        let counterpartyInitiatedShutdown =
            instruction.instructionResult.acknowledgementNumber == Self.shutdownSentinelStateNumber
        if let runtime = self.runtime, self.isStarted, self.isStopped == false {
            if counterpartyInitiatedShutdown {
                self.diagnosticEventContinuation.yield(.peerShutdown)
                await self.stop()
                return
            }
            if await runtime.shutdownAcknowledged() {
                await self.stop()
                return
            }
            self.restartMaintenanceTask(runtime: runtime)
        }
    }

    /// The wire state number a peer sends to signal shutdown (`uint64_t(-1)` in
    /// official Mosh). When our receiver's acknowledgement number reaches this
    /// value, the peer has initiated shutdown.
    private static var shutdownSentinelStateNumber: UInt64 { UInt64.max }

    private func finishFromReceiveTask(throwing error: Error?) async {
        guard self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.isStarted = false
        self.maintenanceGeneration &+= 1
        self.maintenanceTask?.cancel()
        self.maintenanceTask = nil
        self.linkEventTask?.cancel()
        self.linkEventTask = nil
        await self.runtime?.stop()
        self.runtime = nil
        if let error {
            self.hostOperationContinuation.finish(throwing: error)
            self.renderOperationContinuation.finish(throwing: error)
        } else {
            self.hostOperationContinuation.finish()
            self.renderOperationContinuation.finish()
        }
        self.finishStopWaiters(throwing: error)
        self.diagnosticEventContinuation.yield(.stopped)
        self.diagnosticEventContinuation.finish()
    }

    private func finishFromStartFailure(
        runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>,
        throwing error: Error
    ) async {
        guard self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.isStarted = false
        self.maintenanceGeneration &+= 1
        self.receiveTask?.cancel()
        self.receiveTask = nil
        self.maintenanceTask?.cancel()
        self.maintenanceTask = nil
        self.linkEventTask?.cancel()
        self.linkEventTask = nil
        await runtime.stop()
        self.runtime = nil
        self.hostOperationContinuation.finish(throwing: error)
        self.renderOperationContinuation.finish(throwing: error)
        self.finishStopWaiters(throwing: error)
        self.diagnosticEventContinuation.yield(.stopped)
        self.diagnosticEventContinuation.finish()
    }

    private func finishFromClientUpdateFailure(throwing error: Error) async {
        guard self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.isStarted = false
        self.maintenanceGeneration &+= 1
        self.receiveTask?.cancel()
        self.receiveTask = nil
        self.maintenanceTask?.cancel()
        self.maintenanceTask = nil
        self.linkEventTask?.cancel()
        self.linkEventTask = nil
        await self.runtime?.stop()
        self.runtime = nil
        self.hostOperationContinuation.finish(throwing: error)
        self.renderOperationContinuation.finish(throwing: error)
        self.finishStopWaiters(throwing: error)
        self.diagnosticEventContinuation.yield(.stopped)
        self.diagnosticEventContinuation.finish()
    }

    private func requireStarted() throws {
        guard self.isStopped == false else {
            throw MoshSessionError.stopped
        }
        guard self.isStarted else {
            throw MoshSessionError.notStarted
        }
    }

    private func registerUserPrediction(_ bytes: [UInt8]) async {
        guard bytes.isEmpty == false,
              let runtime = self.runtime else {
            return
        }

        await self.updatePredictionHints(runtime: runtime, hostState: self.terminalEngine.hostState)
        self.predictionEngine.setLocalFrameSent(await runtime.lastSentSendStateNumber())
        self.predictionEngine.registerUserInput(
            bytes,
            baseSnapshot: self.terminalScreen.snapshot,
            nowMilliseconds: await self.configuration.clock.nowMilliseconds()
        )
    }

    private func updatePredictionHints(
        runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>?,
        hostState: MoshTerminalHostState
    ) async {
        if let runtime {
            self.predictionEngine.setLocalFrameAcknowledged(
                await runtime.knownAcknowledgedSendStateNumber()
            )
            self.predictionEngine.setSendIntervalMilliseconds(
                await runtime.sendIntervalMilliseconds()
            )
        }

        if let latestEchoAcknowledgementNumber = hostState.latestEchoAcknowledgementNumber {
            self.predictionEngine.setLocalFrameLateAcknowledged(latestEchoAcknowledgementNumber)
        }
    }

    private func finishFromMaintenanceTask(
        throwing error: Error,
        generation: UInt64
    ) async {
        guard self.maintenanceGeneration == generation, self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.isStarted = false
        self.maintenanceGeneration &+= 1
        self.receiveTask?.cancel()
        self.receiveTask = nil
        self.maintenanceTask = nil
        self.linkEventTask?.cancel()
        self.linkEventTask = nil
        await self.runtime?.stop()
        self.runtime = nil
        self.hostOperationContinuation.finish(throwing: error)
        self.renderOperationContinuation.finish(throwing: error)
        self.finishStopWaiters(throwing: error)
        self.diagnosticEventContinuation.yield(.stopped)
        self.diagnosticEventContinuation.finish()
    }

    private func startReceiveTask(
        runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>
    ) {
        let stream = runtime.incomingInstructions
        self.receiveTask = Task { [weak self] in
            do {
                for try await instruction in stream {
                    try Task.checkCancellation()
                    guard let self else {
                        return
                    }
                    try await self.handleIncomingInstruction(instruction)
                }

                guard let self else {
                    return
                }
                await self.finishFromReceiveTask(throwing: nil)
            } catch is CancellationError {
                guard let self else {
                    return
                }
                await self.finishFromReceiveTask(throwing: nil)
            } catch {
                guard let self else {
                    return
                }
                await self.finishFromReceiveTask(throwing: error)
            }
        }
    }

    /// Listen for the runtime's out-of-band transport-lifecycle signals. On a
    /// `.linkFailed`, drive the bounded rebuild policy. The runtime keeps its crypto
    /// session and SSP state alive across the failure, so a successful rebuild
    /// resumes the SAME session on a fresh socket.
    private func startLinkEventTask(
        runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>
    ) {
        let linkEvents = runtime.linkEvents
        self.linkEventTask = Task { [weak self] in
            for await event in linkEvents {
                guard let self else {
                    return
                }
                switch event {
                case .linkFailed:
                    await self.rebuildLink(runtime: runtime)
                }
            }
        }
    }

    /// Bounded, backed-off automatic link rebuild after transport death. Mirrors
    /// official Mosh's port hop (`Connection::hop_port`): a new socket is opened to
    /// the same endpoint while the crypto session and send sequence continue
    /// unchanged (`runtime.replaceLink` preserves the `~Copyable` sequencer). The
    /// SSP retransmit timer then re-sends unacknowledged state over the new link.
    private func rebuildLink(
        runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>
    ) async {
        guard self.isStarted, self.isStopped == false else {
            return
        }
        // Serialize: a second `.linkFailed` while a rebuild is in flight is ignored.
        guard self.isRebuildingLink == false else {
            return
        }
        self.isRebuildingLink = true
        defer { self.isRebuildingLink = false }

        var attempt = 0
        while self.isStarted, self.isStopped == false {
            attempt += 1
            self.diagnosticEventContinuation.yield(.reconnecting(attempt: attempt))
            do {
                let newLink = try await self.configuration.transportFactory.makeDatagramLink(
                    for: self.configuration.endpoint
                )
                try Task.checkCancellation()
                guard self.isStarted, self.isStopped == false else {
                    await newLink.stop()
                    return
                }
                try await runtime.replaceLink(newLink)
                self.diagnosticEventContinuation.yield(.reconnected)
                self.hasEmittedNoContact = false
                // Resume the maintenance/retransmit loop against the new link.
                self.restartMaintenanceTask(runtime: runtime)
                return
            } catch is CancellationError {
                return
            } catch {
                if let maximumAttempts = self.configuration.resilience.maximumLinkRebuildAttempts,
                   attempt >= maximumAttempts {
                    await self.finishFromLinkRebuildFailure(throwing: error)
                    return
                }
                let backoffMilliseconds = self.rebuildBackoffMilliseconds(attempt: attempt)
                do {
                    try await self.configuration.timer.sleep(forMilliseconds: backoffMilliseconds)
                } catch {
                    return
                }
            }
        }
    }

    private func rebuildBackoffMilliseconds(attempt: Int) -> UInt64 {
        let resilience = self.configuration.resilience
        let exponent = max(0, attempt - 1)
        var backoff = resilience.initialRebuildBackoffMilliseconds
        for _ in 0..<exponent {
            if backoff >= resilience.maximumRebuildBackoffMilliseconds / 2 {
                return resilience.maximumRebuildBackoffMilliseconds
            }
            backoff *= 2
        }
        return min(backoff, resilience.maximumRebuildBackoffMilliseconds)
    }

    private func finishFromLinkRebuildFailure(throwing error: Error) async {
        guard self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.isStarted = false
        self.maintenanceGeneration &+= 1
        self.receiveTask?.cancel()
        self.receiveTask = nil
        self.maintenanceTask?.cancel()
        self.maintenanceTask = nil
        self.linkEventTask?.cancel()
        self.linkEventTask = nil
        await self.runtime?.stop()
        self.runtime = nil
        self.hostOperationContinuation.finish(throwing: error)
        self.renderOperationContinuation.finish(throwing: error)
        self.finishStopWaiters(throwing: error)
        self.diagnosticEventContinuation.yield(.stopped)
        self.diagnosticEventContinuation.finish()
    }

    /// Emit a single informational `.noContact` diagnostic when the server has not
    /// been heard from for at least the configured threshold. Latched so at most one
    /// event fires per outage; reset once contact resumes (`handleIncomingInstruction`,
    /// `rebuildLink`). Never tears the session down.
    private func emitNoContactIfNeeded(
        runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>
    ) async {
        guard self.hasEmittedNoContact == false, self.isStarted, self.isStopped == false else {
            return
        }
        let threshold = self.configuration.resilience.noContactThresholdMilliseconds
        guard threshold > 0 else {
            return
        }

        let nowMilliseconds = await self.configuration.clock.nowMilliseconds()
        let reference = await runtime.lastHeardAtMilliseconds() ?? self.startedAtMilliseconds
        guard nowMilliseconds >= reference else {
            return
        }
        let sinceLastHeard = nowMilliseconds - reference
        guard sinceLastHeard >= threshold else {
            return
        }

        self.hasEmittedNoContact = true
        self.diagnosticEventContinuation.yield(
            .noContact(millisecondsSinceLastHeard: sinceLastHeard)
        )
    }

    private func restartMaintenanceTask(
        runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>
    ) {
        self.cancelMaintenanceTask()
        let generation = self.maintenanceGeneration
        self.maintenanceTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.runMaintenanceLoop(runtime: runtime, generation: generation)
        }
    }

    private func runMaintenanceLoop(
        runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>,
        generation: UInt64
    ) async {
        do {
            while self.shouldContinueMaintenance(generation: generation) {
                guard let waitMilliseconds = try await runtime.waitTime() else {
                    return
                }

                guard self.shouldContinueMaintenance(generation: generation) else {
                    return
                }

                if waitMilliseconds > 0 {
                    try await self.configuration.timer.sleep(
                        forMilliseconds: waitMilliseconds
                    )
                }

                try Task.checkCancellation()
                guard self.shouldContinueMaintenance(generation: generation) else {
                    return
                }

                // A tick that finds nothing due is BENIGN, exactly as official Mosh's
                // `TransportSender::tick` (`network/transportsender-impl.h` ~138-187):
                // when no diff/ack needs sending it simply recomputes timers (clearing
                // `next_send_time`) and returns — there is no error path that ends the
                // session. `waitTime()` and `sendDueDatagrams()` are separate actor hops
                // (each awaits the clock), so an in-flight inbound datagram can legitimately
                // erase the due-ness the scheduler reported at `waitTime()` — e.g. an ACK
                // makes the current state match the assumed-receiver state (`nextSendAt` →
                // nil), or a timestamp-reply raises SRTT and pushes `nextSendAt` into the
                // future. Treating that as fatal tore down healthy sessions nondeterministically.
                // We do not spin: after such a no-op the scheduler's timer has recomputed to
                // a positive wait or nil (the assumed-receiver freshness reset guarantees a
                // consistent state never reports a due send with an empty diff), so the loop
                // re-evaluates `waitTime()` and then sleeps or exits.
                _ = try await self.sendDueDatagrams()
                await self.emitNoContactIfNeeded(runtime: runtime)
                if await runtime.shutdownTimedOut() {
                    throw MoshSessionError.shutdownTimedOut
                }
                if await runtime.shutdownAcknowledged() {
                    await self.stop()
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            await self.finishFromMaintenanceTask(throwing: error, generation: generation)
        }
    }

    private func shouldContinueMaintenance(generation: UInt64) -> Bool {
        self.isStarted && self.isStopped == false && self.maintenanceGeneration == generation
    }

    private func cancelMaintenanceTask() {
        self.maintenanceGeneration &+= 1
        self.maintenanceTask?.cancel()
        self.maintenanceTask = nil
    }

    private func waitUntilStopped() async throws {
        if self.isStopped {
            return
        }

        let waiterID = self.nextStopWaiterID
        self.nextStopWaiterID &+= 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.storeStopWaiter(id: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task {
                await self.cancelStopWaiter(id: waiterID)
            }
        }
    }

    private func storeStopWaiter(
        id: UInt64,
        continuation: CheckedContinuation<Void, Error>
    ) {
        if self.isStopped {
            continuation.resume()
            return
        }
        if self.cancelledStopWaiterIDs.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.stopWaiters[id] = continuation
    }

    private func cancelStopWaiter(id: UInt64) {
        if let continuation = self.stopWaiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            self.cancelledStopWaiterIDs.insert(id)
        }
    }

    private func finishStopWaiters(throwing error: Error?) {
        let waiters = Array(self.stopWaiters.values)
        self.stopWaiters.removeAll()
        self.cancelledStopWaiterIDs.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }

    private static func makeHostOperationStream(
        bufferingPolicy: HostOperationStream.Continuation.BufferingPolicy
    ) -> (stream: HostOperationStream, continuation: HostOperationStream.Continuation) {
        var capturedContinuation: HostOperationStream.Continuation?
        let stream = HostOperationStream(bufferingPolicy: bufferingPolicy) { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }

        return (stream, capturedContinuation)
    }

    private static func makeRenderOperationStream(
        bufferingPolicy: RenderOperationStream.Continuation.BufferingPolicy
    ) -> (stream: RenderOperationStream, continuation: RenderOperationStream.Continuation) {
        var capturedContinuation: RenderOperationStream.Continuation?
        let stream = RenderOperationStream(bufferingPolicy: bufferingPolicy) { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }

        return (stream, capturedContinuation)
    }

    private static func makeDiagnosticEventStream(
        bufferingPolicy: DiagnosticEventStream.Continuation.BufferingPolicy
    ) -> (stream: DiagnosticEventStream, continuation: DiagnosticEventStream.Continuation) {
        var capturedContinuation: DiagnosticEventStream.Continuation?
        let stream = DiagnosticEventStream(bufferingPolicy: bufferingPolicy) { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncStream did not provide a continuation")
        }

        return (stream, capturedContinuation)
    }
}
