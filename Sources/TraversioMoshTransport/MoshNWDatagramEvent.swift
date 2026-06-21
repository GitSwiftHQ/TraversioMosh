// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

@preconcurrency import Network

public typealias MoshNWDatagramEventStream = AsyncStream<MoshNWDatagramEvent>

public enum MoshNWDatagramEvent: Equatable, Sendable {
    case stateChanged(MoshNWDatagramConnectionState)
    case pathChanged(MoshNWDatagramPathSnapshot)
    case viabilityChanged(Bool)
    case betterPathChanged(Bool)
}

public enum MoshNWDatagramConnectionState: Equatable, Sendable {
    case setup
    case waiting
    case preparing
    case ready
    case failed
    case cancelled

    init(_ state: NWConnection.State) {
        switch state {
        case .setup:
            self = .setup
        case .waiting:
            self = .waiting
        case .preparing:
            self = .preparing
        case .ready:
            self = .ready
        case .failed:
            self = .failed
        case .cancelled:
            self = .cancelled
        @unknown default:
            self = .failed
        }
    }
}

public struct MoshNWDatagramPathSnapshot: Equatable, Sendable {
    public let status: MoshNWDatagramPathStatus
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let supportsDNS: Bool
    public let availableInterfaceTypes: [MoshNWDatagramInterfaceType]

    init(_ path: NWPath) {
        self.status = MoshNWDatagramPathStatus(path.status)
        self.isExpensive = path.isExpensive
        self.isConstrained = path.isConstrained
        self.supportsIPv4 = path.supportsIPv4
        self.supportsIPv6 = path.supportsIPv6
        self.supportsDNS = path.supportsDNS
        self.availableInterfaceTypes = path.availableInterfaces.map { MoshNWDatagramInterfaceType($0.type) }
    }
}

public enum MoshNWDatagramPathStatus: Equatable, Sendable {
    case satisfied
    case unsatisfied
    case requiresConnection
    case unknown

    init(_ status: NWPath.Status) {
        switch status {
        case .satisfied:
            self = .satisfied
        case .unsatisfied:
            self = .unsatisfied
        case .requiresConnection:
            self = .requiresConnection
        @unknown default:
            self = .unknown
        }
    }
}

public enum MoshNWDatagramInterfaceType: Equatable, Sendable {
    case other
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case unknown

    init(_ type: NWInterface.InterfaceType) {
        switch type {
        case .other:
            self = .other
        case .wifi:
            self = .wifi
        case .cellular:
            self = .cellular
        case .wiredEthernet:
            self = .wiredEthernet
        case .loopback:
            self = .loopback
        @unknown default:
            self = .unknown
        }
    }
}
