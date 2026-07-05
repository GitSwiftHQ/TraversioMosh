<!--
Copyright (c) 2026 GitSwift LLC

Licensed under the MIT License.
See LICENSE for details.
-->

# TraversioMosh

TraversioMosh is a pure Swift Mosh client stack for Apple platforms.

It is Traversio-adjacent, not part of Traversio core. Traversio can be used by
an application to authenticate with SSH, verify host keys, run
`mosh-server new`, and hand the resulting UDP port and session key to
TraversioMosh through a small bootstrap boundary. TraversioMosh owns the Mosh
data plane.

## Current Scope

This repository is a standalone Swift package for the Mosh client data plane.
It currently includes tested bootstrap parsing, session-key validation,
AES-128-OCB, packet nonce construction, protobuf2 wire messages, compression,
fragmentation, SSP state handling, UDP datagram transport, encrypted datagram
runtime, a public `MoshSession` facade, renderer-facing host operation streams,
an internal terminal screen projection, and SSP graceful shutdown. The
Network.framework UDP transport also exposes connection/path diagnostic events
and a current path snapshot for host apps that need network status visibility.
Host apps that want the default Network.framework UDP backend can use
`MoshNWSessionTransportFactory` directly with `MoshSessionConfiguration`.
Host apps that need Network.framework path/status events should provide or
retain their own `MoshNWDatagramLink` through a custom factory.

`MoshSession` exposes raw keystroke sending, raw default terminal-input
sending, explicit-mode terminal-input translation for callers that own that
adapter boundary, resize sending, graceful shutdown, async host operation and
render operation streams, diagnostic events, protocol snapshots, a
renderer-ready screen snapshot, and a liveness snapshot.

The package is substantially hardened: hardened wire decoding (bounded inflate
and resize dimensions), crypto session-lifetime enforcement with key wiping and
redaction, a materialized-framebuffer state model, out-of-order and
heartbeat-gated SSP receive, and automatic datagram-link rebuild that preserves
the crypto session across transport death. See
[`Docs/Readiness.md`](Docs/Readiness.md) for the host-app integration boundary,
the resilience and liveness API, lifecycle semantics, and validation status.
Some concerns remain host-application responsibilities; they are enumerated
there.

## Products

- `TraversioMoshCore`: session API, lifecycle, SSP runtime coordination,
  client operation entry points, async host/render operation streams, and
  terminal state projection.
- `TraversioMoshTransport`: UDP datagram transport abstraction,
  Network.framework-backed implementation, and concrete transport diagnostics.
- `TraversioMoshWire`: Mosh client/host instruction and codec boundary.
- `TraversioMoshCrypto`: session-key validation and crypto boundary.
- `TraversioMoshBootstrap`: `mosh-server` output parsing and an adapter protocol
  for SSH-backed bootstrap executors.

## Minimal Session Setup

Host applications own SSH login, host-key trust, remote command execution, and
UI rendering. After running `mosh-server new` and parsing the connect line, the
default Network.framework-backed session setup is:

```swift
let endpoint = MoshEndpoint(
    host: host,
    port: bootstrapResult.port,
    sessionKey: bootstrapResult.sessionKey
)

let session = MoshSession(
    configuration: MoshSessionConfiguration(
        endpoint: endpoint,
        initialTerminalDimensions: try MoshTerminalDimensions(columns: 80, rows: 24),
        transportFactory: MoshNWSessionTransportFactory()
    )
)

try await session.start()
try await session.sendTerminalInput(Array("ls\n".utf8))
await session.stop()
```

## Package Requirements

- Swift `6.2`
- Apple platform targets declared by `Package.swift`:
  - macOS 13
  - iOS 16
  - tvOS 16
  - watchOS 9
  - visionOS 1

## Implementation Focus

- Keep the public API narrow and data-plane focused.
- Match official Mosh behavior for UDP transport, SSP state, packet crypto,
  wire messages, terminal synchronization, and client input translation.
- Validate cryptography with RFC 7253 OCB vectors and official wire
  known-answer vectors.
- Validate protocol and terminal behavior with deterministic unit and
  adversarial-network suites in this repository. Interoperability with a real
  `mosh-server` is validated separately in an external live harness and is not
  reproducible from this repository alone.
- Keep SSH bootstrap, host-key trust, UI rendering, and application lifecycle
  policy outside the core package boundary.

## Reference Policy

TraversioMosh does not copy any third-party Mosh implementation. Official Mosh
behavior, protocol references, compatibility tests, and interoperability
validation against real `mosh-server` are the source of truth.

## License

MIT
