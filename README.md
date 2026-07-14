<!--
Copyright (c) 2026 GitSwift LLC

Licensed under the MIT License.
See LICENSE for details.
-->

# TraversioMosh

TraversioMosh is a native Swift client data-plane library for
[Mosh](https://mosh.org/) on Apple platforms. Pair it with
[Traversio](https://github.com/GitSwiftHQ/Traversio) or another SSH client to
start `mosh-server`, then use TraversioMosh for the encrypted UDP session,
terminal synchronization, roaming, and local prediction.

## Features

- Mosh-compatible AES-128-OCB packets, protobuf messages, compression,
  fragmentation, and State Synchronization Protocol behavior
- Network.framework UDP transport with connection and path diagnostics
- Automatic port hopping and link rebuild while preserving the Mosh session
- Async input, resize, render-operation, diagnostic, and liveness APIs
- Renderer-ready terminal screen snapshots and local input prediction
- Bounded parsing, decompression, reassembly, framebuffer, and receive-state
  memory
- Deterministic Swift Testing coverage plus interoperability validation against
  real `mosh-server` releases

## Platforms

- macOS 13+
- iOS 16+
- tvOS 16+
- watchOS 9+
- visionOS 1+
- Swift 6.2+

## Installation

Add TraversioMosh with Swift Package Manager:

```swift
dependencies: [
    .package(
        url: "https://github.com/GitSwiftHQ/TraversioMosh.git",
        from: "1.0.0"
    )
]
```

Add the products used by your target. Most applications need the bootstrap and
session products:

```swift
.target(
    name: "TerminalApp",
    dependencies: [
        .product(name: "TraversioMoshBootstrap", package: "TraversioMosh"),
        .product(name: "TraversioMoshCore", package: "TraversioMosh"),
    ]
)
```

## Basic Usage

After an SSH client has run `mosh-server new`, parse its connect line and start
the UDP session:

```swift
import TraversioMoshBootstrap
import TraversioMoshCore

let bootstrap = try MoshBootstrapParser.parse(moshServerOutput)
let dimensions = try MoshTerminalDimensions(columns: 80, rows: 24)

let session = MoshSession(
    configuration: MoshSessionConfiguration(
        endpoint: MoshEndpoint(
            host: serverAddress,
            port: bootstrap.port,
            sessionKey: bootstrap.sessionKey
        ),
        initialTerminalDimensions: dimensions,
        transportFactory: MoshNWSessionTransportFactory()
    )
)

let rendering = Task {
    for try await _ in session.renderOperations {
        let screen = await session.screenSnapshot
        await draw(screen)
    }
}

try await session.start()
try await session.sendTerminalInput(Array("uname -a\n".utf8))

// On terminal close:
await session.stop()
_ = try? await rendering.value
```

The host application owns SSH authentication and host-key trust, execution of
`mosh-server`, terminal UI, scrollback, persistence, and app lifecycle policy.
See [Getting Started](Documentation/getting-started.md) for the complete
bootstrap-to-rendering flow.

## Products

- `TraversioMoshCore` — session lifecycle, terminal state, rendering, input,
  prediction, resilience, and liveness
- `TraversioMoshBootstrap` — safe `mosh-server` command construction and connect
  line parsing
- `TraversioMoshTransport` — datagram transport protocol and Network.framework
  implementation
- `TraversioMoshWire` — Mosh packet, protobuf, compression, and fragmentation
  types
- `TraversioMoshCrypto` — session keys, nonces, OCB, and packet sequencing

## Documentation

- [Documentation index](Documentation/README.md)
- [Getting Started](Documentation/getting-started.md)
- [SSH Bootstrap](Documentation/ssh-bootstrap.md)
- [Sessions and Resilience](Documentation/session-and-resilience.md)
- [Configuration](Documentation/configuration.md)
- [Ubuntu and Physical-Device Testing](Documentation/live-testing.md)
- [Security](Documentation/security.md)
- [Release Notes](Documentation/release-notes.md)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and local
validation commands. Please report security issues according to
[SECURITY.md](SECURITY.md).

## License

TraversioMosh is available under the MIT License. See [LICENSE](LICENSE).
