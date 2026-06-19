// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Testing
import Network
import TraversioMoshTransport

struct MoshInMemoryDatagramLinkTests {
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
}
