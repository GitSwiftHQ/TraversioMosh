<!--
Copyright (c) 2026 GitSwift LLC

Licensed under the MIT License.
See LICENSE for details.
-->

# Release Notes

## Unreleased

No user-visible changes yet.

## 1.0.0 - 2026-07-14

Initial public release of the TraversioMosh client data plane for Apple
platforms.

### Highlights

- Mosh-compatible session keys, AES-128-OCB datagrams, direction-specific
  nonces, protobuf messages, compression, fragmentation, and SSP state
  synchronization
- Network.framework UDP transport with connection/path diagnostics and fast
  failure when no viable route is available
- Public `MoshSession` lifecycle with input, resize, graceful shutdown,
  renderer-ready snapshots, render operations, diagnostics, and liveness
- Automatic link rebuild and time-driven port hopping that preserve crypto and
  synchronized-session state across network loss
- Terminal parsing, display state, local prediction, cursor-key translation,
  colors, attributes, hyperlinks, mouse modes, and alternate-screen behavior
- Typed `mosh-server` command construction and connect-line parsing for use with
  Traversio or another SSH implementation
- Bounds for parser nesting, decompression, fragment reassembly, terminal
  dimensions, framebuffer cells, render buffering, and retained synchronized
  state
- Key redaction, session-lifetime crypto limits, and best-effort key-material
  wiping

### Validation

- 554 deterministic Swift Testing tests in 26 suites
- warning-as-error Release build with complete strict-concurrency checking
- real-server interoperability across Ubuntu 22.04, Ubuntu 24.04, Alpine 3.20,
  and a source-built current Mosh server
- 24 live workload modes and 94 target runs, including full-screen programs,
  loss, reorder, roaming, terminal queries, shutdown, and recovery
- more than 2 MiB of incremental rendering in each large-redraw target
- a 3,601-second single Ubuntu session with continuous host-state traffic and no
  no-contact or reconnect event
- an OS-delivered Network.framework `.waiting` path followed by prompt send
  failure
