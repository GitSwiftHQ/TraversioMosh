<!--
Copyright (c) 2026 GitSwift LLC

Licensed under the MIT License.
See LICENSE for details.
-->

# TraversioMosh Readiness

This document records the current package-level handoff for host applications
that want to embed TraversioMosh.

## Supported Package Boundary

TraversioMosh owns the Mosh data plane:

- parsing the `mosh-server` connect line
- validating the session key
- encrypting and authenticating datagrams
- packet framing, compression, fragmentation, and SSP state synchronization
- UDP datagram transport over Network.framework or an injected transport
- public `MoshSession` lifecycle, input, resize, shutdown, snapshots, and
  diagnostic events
- terminal host/render operation streams and the internal renderer-ready screen
  projection

Host applications own everything outside the data plane:

- SSH authentication and host-key trust
- remote command execution for `mosh-server new`
- policy for ProxyJump, agent forwarding, identities, and known hosts
- UI layout, terminal view rendering, scrollback, tabs, windows, and settings
- persistence, telemetry, reconnect policy, and application lifecycle policy

## Default Transport

For the normal Apple-platform UDP path, configure a session with
`MoshNWSessionTransportFactory`:

```swift
let session = MoshSession(
    configuration: MoshSessionConfiguration(
        endpoint: endpoint,
        initialTerminalDimensions: dimensions,
        transportFactory: MoshNWSessionTransportFactory()
    )
)
```

Use a custom `MoshSessionTransportFactory` only when the host app needs a
test transport, packet capture, proxying, or a platform-specific datagram
backend.

Host apps that need Network.framework status UI should retain the
`MoshNWDatagramLink` they create, or provide a small capturing factory, and
consume `MoshNWDatagramLink.events` directly. `MoshNWSessionTransportFactory`
is intentionally the default session adapter; it does not impose app-specific
network status storage, logging, or UI policy.

## Lifecycle And Errors

`MoshSession.start()` creates the datagram runtime, starts the injected
transport, publishes `.started`, sends the initial resize state, and owns the
receive and maintenance tasks until stop or failure.

`MoshSession.stop()` is idempotent. It cancels receive and maintenance tasks,
stops the runtime and link, finishes host/render streams normally, emits
`.stopped`, and finishes diagnostic events.

`MoshSession.shutdown()` sends the SSP maximum-state shutdown marker and waits
for server acknowledgement. If the waiting task is cancelled, the caller
receives `CancellationError` and the session remains running until an explicit
stop or another failure path.

Transport failures after startup are terminal session failures. Start failure
after runtime startup, receive-task failure, and user-send failure all stop the
runtime/link, finish host/render streams with the original error, emit
`.stopped`, and cause later user operations to fail with `MoshSessionError.stopped`.

`MoshNWDatagramLink.events` reports Network.framework connection state, path,
viability, and better-path changes. Host apps may use those events for network
status UI or logs, but session correctness is driven by authenticated Mosh
datagrams rather than by path labels.

## Resilience And Liveness API

`MoshSessionResilienceConfiguration` (on `MoshSessionConfiguration.resilience`)
governs automatic recovery from transport death. When the datagram link fails,
the session rebuilds it on a fresh local socket while preserving the same crypto
session and SSP send sequence, then retransmits unacknowledged state. Each
attempt is separated by exponential backoff so a genuinely-down network never
tight-loops:

- `maximumLinkRebuildAttempts`: consecutive rebuild attempts before the session
  gives up and tears down with the last error. Defaults to `nil`, which retries
  indefinitely (bounded by backoff), matching Mosh's promise that a session
  survives arbitrarily long outages. The host application decides when to stop a
  never-recovering session; by default the package keeps trying.
- `initialRebuildBackoffMilliseconds` (default 200) and
  `maximumRebuildBackoffMilliseconds` (default 10000): the backoff schedule,
  doubling each attempt up to the cap.
- `noContactThresholdMilliseconds` (default 60000, matching official Mosh's
  overlay threshold): when the server has not been heard from for this long, the
  session emits a single informational `.noContact` diagnostic. This never tears
  the session down; recovery is via link rebuild.

`MoshSession.liveness` (async) returns a `MoshSessionLiveness` snapshot for
rendering "last contact Ns ago" and latency, mirroring Mosh's overlay:

- `lastHeardFromServerMilliseconds`: clock time of last contact, or `nil` before
  first contact.
