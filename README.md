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
an internal terminal screen projection, and SSP graceful shutdown.

`MoshSession` exposes raw keystroke sending, raw default terminal-input
sending, explicit-mode terminal-input translation for callers that own that
adapter boundary, resize sending, graceful shutdown, async host operation and
render operation streams, diagnostic events including typed screen projection
failures, protocol snapshots, and a renderer-ready screen snapshot.

The package is still under active compatibility work. Real `mosh-server`
validation lives in the parent workspace matrix while protocol, roaming, and
terminal-state coverage continue to expand.

## Products

- `TraversioMoshCore`: session API, lifecycle, SSP runtime coordination,
  client operation entry points, async host/render operation streams, and
  terminal state projection.
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

## Implementation Focus

- Keep the public API narrow and data-plane focused.
- Match official Mosh behavior for UDP transport, SSP state, packet crypto,
  wire messages, terminal synchronization, and client input translation.
- Validate cryptography with RFC vectors and Mosh-compatible fixtures.
- Validate protocol and terminal behavior against real `mosh-server` fixtures.
- Keep SSH bootstrap, host-key trust, UI rendering, and application lifecycle
  policy outside the core package boundary.

## Reference Policy

`wiedymi/swift-mosh` is kept only as an external reference under the parent
workspace's `References/Implementations/` directory. TraversioMosh code should
not copy that implementation. Use official Mosh behavior, compatibility tests,
and local audits as the source of truth.

## License

MIT
