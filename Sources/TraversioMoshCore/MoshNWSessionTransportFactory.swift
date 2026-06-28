// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import Dispatch
@preconcurrency import Network
import TraversioMoshTransport

public struct MoshNWSessionTransportFactory: MoshSessionTransportFactory {
    private let queue: DispatchQueue

    public init(
        queue: DispatchQueue = DispatchQueue(label: "com.gitswift.TraversioMosh.NWSessionTransportFactory")
    ) {
        self.queue = queue
    }

    public func makeDatagramLink(for endpoint: MoshEndpoint) async throws -> any MoshDatagramLink {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw MoshDatagramTransportError.notConnected
        }

        return MoshNWDatagramLink(
            endpoint: .hostPort(host: NWEndpoint.Host(endpoint.host), port: port),
            queue: self.queue
        )
    }
}