- `millisecondsSinceLastHeard`: elapsed time for direct "Ns ago" rendering.
- `smoothedRoundTripMilliseconds` / `roundTripVariationMilliseconds`: SRTT and
  its variation. Reading liveness never affects the session.

### Diagnostic Events

`MoshSession.diagnosticEvents` (`MoshSessionEvent`) is an informational stream;
session correctness does not depend on a consumer draining it. The cases are:

- `.started(host:port:)`: the session started against this endpoint. It carries
  only the non-secret host and port, never the session key.
- `.datagramsSent(packetCount:)` and `.hostStateReceived(number:operationCount:)`.
- `.reconnecting(attempt:)`: the transport failed and the session is rebuilding
  the link (attempt counts from 1). Recovery is automatic; the session is not
  torn down while reconnecting.
- `.reconnected`: a fresh link was installed; unacknowledged state is
  retransmitted over it.
- `.noContact(millisecondsSinceLastHeard:)`: the no-contact threshold was
  crossed. Emitted once per outage; informational only.
- `.peerShutdown`: the server initiated shutdown; the session then finishes its
  streams cleanly. Distinct from `.stopped`, the generic terminal event.
- `.stopped`: terminal event for any stop path.

## Transport And Datagram Sizing

The default outbound fragment budget
(`MoshSSPDatagramBudget.defaultMaximumSerializedFragmentByteCount`) is 472 bytes,
chosen to keep encrypted datagrams within a conservative path MTU. Override it
via `MoshSessionConfiguration.maximumSerializedFragmentByteCount` only when the
host app has a proven reason.

## Key Handling

`MoshSessionKey` never renders its bytes: its `description` and
`debugDescription` are redacted, as is `MoshEndpoint`'s, so logging or string
interpolation cannot leak key material. Call `MoshSessionKey.wipe()` when the
host application is done with the key to zero the underlying bytes; the shared
key buffer is also zeroed when its last reference is released. The crypto layer
enforces a session-lifetime block limit. Note that a cipher's derived key
schedule is a separate copy and is not zeroed by `wipe()`.

## Host-Application Responsibilities

Beyond the data-plane boundary above, the host application must own:

- SSH bootstrap: login, host-key trust, and running `mosh-server new`, then
  handing the parsed UDP port and session key to `MoshEndpoint`.
- DNS: resolve the server host to an address once and reuse that address for the
  session and any link rebuild, so roaming and reconnection stay on a stable
  target.
- Give-up policy: decide when to stop a session that never recovers. By default
  the package retries link rebuild indefinitely (see `maximumLinkRebuildAttempts`).
- Escape-key, detach, and suspend UX: the package does not interpret a client
  escape sequence or provide detach/suspend affordances; the app owns that.
- Mouse-report encoding: `MoshTerminalScreenSnapshot` exposes the current mouse
  reporting mode, encoding mode, focus-event flag, and alternate-scroll flag,
  but the app must synthesize the actual mouse report bytes to send as input.
- UI layout, terminal view rendering, scrollback, tabs, windows, and settings.
- Persistence, telemetry, and application lifecycle policy.

## Current Validation

The in-repo test suite is deterministic and fixture-based. It covers crypto
vectors and the session-lifetime block limit, packet wire formats, protobuf2
messages, compression and the bounded inflate ceiling, fragmentation, SSP
sender/receiver behavior, out-of-order and heartbeat-gated receive,
server-initiated-shutdown detection, datagram sequencing, terminal
parser/framebuffer behavior, local prediction, session lifecycle, transport
boundaries, shutdown, cancellation, key wiping and redaction, and public stream
failure semantics. A deterministic adversarial-network suite additionally
exercises loss, reorder, duplication, transient send errors, link death with
crypto-preserving rebuild, and long-session memory behavior.

Interoperability with real `mosh-server` is validated separately, outside this
repository, in a live validation harness that runs the package against real
server targets across multiple Linux distributions and a source-built current
Mosh, covering baseline output, user input, resize, maintenance sends, malformed
datagrams, packet loss, roaming, terminal queries, and full-screen workloads
such as `less`, `nano`, `tmux`, and `top`. That live coverage is not reproducible
from this repository alone.

## Integration Status

The package provides a hardened Mosh client data plane with strong in-repo
deterministic and adversarial-network coverage, and is ready to embed through
`MoshSession` and the documented bootstrap, transport, resilience, and liveness
boundaries. The host-application responsibilities listed above remain the
embedding app's to own. If host-app integration exposes a TraversioMosh defect,
fix it in this package with focused regression coverage.
