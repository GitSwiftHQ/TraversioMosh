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

public protocol MoshSessionTransportFactory: Sendable {
    func makeDatagramLink(for endpoint: MoshEndpoint) async throws -> any MoshDatagramLink
}

public protocol MoshSessionTimer: Sendable {
    func sleep(forMilliseconds milliseconds: UInt64) async throws
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

    public init(
        endpoint: MoshEndpoint,
        initialTerminalDimensions: MoshTerminalDimensions,
        transportFactory: any MoshSessionTransportFactory,
        clock: any MoshMillisecondsClock = MoshSystemMillisecondsClock(),
        timer: any MoshSessionTimer = MoshTaskSessionTimer(),
        timing: MoshSSPSendTimingConfiguration = MoshSSPSendTimingConfiguration(),
        maximumSerializedFragmentByteCount: Int = 1_280,
        chaffSource: MoshSSPChaffSource = .random
    ) {
        self.endpoint = endpoint
        self.initialTerminalDimensions = initialTerminalDimensions
        self.transportFactory = transportFactory
        self.clock = clock
        self.timer = timer
        self.timing = timing
        self.maximumSerializedFragmentByteCount = maximumSerializedFragmentByteCount
        self.chaffSource = chaffSource
    }
}

public enum MoshSessionError: Error, Equatable, Sendable {
    case alreadyStarted
    case notStarted
    case stopped
    case shutdownTimedOut
    case timerExpiredWithoutDueDatagram
}

public enum MoshSessionEvent: Equatable, Sendable {
    case started(MoshEndpoint)
    case datagramsSent(packetCount: Int)
    case hostStateReceived(number: UInt64, operationCount: Int)
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
    private var userInputTranslator: MoshTerminalUserInputTranslator
    private var runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>?
    private var receiveTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceGeneration: UInt64 = 0
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

        var terminalEngine = MoshTerminalStateEngine()
        terminalEngine.enqueueClientOperation(.resize(configuration.initialTerminalDimensions))
        self.terminalEngine = terminalEngine
        self.userInputTranslator = MoshTerminalUserInputTranslator()
    }

    deinit {
        self.receiveTask?.cancel()
        self.maintenanceTask?.cancel()
        self.hostOperationContinuation.finish()
        self.renderOperationContinuation.finish()
        self.diagnosticEventContinuation.finish()
    }

    public var snapshot: MoshTerminalSnapshot {
        self.terminalEngine.snapshot
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
            initialReceiveState: MoshTerminalHostState(),
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

        try await runtime.start()
        await runtime.setCurrentState(self.terminalEngine.clientState)

        self.runtime = runtime
        self.isStarted = true
        self.startReceiveTask(runtime: runtime)
        self.diagnosticEventContinuation.yield(.started(self.configuration.endpoint))
        _ = try await self.sendDueDatagrams()
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
        await self.runtime?.stop()
        self.runtime = nil
        self.hostOperationContinuation.finish()
        self.renderOperationContinuation.finish()
        self.diagnosticEventContinuation.yield(.stopped)
        self.diagnosticEventContinuation.finish()
    }

    public func sendKeystrokes(_ bytes: [UInt8]) async throws {
        guard bytes.isEmpty == false else {
            return
        }

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
        guard translatedBytes.isEmpty == false else {
            return
        }

        try await self.updateClientState(.keystrokes(translatedBytes))
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

        self.terminalEngine.enqueueClientOperation(operation)
        await runtime.setCurrentState(self.terminalEngine.clientState)
        _ = try await self.sendDueDatagrams()
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
    ) {
        let state = instruction.instructionResult.latestState
        let operations = self.terminalEngine.acceptHostState(state.state)
        for operation in operations {
            self.hostOperationContinuation.yield(operation)
            if let renderOperation = MoshTerminalRenderOperation(operation) {
                self.renderOperationContinuation.yield(renderOperation)
            }
        }
        self.diagnosticEventContinuation.yield(
            .hostStateReceived(number: state.number, operationCount: operations.count)
        )
        if let runtime = self.runtime, self.isStarted, self.isStopped == false {
            self.restartMaintenanceTask(runtime: runtime)
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
        self.runtime = nil
        if let error {
            self.hostOperationContinuation.finish(throwing: error)
            self.renderOperationContinuation.finish(throwing: error)
        } else {
            self.hostOperationContinuation.finish()
            self.renderOperationContinuation.finish()
        }
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
        await self.runtime?.stop()
        self.runtime = nil
        self.hostOperationContinuation.finish(throwing: error)
        self.renderOperationContinuation.finish(throwing: error)
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
                    await self.handleIncomingInstruction(instruction)
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

    private func restartMaintenanceTask(
        runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>
    ) {
        self.maintenanceTask?.cancel()
        self.maintenanceGeneration &+= 1
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

                let sentDatagram = try await self.sendDueDatagrams()
                if sentDatagram == false, waitMilliseconds == 0 {
                    throw MoshSessionError.timerExpiredWithoutDueDatagram
                }
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
