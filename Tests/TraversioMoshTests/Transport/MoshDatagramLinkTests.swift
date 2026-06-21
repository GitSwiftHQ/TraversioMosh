// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import Foundation
@preconcurrency import Network
import TraversioMoshTransport

struct MoshDatagramLinkTests {
    @Test
    func connectedPairDeliversDatagramsInOrder() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        try await pair.client.start()
        try await pair.server.start()
        var serverIncoming = pair.server.incomingDatagrams.makeAsyncIterator()

        try await pair.client.send([0x01])
        try await pair.client.send([0x02, 0x03])

        let first = try await serverIncoming.next()
        let second = try await serverIncoming.next()

        #expect(first == [0x01])
        #expect(second == [0x02, 0x03])
    }

    @Test
    func sendBeforeStartFailsAtSenderBoundary() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        try await pair.server.start()

        await #expect(
            throws: MoshDatagramTransportError.notStarted
        ) {
            try await pair.client.send([0x01])
        }
    }

    @Test
    func sendBeforePeerStartFailsAtPeerBoundary() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        try await pair.client.start()

        await #expect(
            throws: MoshDatagramTransportError.peerNotStarted
        ) {
            try await pair.client.send([0x01])
        }
    }

    @Test
    func stoppedLinkFinishesIncomingStream() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        try await pair.server.start()
        var serverIncoming = pair.server.incomingDatagrams.makeAsyncIterator()

        await pair.server.stop()

        let next = try await serverIncoming.next()
        #expect(next == nil)
    }

    @Test
    func sendToStoppedPeerFailsAtPeerBoundary() async throws {
        let pair = await MoshInMemoryDatagramLink.connectedPair()
        try await pair.client.start()
        try await pair.server.start()
        await pair.server.stop()

        await #expect(
            throws: MoshDatagramTransportError.peerStopped
        ) {
            try await pair.client.send([0x01])
        }
    }

    @Test
    func stopIsIdempotent() async throws {
        let link = MoshInMemoryDatagramLink()
        try await link.start()

        await link.stop()
        await link.stop()

        await #expect(
            throws: MoshDatagramTransportError.stopped
        ) {
            try await link.start()
        }
    }

    @Test
    func nwLinkSendBeforeStartFailsAtSenderBoundary() async throws {
        let link = MoshNWDatagramLink(
            endpoint: .hostPort(host: "127.0.0.1", port: 1)
        )

        await #expect(
            throws: MoshDatagramTransportError.notStarted
        ) {
            try await link.send([0x01])
        }
    }

    @Test
    func nwLinkStopPreventsStart() async throws {
        let link = MoshNWDatagramLink(
            endpoint: .hostPort(host: "127.0.0.1", port: 1)
        )

        await link.stop()

        await #expect(
            throws: MoshDatagramTransportError.stopped
        ) {
            try await link.start()
        }
    }

    @Test
    func nwLinkRoundTripsDatagramOverLoopback() async throws {
        let server = try LoopbackUDPEchoServer()
        let port: NWEndpoint.Port
        do {
            port = try await withTimeout {
                try await server.start()
            }
        } catch {
            await server.stop()
            throw error
        }

        let link = MoshNWDatagramLink(
            endpoint: .hostPort(host: "127.0.0.1", port: port)
        )
        let receiveTask = Task<[UInt8]?, Error> {
            var iterator = link.incomingDatagrams.makeAsyncIterator()
            return try await iterator.next()
        }

        do {
            try await link.start()
            try await link.send([0xde, 0xad, 0xbe, 0xef])

            let received = try await withTimeout {
                try await receiveTask.value
            }

            #expect(received == [0xde, 0xad, 0xbe, 0xef])
            receiveTask.cancel()
            await link.stop()
            await server.stop()
        } catch {
            receiveTask.cancel()
            await link.stop()
            await server.stop()
            throw error
        }
    }

    @Test
    func nwLinkPublishesReadyEventAndCurrentPathSnapshot() async throws {
        let server = try LoopbackUDPEchoServer()
        let port: NWEndpoint.Port
        do {
            port = try await withTimeout {
                try await server.start()
            }
        } catch {
            await server.stop()
            throw error
        }

        let link = MoshNWDatagramLink(
            endpoint: .hostPort(host: "127.0.0.1", port: port)
        )
        let readyEventTask = Task<MoshNWDatagramEvent?, Never> {
            var iterator = link.events.makeAsyncIterator()
            while let event = await iterator.next() {
                if event == .stateChanged(.ready) {
                    return event
                }
            }
            return nil
        }

        do {
            try await link.start()

            let event = try await withTimeout {
                await readyEventTask.value
            }
            let snapshot = try #require(await link.currentPathSnapshot())

            #expect(event == .stateChanged(.ready))
            #expect(snapshot.status == .satisfied)

            readyEventTask.cancel()
            await link.stop()
            await server.stop()
        } catch {
            readyEventTask.cancel()
            await link.stop()
            await server.stop()
            throw error
        }
    }
}

private actor LoopbackUDPEchoServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.gitswift.TraversioMoshTests.UDPEchoServer")
    private var connections: [NWConnection] = []
    private var startContinuation: CheckedContinuation<NWEndpoint.Port, Error>?

    init() throws {
        self.listener = try NWListener(using: .udp, on: .any)
    }

    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            self.startContinuation = continuation
            self.listener.newConnectionHandler = { connection in
                Task {
                    await self.accept(connection)
                }
            }
            self.listener.stateUpdateHandler = { state in
                Task {
                    await self.handleState(state)
                }
            }
            self.listener.start(queue: self.queue)
        }
    }

    func stop() {
        self.listener.stateUpdateHandler = nil
        self.listener.newConnectionHandler = nil
        self.listener.cancel()
        for connection in self.connections {
            connection.cancel()
        }
        self.connections.removeAll()
        self.startContinuation?.resume(throwing: MoshDatagramTransportError.stopped)
        self.startContinuation = nil
    }

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = self.listener.port else {
                self.startContinuation?.resume(throwing: MoshDatagramTransportError.notConnected)
                self.startContinuation = nil
                return
            }
            self.startContinuation?.resume(returning: port)
            self.startContinuation = nil
        case .failed(let error):
            self.startContinuation?.resume(throwing: error)
            self.startContinuation = nil
        case .cancelled:
            self.startContinuation?.resume(throwing: MoshDatagramTransportError.stopped)
            self.startContinuation = nil
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        self.connections.append(connection)
        self.receive(on: connection)
        connection.start(queue: self.queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { data, _, _, error in
            Task {
                await self.handleReceive(on: connection, data: data, error: error)
            }
        }
    }

    private func handleReceive(on connection: NWConnection, data: Data?, error: NWError?) {
        guard error == nil else {
            connection.cancel()
            return
        }

        if let data {
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in }
            )
        }
        self.receive(on: connection)
    }
}

private enum MoshTransportTestError: Error, Equatable {
    case timedOut
}

private func withTimeout<T: Sendable>(
    after duration: Duration = .seconds(2),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: duration)
            throw MoshTransportTestError.timedOut
        }

        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}
