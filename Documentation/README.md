<!--
Copyright (c) 2026 GitSwift LLC

Licensed under the MIT License.
See LICENSE for details.
-->

# TraversioMosh Documentation

These guides cover installation, SSH bootstrap, session integration, runtime
configuration, security, and live validation.

## Start Here

- [Getting Started](getting-started.md) — add the package and connect a terminal
  to a parsed `mosh-server` result.
- [SSH Bootstrap](ssh-bootstrap.md) — construct the remote command, adapt an SSH
  library, and hand the UDP endpoint to TraversioMosh.
- [Sessions and Resilience](session-and-resilience.md) — understand lifecycle,
  rendering, shutdown, liveness, and recovery behavior.

## Guides

- [Configuration](configuration.md) — choose products, transport, resilience,
  prediction, buffers, and datagram sizing.
- [Ubuntu and Physical-Device Testing](live-testing.md) — install
  `mosh-server`, open UDP access, and exercise a real Apple device.
- [Security](security.md) — understand trust boundaries, key handling, parser
  limits, and security-sensitive integration choices.
- [OCB Audit Checklist](security/ocb-audit.md) — implementation-specific review
  record for the packet cipher.
- [Release Notes](release-notes.md) — user-visible changes and validation for
  each release.

## API Products

| Product | Use it for |
| --- | --- |
| `TraversioMoshCore` | Sessions, terminal state, rendering, input, prediction, liveness |
| `TraversioMoshBootstrap` | `mosh-server` command creation and output parsing |
| `TraversioMoshTransport` | Custom datagram links and Network.framework diagnostics |
| `TraversioMoshWire` | Direct packet, instruction, compression, or fragmentation access |
| `TraversioMoshCrypto` | Direct key, nonce, OCB, cipher, or sequencer access |

Most applications should start with `TraversioMoshCore` and
`TraversioMoshBootstrap`. Add lower-level products only when the application
directly uses their public types.
