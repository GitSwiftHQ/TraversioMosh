// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Dispatch
import Foundation
@preconcurrency import Network

public actor MoshNWDatagramLink: MoshDatagramLink {
    public nonisolated let incomingDatagrams: MoshDatagramStream
    public nonisolated let events: MoshNWDatagramEventStream

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let continuation: MoshDatagramStream.Continuation
    private let eventContinuation: MoshNWDatagramEventStream.Continuation
    private var isStarted = false
    private var isStopped = false
    private var isReceiving = false
    private var nextSendID: UInt64 = 0
    private var pendingSends: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var cancelledSendIDs: Set<UInt64> = []
    private var latestPathSnapshot: MoshNWDatagramPathSnapshot?

    public init(
        endpoint: NWEndpoint,
        parameters: NWParameters = .udp,
        queue: DispatchQueue = DispatchQueue(label: "com.gitswift.TraversioMosh.NWDatagramLink")
    ) {
        let streamAndContinuation = Self.makeStream(bufferingPolicy: .bufferingNewest(256))
        let eventStreamAndContinuation = Self.makeEventStream(bufferingPolicy: .bufferingNewest(256))
        self.incomingDatagrams = streamAndContinuation.stream
        self.events = eventStreamAndContinuation.stream
        self.continuation = streamAndContinuation.continuation
        self.eventContinuation = eventStreamAndContinuation.continuation
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.queue = queue
    }

    public func start() async throws {
        guard self.isStopped == false else {
            throw MoshDatagramTransportError.stopped
        }
        guard self.isStarted == false else {
            return
        }

        self.isStarted = true
        self.connection.stateUpdateHandler = { state in
            Task {
                await self.handleState(state)
            }
        }
        self.connection.pathUpdateHandler = { path in
            Task {
                await self.handlePath(path)
            }
        }
        self.connection.viabilityUpdateHandler = { isViable in
            Task {
                await self.handleViability(isViable)
            }
        }
        self.connection.betterPathUpdateHandler = { hasBetterPath in
            Task {
                await self.handleBetterPath(hasBetterPath)
            }
        }
        self.connection.start(queue: self.queue)
    }

    public func currentPathSnapshot() -> MoshNWDatagramPathSnapshot? {
        if let latestPathSnapshot {
            return latestPathSnapshot
        }
        return self.connection.currentPath.map(MoshNWDatagramPathSnapshot.init)
    }

    public func send(_ datagram: [UInt8]) async throws {
        guard self.isStopped == false else {
            throw MoshDatagramTransportError.stopped
        }
        guard self.isStarted else {
            throw MoshDatagramTransportError.notStarted
        }

        let sendID = self.nextSendID
        self.nextSendID += 1
        let payload = Data(datagram)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if self.storePendingSend(id: sendID, continuation: continuation) {
                    self.connection.send(
                        content: payload,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { error in
                            Task {
                                await self.completeSend(sendID, error: error)
                            }
                        }
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelSend(sendID)
            }
        }
    }

    public func stop() async {
        guard self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.clearConnectionHandlers()
        self.connection.cancel()
        self.continuation.finish()
        self.eventContinuation.finish()
        self.resumePendingSends(throwing: MoshDatagramTransportError.stopped)
    }

    private func storePendingSend(
        id sendID: UInt64,
        continuation: CheckedContinuation<Void, Error>
    ) -> Bool {
        if self.isStopped {
            continuation.resume(throwing: MoshDatagramTransportError.stopped)
            return false
        }
        if self.cancelledSendIDs.remove(sendID) != nil {
            continuation.resume(throwing: CancellationError())
            return false
        }

        self.pendingSends[sendID] = continuation
        return true
    }

    private func handleState(_ state: NWConnection.State) {
        guard self.isStopped == false else {
            return
        }

        self.eventContinuation.yield(.stateChanged(MoshNWDatagramConnectionState(state)))

        switch state {
        case .ready:
            self.scheduleReceive()
        case .failed(let error):
            self.finish(throwing: error)
        case .cancelled:
            self.finish(throwing: nil)
        case .setup, .waiting, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func handlePath(_ path: NWPath) {
        guard self.isStopped == false else {
            return
        }

        let snapshot = MoshNWDatagramPathSnapshot(path)
        self.latestPathSnapshot = snapshot
        self.eventContinuation.yield(.pathChanged(snapshot))
    }

    private func handleViability(_ isViable: Bool) {
        guard self.isStopped == false else {
            return
        }

        self.eventContinuation.yield(.viabilityChanged(isViable))
    }

    private func handleBetterPath(_ hasBetterPath: Bool) {
        guard self.isStopped == false else {
            return
        }

        self.eventContinuation.yield(.betterPathChanged(hasBetterPath))
    }

    private func scheduleReceive() {
        guard self.isStarted, self.isStopped == false, self.isReceiving == false else {
            return
        }

        self.isReceiving = true
        self.connection.receiveMessage { data, _, _, error in
            Task {
                await self.handleReceive(data: data, error: error)
            }
        }
    }

    private func handleReceive(data: Data?, error: NWError?) {
        self.isReceiving = false
        guard self.isStopped == false else {
            return
        }

        if let error {
            self.finish(throwing: error)
            return
        }

        if let data {
            self.continuation.yield(Array(data))
        }
        self.scheduleReceive()
    }

    private func completeSend(_ sendID: UInt64, error: NWError?) {
        guard let continuation = self.pendingSends.removeValue(forKey: sendID) else {
            return
        }

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func cancelSend(_ sendID: UInt64) {
        guard let continuation = self.pendingSends.removeValue(forKey: sendID) else {
            self.cancelledSendIDs.insert(sendID)
            return
        }

        continuation.resume(throwing: CancellationError())
    }

    private func finish(throwing error: Error?) {
        guard self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.clearConnectionHandlers()
        self.connection.cancel()
        if let error {
            self.continuation.finish(throwing: error)
            self.eventContinuation.finish()
            self.resumePendingSends(throwing: error)
        } else {
            self.continuation.finish()
            self.eventContinuation.finish()
            self.resumePendingSends(throwing: MoshDatagramTransportError.stopped)
        }
    }

    private func clearConnectionHandlers() {
        self.connection.stateUpdateHandler = nil
        self.connection.pathUpdateHandler = nil
        self.connection.viabilityUpdateHandler = nil
        self.connection.betterPathUpdateHandler = nil
    }

    private func resumePendingSends(throwing error: Error) {
        let continuations = Array(self.pendingSends.values)
        self.pendingSends.removeAll()
        self.cancelledSendIDs.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private static func makeStream(
        bufferingPolicy: MoshDatagramStream.Continuation.BufferingPolicy
    ) -> (stream: MoshDatagramStream, continuation: MoshDatagramStream.Continuation) {
        var capturedContinuation: MoshDatagramStream.Continuation?
        let stream = MoshDatagramStream(bufferingPolicy: bufferingPolicy) { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }

        return (stream, capturedContinuation)
    }

    private static func makeEventStream(
        bufferingPolicy: MoshNWDatagramEventStream.Continuation.BufferingPolicy
    ) -> (
        stream: MoshNWDatagramEventStream,
        continuation: MoshNWDatagramEventStream.Continuation
    ) {
        var capturedContinuation: MoshNWDatagramEventStream.Continuation?
        let stream = MoshNWDatagramEventStream(bufferingPolicy: bufferingPolicy) { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncStream did not provide a continuation")
        }

        return (stream, capturedContinuation)
    }
}
