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

public struct MoshSessionConfiguration: Sendable {
    public var endpoint: MoshEndpoint
    public var initialTerminalDimensions: MoshTerminalDimensions
    public var transportFactory: any MoshSessionTransportFactory
    public var clock: any MoshMillisecondsClock
    public var timing: MoshSSPSendTimingConfiguration
    public var maximumSerializedFragmentByteCount: Int
    public var chaffSource: MoshSSPChaffSource

    public init(
        endpoint: MoshEndpoint,
        initialTerminalDimensions: MoshTerminalDimensions,
        transportFactory: any MoshSessionTransportFactory,
        clock: any MoshMillisecondsClock = MoshSystemMillisecondsClock(),
        timing: MoshSSPSendTimingConfiguration = MoshSSPSendTimingConfiguration(),
        maximumSerializedFragmentByteCount: Int = 1_280,
        chaffSource: MoshSSPChaffSource = .random
    ) {
        self.endpoint = endpoint
        self.initialTerminalDimensions = initialTerminalDimensions
        self.transportFactory = transportFactory
        self.clock = clock
        self.timing = timing
        self.maximumSerializedFragmentByteCount = maximumSerializedFragmentByteCount
        self.chaffSource = chaffSource
    }
}

public enum MoshSessionError: Error, Equatable, Sendable {
    case alreadyStarted
    case notStarted
    case stopped
}

public enum MoshSessionEvent: Equatable, Sendable {
    case started(MoshEndpoint)
    case datagramsSent(packetCount: Int)
    case hostStateReceived(number: UInt64, operationCount: Int)
    case stopped
}

public actor MoshSession {
    public typealias HostOperationStream = AsyncThrowingStream<MoshHostOperation, Error>
    public typealias DiagnosticEventStream = AsyncStream<MoshSessionEvent>

    public nonisolated let hostOperations: HostOperationStream
    public nonisolated let diagnosticEvents: DiagnosticEventStream

    private let configuration: MoshSessionConfiguration
    private let hostOperationContinuation: HostOperationStream.Continuation
    private let diagnosticEventContinuation: DiagnosticEventStream.Continuation

    private var terminalEngine: MoshTerminalStateEngine
    private var runtime: MoshSSPDatagramRuntime<MoshTerminalClientState, MoshTerminalHostState>?
    private var receiveTask: Task<Void, Never>?
    private var isStarted = false
    private var isStopped = false

    public init(
        configuration: MoshSessionConfiguration,
        hostOperationBufferingPolicy: HostOperationStream.Continuation.BufferingPolicy = .bufferingNewest(512),
        diagnosticEventBufferingPolicy: DiagnosticEventStream.Continuation.BufferingPolicy = .bufferingNewest(512)
    ) {
        let hostOperationStream = Self.makeHostOperationStream(bufferingPolicy: hostOperationBufferingPolicy)
        let diagnosticEventStream = Self.makeDiagnosticEventStream(bufferingPolicy: diagnosticEventBufferingPolicy)

        self.configuration = configuration
        self.hostOperations = hostOperationStream.stream
        self.hostOperationContinuation = hostOperationStream.continuation
        self.diagnosticEvents = diagnosticEventStream.stream
        self.diagnosticEventContinuation = diagnosticEventStream.continuation

        var terminalEngine = MoshTerminalStateEngine()
        terminalEngine.enqueueClientOperation(.resize(configuration.initialTerminalDimensions))
        self.terminalEngine = terminalEngine
    }

    deinit {
        self.receiveTask?.cancel()
        self.hostOperationContinuation.finish()
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
        try await self.sendDueDatagrams()
    }

    public func stop() async {
        guard self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.isStarted = false
        self.receiveTask?.cancel()
        self.receiveTask = nil
        await self.runtime?.stop()
        self.runtime = nil
        self.hostOperationContinuation.finish()
        self.diagnosticEventContinuation.yield(.stopped)
        self.diagnosticEventContinuation.finish()
    }

    public func sendKeystrokes(_ bytes: [UInt8]) async throws {
        guard bytes.isEmpty == false else {
            return
        }

        try await self.updateClientState(.keystrokes(bytes))
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
        try await self.sendDueDatagrams()
    }

    private func sendDueDatagrams() async throws {
        try self.requireStarted()
        guard let runtime = self.runtime else {
            throw MoshSessionError.notStarted
        }
        guard let batch = try await runtime.sendDueDatagrams() else {
            return
        }

        self.diagnosticEventContinuation.yield(
            .datagramsSent(packetCount: batch.packets.count)
        )
    }

    private func handleIncomingInstruction(
        _ instruction: MoshSSPDatagramIncomingInstruction<MoshTerminalHostState>
    ) {
        let state = instruction.instructionResult.latestState
        let operations = self.terminalEngine.acceptHostState(state.state)
        for operation in operations {
            self.hostOperationContinuation.yield(operation)
        }
        self.diagnosticEventContinuation.yield(
            .hostStateReceived(number: state.number, operationCount: operations.count)
        )
    }

    private func finishFromReceiveTask(throwing error: Error?) async {
        guard self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.isStarted = false
        self.runtime = nil
        if let error {
            self.hostOperationContinuation.finish(throwing: error)
        } else {
            self.hostOperationContinuation.finish()
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
