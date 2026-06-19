// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

public typealias MoshDatagramStream = AsyncThrowingStream<[UInt8], Error>

public protocol MoshDatagramLink: Sendable {
    /// A single-consumer stream of received datagram payloads.
    var incomingDatagrams: MoshDatagramStream { get }

    func start() async throws
    func send(_ datagram: [UInt8]) async throws
    func stop() async
}

public enum MoshDatagramTransportError: Error, Equatable, Sendable {
    case notStarted
    case stopped
    case notConnected
    case peerNotStarted
    case peerStopped
}

public struct MoshInMemoryDatagramPair: Sendable {
    public let client: MoshInMemoryDatagramLink
    public let server: MoshInMemoryDatagramLink

    public init(client: MoshInMemoryDatagramLink, server: MoshInMemoryDatagramLink) {
        self.client = client
        self.server = server
    }
}

public actor MoshInMemoryDatagramLink: MoshDatagramLink {
    public typealias StreamContinuation = MoshDatagramStream.Continuation

    public nonisolated let incomingDatagrams: MoshDatagramStream

    private let continuation: StreamContinuation
    private var peer: MoshInMemoryDatagramLink?
    private var isStarted = false
    private var isStopped = false

    public init(
        bufferingPolicy: StreamContinuation.BufferingPolicy = .bufferingNewest(256)
    ) {
        let streamAndContinuation = Self.makeStream(bufferingPolicy: bufferingPolicy)
        self.incomingDatagrams = streamAndContinuation.stream
        self.continuation = streamAndContinuation.continuation
    }

    public static func connectedPair(
        bufferingPolicy: StreamContinuation.BufferingPolicy = .bufferingNewest(256)
    ) async -> MoshInMemoryDatagramPair {
        let client = MoshInMemoryDatagramLink(bufferingPolicy: bufferingPolicy)
        let server = MoshInMemoryDatagramLink(bufferingPolicy: bufferingPolicy)
        await client.connect(to: server)
        await server.connect(to: client)
        return MoshInMemoryDatagramPair(client: client, server: server)
    }

    public func start() async throws {
        guard self.isStopped == false else {
            throw MoshDatagramTransportError.stopped
        }
        self.isStarted = true
    }

    public func send(_ datagram: [UInt8]) async throws {
        guard self.isStopped == false else {
            throw MoshDatagramTransportError.stopped
        }
        guard self.isStarted else {
            throw MoshDatagramTransportError.notStarted
        }
        guard let peer else {
            throw MoshDatagramTransportError.notConnected
        }

        try await peer.deliver(datagram)
    }

    public func stop() async {
        guard self.isStopped == false else {
            return
        }

        self.isStopped = true
        self.continuation.finish()
    }

    private func connect(to peer: MoshInMemoryDatagramLink) {
        self.peer = peer
    }

    private func deliver(_ datagram: [UInt8]) throws {
        guard self.isStopped == false else {
            throw MoshDatagramTransportError.peerStopped
        }
        guard self.isStarted else {
            throw MoshDatagramTransportError.peerNotStarted
        }

        self.continuation.yield(datagram)
    }

    private static func makeStream(
        bufferingPolicy: StreamContinuation.BufferingPolicy
    ) -> (stream: MoshDatagramStream, continuation: StreamContinuation) {
        var capturedContinuation: StreamContinuation?
        let stream = MoshDatagramStream(bufferingPolicy: bufferingPolicy) { continuation in
            capturedContinuation = continuation
        }

        guard let capturedContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }

        return (stream, capturedContinuation)
    }
}
