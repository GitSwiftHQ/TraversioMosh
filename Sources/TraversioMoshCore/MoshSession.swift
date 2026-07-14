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
    /// Maximum number of consecutive link-rebuild attempts before the session
    /// gives up and tears down. An attempt only stops counting as consecutive
    /// once the server is actually HEARD on a rebuilt link — merely installing a
    /// fresh socket proves nothing (`NWConnection.start()` returns before any
    /// contact), so a dead network cannot launder the counter through rebuilds
    /// that "succeed" and immediately fail again. `nil` retries indefinitely
    /// (bounded only by backoff), matching Mosh's promise that a session
    /// survives arbitrarily long outages.
    public var maximumLinkRebuildAttempts: Int?
    /// Backoff between rebuild attempts (ms), doubling per consecutive attempt.
    /// Clamped to at least 1 ms so the doubling can never degenerate into a
    /// zero-delay retry loop.
    public var initialRebuildBackoffMilliseconds: UInt64
    /// Upper bound on the exponential backoff interval (ms).
    public var maximumRebuildBackoffMilliseconds: UInt64
    /// When the server has been silent for at least this long AND the current
    /// link has been installed for at least this long, the session proactively
    /// rebuilds the link (fresh socket = fresh source port) even though the
    /// transport never reported a failure. This is the client port hop official
    /// Mosh performs in `Connection::send` (`network/network.cc`,
    /// `PORT_HOP_INTERVAL` = 10 s): the dominant transport-death mode — a NAT
    /// mapping silently dropped or a UDP path blackholed — never faults the
    /// socket, so recovery must be time-driven, not error-driven. `0` disables.
    public var portHopIntervalMilliseconds: UInt64
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
        portHopIntervalMilliseconds: UInt64 = 10_000,
        noContactThresholdMilliseconds: UInt64 = 60_000
    ) {
        self.maximumLinkRebuildAttempts = maximumLinkRebuildAttempts
        self.initialRebuildBackoffMilliseconds = max(1, initialRebuildBackoffMilliseconds)
        self.maximumRebuildBackoffMilliseconds = max(
            self.initialRebuildBackoffMilliseconds,
            maximumRebuildBackoffMilliseconds
        )
        self.portHopIntervalMilliseconds = portHopIntervalMilliseconds
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
    /// Description of the most recent `link.send` failure that was recorded and
    /// swallowed (transient send tolerance), or `nil` if the last send
    /// succeeded. Mirrors official `Connection::send_error` and is the host's
    /// immediate signal of an outbound outage, ahead of the slower `.noContact`
    /// diagnostic.
    public let recordedSendErrorDescription: String?

    public init(
        lastHeardFromServerMilliseconds: UInt64?,
        millisecondsSinceLastHeard: UInt64,
        smoothedRoundTripMilliseconds: Double,
        roundTripVariationMilliseconds: Double,
        recordedSendErrorDescription: String? = nil
    ) {
        self.lastHeardFromServerMilliseconds = lastHeardFromServerMilliseconds
        self.millisecondsSinceLastHeard = millisecondsSinceLastHeard
        self.smoothedRoundTripMilliseconds = smoothedRoundTripMilliseconds
        self.roundTripVariationMilliseconds = roundTripVariationMilliseconds
        self.recordedSendErrorDescription = recordedSendErrorDescription
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
    /// The configured `maximumLinkRebuildAttempts` consecutive rebuild attempts
    /// elapsed without the server being heard from again.
    case linkRebuildAttemptsExhausted
}

public enum MoshSessionEvent: Equatable, Sendable {
    /// The session started against the given host and port. Deliberately carries
    /// only the non-secret endpoint summary (not the live `MoshSessionKey`), so a
    /// diagnostic-stream consumer never holds or renders key material.
    case started(host: String, port: UInt16)
    case datagramsSent(packetCount: Int)
    case hostStateReceived(number: UInt64, operationCount: Int)
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
    /// The server was heard from again on a rebuilt link. Deliberately NOT
    /// emitted when the fresh link is merely installed — a socket that opens
    /// against a dead network proves nothing — so this event means actual
    /// recovery, mirroring official Mosh crediting `last_roundtrip_success`.
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

    /// Raw wire operations decoded from server diffs, forwarded only when a diff
    /// chains from the exact host state this stream last rendered.
    ///
    /// This stream emits NOTHING for a re-based diff (one whose `oldNumber` is not
    /// the last-rendered state, possible whenever an acknowledgement is lost) and
    /// carries no resync signal, so it is not sufficient for exact incremental
    /// reconstruction of the screen across a rebase. Consumers that need display
    /// fidelity must use `renderOperations` (which carries
    /// `MoshTerminalRenderOperation.resync`) or read `screenSnapshot`.
    public nonisolated let hostOperations: HostOperationStream
    /// Display-ready operations. Unlike `hostOperations`, this stream emits a
    /// `MoshTerminalRenderOperation.resync(snapshot)` on a re-based diff, so an
    /// incremental consumer can stay exact across rebases.
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
    /// Rebuild attempts since the server was last heard. Reset ONLY by actual
    /// contact (`handleIncomingInstruction`), never by installing a link, so
    /// backoff and the attempt bound survive install-then-die churn.
    private var consecutiveRebuildAttempts = 0
    /// Set when a rebuilt link is installed; the next received instruction
    /// emits `.reconnected` and clears it.
    private var awaitingRebuildContact = false
    /// Clock time the current link was installed (session start or rebuild).
    /// Gates the port-hop interval so a freshly hopped link gets a full
    /// interval to prove itself before the next hop.
    private var lastLinkInstalledAtMilliseconds: UInt64 = 0
    private var hasEmittedNoContact = false
    private var nextStopWaiterID: UInt64 = 0
    private var stopWaiters: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var cancelledStopWaiterIDs: Set<UInt64> = []
    /// Distinguishes concurrent `start()` attempts. Bumped at the top of every
    /// `start()` call, before its first suspension point, so an attempt that
    /// resumes from an await can tell whether a later `start()` call has since
    /// become the current one and must not overwrite that attempt's state.
    private var startGeneration: UInt64 = 0
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
            let recordedSendError = await self.runtime?.recordedSendError()
            return MoshSessionLiveness(
                lastHeardFromServerMilliseconds: lastHeard,
                millisecondsSinceLastHeard: sinceLastHeard,
                smoothedRoundTripMilliseconds: smoothedRoundTrip,
                roundTripVariationMilliseconds: roundTripVariation,
                recordedSendErrorDescription: recordedSendError
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

        self.startGeneration &+= 1
        let myStartGeneration = self.startGeneration

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
        } catch {
            // Not committed to `self` yet, so a concurrent `stop()` cannot have
            // reached this runtime (it saw `self.runtime == nil`) and a
            // concurrent WINNING `start()` must not be torn down by our
            // failure. Only run the shared failure cleanup when neither raced
            // us; otherwise just stop the runtime this attempt created.
            if self.startGeneration == myStartGeneration, self.isStopped == false {
                await self.finishFromStartFailure(runtime: runtime, throwing: error)
            } else {
                await runtime.stop()
            }
            throw error
        }

        // Re-validate after every suspension above: while this attempt was
        // suspended, a concurrent `stop()` may have run to completion (it saw
        // `self.runtime == nil` and so could not reach this runtime), or a
        // second concurrent `start()` may have claimed a newer
        // `startGeneration` and already committed. Committing unconditionally
        // here is exactly the reentrancy race that let a "stopped" session
        // silently come back with a live, uncancellable runtime, or let a
        // superseded attempt overwrite the winner's state.
        guard self.startGeneration == myStartGeneration else {
            await runtime.stop()
            throw MoshSessionError.alreadyStarted
        }
        guard self.isStopped == false else {
            await runtime.stop()
            throw MoshSessionError.stopped
        }

        self.runtime = runtime
        self.isStarted = true
        self.startedAtMilliseconds = initialNowMilliseconds
        self.lastLinkInstalledAtMilliseconds = initialNowMilliseconds
        self.hasEmittedNoContact = false
        self.startReceiveTask(runtime: runtime)
        self.startLinkEventTask(runtime: runtime)
        self.diagnosticEventContinuation.yield(
            .started(
                host: self.configuration.endpoint.host,
                port: self.configuration.endpoint.port
            )
        )

        do {
            _ = try await self.sendDueDatagrams()
        } catch {
            await self.finishFromStartFailure(runtime: runtime, throwing: error)
            throw error
        }

        // A second `start()` can no longer win from here on: `isStarted` is
        // already true, so any concurrent call is rejected at the top of this
        // method before it can touch `startGeneration`. Only a genuine
        // stop-like transition can invalidate this attempt now, and every one
        // of those stops `self.runtime` itself before setting `isStopped`.
        guard self.isStopped == false else {
            return
        }
        self.restartMaintenanceTask(runtime: runtime)
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

        // Only claim datagrams were sent if the link accepted them: a batch
        // whose sends were all recorded-and-swallowed (transient tolerance)
        // must not read as healthy outbound traffic. The failure itself is
        // visible via `liveness.recordedSendErrorDescription`.
        if await runtime.recordedSendError() == nil {
            self.diagnosticEventContinuation.yield(
                .datagramsSent(packetCount: batch.packets.count)
            )
        }
        return true
    }

    private func handleIncomingInstruction(
        _ instruction: MoshSSPDatagramIncomingInstruction<MoshTerminalHostState>
    ) async throws {
        // Connection-level "fresh contact" is credited only for an in-sequence
        // (`.new`) datagram. An authentic but out-of-order/duplicate datagram
        // arrives as `.replayed`; its payload is still valid state data and is
        // adopted below (official `recv_one` delivers it), but it does NOT prove
        // the link is currently alive — the server may have gone silent after
        // the original transmission. The rest of the codebase gates
        // connection-level last-heard on in-sequence datagrams for exactly this
        // reason, so a replay cannot mask an outage; this spot must match.
        // Clearing the no-contact latch, resetting the consecutive-rebuild
        // counter, and crediting a pending rebuild (`.reconnected`) are all
        // connection-level contact signals, so they run only for `.new`.
        let isFreshContact: Bool
        switch instruction.receivedDatagram.sequenceStatus {
        case .new:
            isFreshContact = true
        case .replayed:
            isFreshContact = false
        }
        if isFreshContact {
            // Being HEARD in-sequence, not installing a socket, is what proves
            // recovery (official Mosh credits `last_roundtrip_success`).
            self.hasEmittedNoContact = false
            self.consecutiveRebuildAttempts = 0
            if self.awaitingRebuildContact {
                self.awaitingRebuildContact = false
                self.diagnosticEventContinuation.yield(.reconnected)
            }
        }
        let state = instruction.instructionResult.latestState
        // Adopt the newest received framebuffer wholesale (mirrors stmclient.cc's
        // `new_state = network->get_latest_remote_state().state.get_fb()`) instead
        // of replaying operations. Only advance when a strictly newer state
        // arrives, so a duplicate/heartbeat never re-yields host operations.
        var operations: [MoshHostOperation] = []
        if state.number > self.lastAdoptedHostStateNumber {
            // A diff's operations can be forwarded incrementally only when the
            // diff chains from the exact state this session last adopted. A
            // re-based diff (the server recomputed against an older reference
            // after a lost acknowledgement) is relative to a frame the stream
            // consumer never rendered; forwarding it would double-apply
            // overlapping content. Official Mosh never forwards wire diffs —
            // its client recomputes every frame from the latest framebuffer
            // (`display.new_frame`) — so on a re-base we emit a wholesale
            // `.resync` instead. The host-operation stream, which carries raw
            // wire operations, emits nothing for a re-based diff.
            let chainsFromAdoptedState =
                instruction.instructionResult.instruction.oldNumber == self.lastAdoptedHostStateNumber
            self.lastAdoptedHostStateNumber = state.number
            operations = self.terminalEngine.acceptHostState(state.state)
            self.terminalScreen = state.state.terminalScreen
            if chainsFromAdoptedState {
                // `renderOperations` defaults to a bounded `.bufferingNewest`
                // policy: once full, a yield still succeeds for the value just
                // passed in, but silently evicts an earlier, not-yet-consumed
                // operation to make room, reported back as `.dropped`. An
                // incremental consumer that missed an evicted operation is left
                // permanently out of sync with every later chained diff unless
                // told to resync. Observe that signal and, on the first drop in
                // this batch, stop trying more granular operations (`terminalScreen`
                // already reflects the final adopted state regardless of how many
                // of this batch's operations were attempted) and fall back to a
                // wholesale resync — the same repair already used for a re-based
                // diff below. `hostOperations` has no resync concept and is
                // unaffected: it keeps receiving every operation in this batch.
                var renderStreamOutOfSync = false
                for operation in operations {
                    self.hostOperationContinuation.yield(operation)
                    guard renderStreamOutOfSync == false,
                          let renderOperation = MoshTerminalRenderOperation(operation) else {
                        continue
                    }
                    if case .dropped = self.renderOperationContinuation.yield(renderOperation) {
                        renderStreamOutOfSync = true
                    }
                }
                if renderStreamOutOfSync {
                    self.renderOperationContinuation.yield(
                        .resync(self.terminalScreen.snapshot)
                    )
                }
            } else {
                self.renderOperationContinuation.yield(
                    .resync(self.terminalScreen.snapshot)
                )
            }
            // Terminal-generated replies (DA/DSR) captured while applying the
            // diff are deliberately NOT transmitted. In official Mosh the
            // server-side emulator answers such queries; the client never
            // sends terminal replies (`Complete::apply_string` asserts
            // `terminal_to_host.empty()`). Transmitting them would inject
            // duplicate bytes whenever a re-based diff re-applies a query, and
            // would hand a hostile server a keystroke-injection channel.
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
                await self.acknowledgeCounterpartyShutdown(runtime: runtime)
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

    /// Official Mosh does not exit on merely SEEING the shutdown sentinel: the
    /// client keeps ticking until a datagram carrying `ack_num = uint64_t(-1)`
    /// has actually been sent (`counterparty_shutdown_ack_sent()`,
    /// `frontend/stmclient.cc` ~530), so the server can stop retransmitting its
    /// final state instead of retrying for up to 10 s. Mirror that here: once
    /// the sentinel is adopted, every outgoing instruction carries
    /// acknowledgement `UInt64.max`, so drive the scheduler until one batch
    /// leaves. The scheduler's shutdown speed-up keeps the wait within a send
    /// interval; the iteration bound keeps a dead link from stalling `stop()` —
    /// best-effort delivery is all official offers too (the server has its own
    /// shutdown retry timeout).
    private func acknowledgeCounterpartyShutdown(
        runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>
    ) async {
        for _ in 0..<8 {
            guard self.isStarted, self.isStopped == false else {
                return
            }
            if (try? await self.sendDueDatagrams()) == true {
                return
            }
            guard let waitMilliseconds = try? await runtime.waitTime() else {
                return
            }
            if waitMilliseconds > 0 {
                do {
                    try await self.configuration.timer.sleep(forMilliseconds: waitMilliseconds)
                } catch {
                    return
                }
            }
        }
    }

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
    ///
    /// Installing a link is NOT success: `NWConnection.start()` returns before
    /// any contact, so against a dead network every install would trivially
    /// "succeed" and immediately fail again. Attempts therefore accumulate in
    /// `consecutiveRebuildAttempts` — reset only when the server is actually
    /// heard (`handleIncomingInstruction`) — so backoff keeps growing and the
    /// configured attempt bound is enforced across install-then-die churn, and
    /// `.reconnected` is deferred until real contact.
    ///
    /// The endpoint handed back to the factory is the one the session was
    /// configured with; per the documented host responsibility, hosts should
    /// resolve DNS once and configure an address, so a rebuild does not
    /// re-resolve to a different server mid-session.
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

        var lastFailure: Error?
        while self.isStarted, self.isStopped == false {
            self.consecutiveRebuildAttempts += 1
            let attempt = self.consecutiveRebuildAttempts
            if let maximumAttempts = self.configuration.resilience.maximumLinkRebuildAttempts,
               attempt > maximumAttempts {
                await self.finishFromLinkRebuildFailure(
                    throwing: lastFailure ?? MoshSessionError.linkRebuildAttemptsExhausted
                )
                return
            }
            if attempt > 1 {
                let backoffMilliseconds = self.rebuildBackoffMilliseconds(attempt: attempt)
                do {
                    try await self.configuration.timer.sleep(forMilliseconds: backoffMilliseconds)
                } catch {
                    return
                }
                guard self.isStarted, self.isStopped == false else {
                    return
                }
            }
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
                self.awaitingRebuildContact = true
                self.lastLinkInstalledAtMilliseconds = await self.configuration.clock.nowMilliseconds()
                // Resume the maintenance/retransmit loop against the new link.
                // `.reconnected` waits for the server to actually be heard.
                self.restartMaintenanceTask(runtime: runtime)
                return
            } catch is CancellationError {
                return
            } catch {
                lastFailure = error
            }
        }
    }

    /// Time-driven client port hop, official Mosh's actual recovery mechanism
    /// for silent transport death (`Connection::send`, `network/network.cc`
    /// ~396: hop when nothing has been heard for `PORT_HOP_INTERVAL` and the
    /// current port choice is at least that old). A NAT mapping that silently
    /// expires or a blackholed UDP path never faults the socket, so the
    /// `.linkFailed`-driven rebuild can never fire for the dominant death mode;
    /// this check, run from the maintenance loop, covers it.
    private func rebuildLinkIfHopIntervalElapsed(
        runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>
    ) async {
        guard self.isRebuildingLink == false, self.isStarted, self.isStopped == false else {
            return
        }
        let interval = self.configuration.resilience.portHopIntervalMilliseconds
        guard interval > 0 else {
            return
        }

        let nowMilliseconds = await self.configuration.clock.nowMilliseconds()
        let lastHeard = await runtime.lastHeardAtMilliseconds() ?? self.startedAtMilliseconds
        guard nowMilliseconds >= lastHeard, nowMilliseconds - lastHeard >= interval else {
            return
        }
        guard nowMilliseconds >= self.lastLinkInstalledAtMilliseconds,
              nowMilliseconds - self.lastLinkInstalledAtMilliseconds >= interval else {
            return
        }

        await self.rebuildLink(runtime: runtime)
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
        // The driving task must NOT hold the session strongly across the sleep:
        // this loop never exits on its own (`waitTime()` is effectively always
        // non-nil), so a strong capture would pin an abandoned session — and its
        // runtime, link, and socket — forever, keeping it transmitting
        // keepalives after the host dropped its last reference. `self` is
        // therefore re-acquired per phase and released before each sleep; once
        // the session deallocates, `deinit` cancels this task and the weak
        // upgrades fail, so the loop ends and the runtime/link chain deinits.
        self.maintenanceTask = Task { [weak self, timer = self.configuration.timer] in
            while Task.isCancelled == false {
                let waitMilliseconds: UInt64?
                do {
                    waitMilliseconds = try await runtime.waitTime()
                } catch {
                    await self?.finishFromMaintenanceTask(throwing: error, generation: generation)
                    return
                }
                guard let waitMilliseconds else {
                    return
                }

                if waitMilliseconds > 0 {
                    do {
                        try await timer.sleep(forMilliseconds: waitMilliseconds)
                    } catch {
                        return
                    }
                }
                if Task.isCancelled {
                    return
                }

                guard let self else {
                    return
                }
                guard await self.performMaintenanceTick(runtime: runtime, generation: generation) else {
                    return
                }
            }
        }
    }

    private func performMaintenanceTick(
        runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>,
        generation: UInt64
    ) async -> Bool {
        guard self.shouldContinueMaintenance(generation: generation) else {
            return false
        }

        do {
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
            await self.rebuildLinkIfHopIntervalElapsed(runtime: runtime)
            if await runtime.shutdownTimedOut() {
                throw MoshSessionError.shutdownTimedOut
            }
            if await runtime.shutdownAcknowledged() {
                await self.stop()
                return false
            }
            return self.shouldContinueMaintenance(generation: generation)
        } catch is CancellationError {
            return false
        } catch {
            await self.finishFromMaintenanceTask(throwing: error, generation: generation)
            return false
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
