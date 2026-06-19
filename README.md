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

This repository is initialized as a standalone Swift package. The first
implementation slice covers canonical Mosh session-key validation and
`mosh-server` bootstrap output parsing. UDP transport, SSP, OCB sealing/opening,
wire codecs, and terminal state synchronization are still pending.

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
  - macOS 13
  - iOS 16
  - tvOS 16
  - watchOS 9
  - visionOS 1

## Initial Implementation Topics

- Bootstrap adapter boundary.
- AES-128-OCB vectors and audit path.
- Test infrastructure for deterministic wire, crypto, and state-machine work.
- SSP state numbering, ACK, throwaway, retransmit, heartbeat, and timeout tests.
- Real `mosh-server` E2E harness using a locally built or containerized server.

## Reference Policy

`wiedymi/swift-mosh` is kept only as an external reference under the parent
workspace's `References/Implementations/` directory. TraversioMosh code should
not copy that implementation. Use official Mosh behavior, compatibility tests,
and local audits as the source of truth.

## License

MIT
