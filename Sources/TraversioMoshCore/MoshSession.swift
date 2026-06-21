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
    public var predictionConfiguration: MoshPredictionConfiguration

    public init(
        endpoint: MoshEndpoint,
        initialTerminalDimensions: MoshTerminalDimensions,
        transportFactory: any MoshSessionTransportFactory,
        clock: any MoshMillisecondsClock = MoshSystemMillisecondsClock(),
        timer: any MoshSessionTimer = MoshTaskSessionTimer(),
        timing: MoshSSPSendTimingConfiguration = MoshSSPSendTimingConfiguration(),
        maximumSerializedFragmentByteCount: Int = 1_280,
        chaffSource: MoshSSPChaffSource = .random,
        predictionConfiguration: MoshPredictionConfiguration = MoshPredictionConfiguration()
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
    }
}

public enum MoshSessionError: Error, Equatable, Sendable {
    case alreadyStarted
    case notStarted
    case stopped
    case shutdownTimedOut
    case timerExpiredWithoutDueDatagram
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
    case started(MoshEndpoint)
    case datagramsSent(packetCount: Int)
    case hostStateReceived(number: UInt64, operationCount: Int)
    case screenProjectionFailed(MoshSessionScreenProjectionFailure)
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
    private var maintenanceGeneration: UInt64 = 0
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

        var terminalEngine = MoshTerminalStateEngine()
        terminalEngine.enqueueClientOperation(.resize(configuration.initialTerminalDimensions))
        self.terminalEngine = terminalEngine
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
        self.hostOperationContinuation.finish()
        self.renderOperationContinuation.finish()
        self.diagnosticEventContinuation.finish()
    }

    public var snapshot: MoshTerminalSnapshot {
        self.terminalEngine.snapshot
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
    ) async throws {
        let state = instruction.instructionResult.latestState
        let operations = self.terminalEngine.acceptHostState(state.state)
        var generatedTerminalToHostBytes: [UInt8] = []
        for (operationIndex, operation) in operations.enumerated() {
            let renderOperation = MoshTerminalRenderOperation(operation)
            if let renderOperation {
                do {
                    generatedTerminalToHostBytes.append(
                        contentsOf: try self.terminalScreen.apply(renderOperation)
                    )
                } catch {
                    let failure = MoshSessionScreenProjectionFailure(
                        stateNumber: state.number,
                        operationIndex: operationIndex,
                        operation: renderOperation,
                        reason: MoshSessionScreenProjectionFailureReason(error: error)
                    )
                    self.diagnosticEventContinuation.yield(.screenProjectionFailed(failure))
                    throw failure
                }
            }
            self.hostOperationContinuation.yield(operation)
            if let renderOperation {
                self.renderOperationContinuation.yield(renderOperation)
            }
        }
        if generatedTerminalToHostBytes.isEmpty == false {
            try await self.updateClientState(.keystrokes(generatedTerminalToHostBytes))
        }
        await self.updatePredictionHints(runtime: self.runtime, hostState: state.state)
        self.predictionEngine.cull(
            baseSnapshot: self.terminalScreen.snapshot,
            nowMilliseconds: await self.configuration.clock.nowMilliseconds()
        )
        self.diagnosticEventContinuation.yield(
            .hostStateReceived(number: state.number, operationCount: operations.count)
        )
        if let runtime = self.runtime, self.isStarted, self.isStopped == false {
            if await runtime.shutdownAcknowledged() {
                await self.stop()
                return
            }
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

                let sentDatagram = try await self.sendDueDatagrams()
                if sentDatagram == false, waitMilliseconds == 0 {
                    guard self.shouldContinueMaintenance(generation: generation) else {
                        return
                    }
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
