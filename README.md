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

This repository is initialized as a standalone Swift package. It intentionally
does not yet define public API or implementation details. API shape, module
ownership, crypto choices, wire compatibility strategy, and validation gates
will be designed before code is added.

## Products

- `TraversioMoshCore`: session API, lifecycle, client operation entry points,
  and async host operation streams.
- `TraversioMoshTransport`: UDP datagram transport abstraction and
  Network.framework-backed implementation.
- `TraversioMoshWire`: Mosh client/host instruction and codec boundary.
- `TraversioMoshCrypto`: session-key validation and crypto boundary.
- `TraversioMoshBootstrap`: `mosh-server` output parsing and an adapter protocol
  for SSH-backed bootstrap executors.

## Package Requirements

- Swift `6.2`
- Apple platform targets declared by `Package.swift`:
  - macOS 10.15
  - iOS 13
  - tvOS 13
  - watchOS 6
  - visionOS 1

## Next Design Topics

- Minimal public API for endpoint, session configuration, start/stop, keystroke
  input, resize, and async host operation streaming.
- Traversio-optional bootstrap adapter protocol.
- UDP transport ownership and Network.framework availability policy.
- AES-128-OCB implementation strategy and compatibility vectors.
- SSP state numbering, ACK, throwaway, retransmit, heartbeat, and timeout model.
- Real `mosh-server` E2E harness shape.

## Reference Policy

`wiedymi/swift-mosh` is kept only as an external reference under the parent
workspace's `References/Implementations/` directory. TraversioMosh code should
not copy that implementation. Use official Mosh behavior, compatibility tests,
and local audits as the source of truth.

## License

MIT
