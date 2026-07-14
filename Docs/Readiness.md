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

Transport trouble after startup is not automatically terminal. A transient
`link.send` failure (for example `ENETDOWN`/`EHOSTUNREACH` on a network
transition, or a link that is momentarily down or rebuilding) is recorded and
tolerated rather than fatal: the datagram is already accounted as sent by the
SSP sender, so its retransmit timer re-sends the still-unacknowledged state once
connectivity returns, and the recorded failure is visible through
`MoshSessionLiveness.recordedSendErrorDescription`. A faulted link triggers the
automatic rebuild described under Resilience below. The session tears down only
on genuinely terminal conditions:

- a receive-side non-packet-local error — a malformed but authenticated
  instruction (packet-local errors, such as an unauthenticated or truncated
  datagram or a direction mismatch, are dropped and the receive loop continues);
- crypto exhaustion — the send-sequence or per-session block-encryption limit is
  reached;
- shutdown timeout after `shutdown()`;
- link-rebuild attempt exhaustion (`MoshSessionError.linkRebuildAttemptsExhausted`);
- an explicit `stop()`.

On any terminal path the session stops the runtime/link, finishes host/render
streams (with the originating error where there is one), emits `.stopped`, and
causes later user operations to fail with `MoshSessionError.stopped`.

When the server initiates shutdown (the SSP shutdown-sentinel state number,
`UInt64.max`), the session first sends the acknowledgement — an outgoing
instruction carrying `ack = UInt64.max`, mirroring official Mosh's
`counterparty_shutdown_ack` so the server can stop retransmitting its final
state — then emits `.peerShutdown` followed by `.stopped`.

`MoshNWDatagramLink.events` reports Network.framework connection state, path,
viability, and better-path changes. Host apps may use those events for network
status UI or logs, but session correctness is driven by authenticated Mosh
datagrams rather than by path labels.

## Host And Render Operation Streams

`hostOperations` carries raw wire operations decoded from server diffs;
`renderOperations` carries the display-ready equivalents. A received diff is
normally forwarded incrementally, but only when it chains from the exact host
state the streams last rendered.

When a diff does not chain from that state — the server re-based its diff
against an older reference after a lost acknowledgement — forwarding it would
double-apply overlapping content. In that case the render stream instead emits a
single `MoshTerminalRenderOperation.resync(snapshot)`: consumers must replace
their displayed frame wholesale with the snapshot. `MoshTerminalScreen.apply(.resync)`
does exactly this, restoring the visible frame from the snapshot. The
host-operation stream, which carries raw wire operations, emits nothing for a
re-based diff (official Mosh never forwards wire diffs; its client recomputes
every frame from the latest framebuffer). Because `hostOperations` emits nothing
for a re-based diff and carries no resync signal, it is not sufficient for exact
incremental reconstruction across rebases: consumers needing display fidelity
must use `renderOperations` (which carries `resync`) or read `screenSnapshot`.

`renderOperations` uses a bounded `.bufferingNewest` policy sized by
`MoshSession.init`'s `renderOperationBufferingCapacity` parameter (default
512; the type is an `Int` capacity, not a general buffering policy, precisely
because the repair below only self-heals under `.bufferingNewest`
semantics). If a slow consumer lets that buffer fill, the session detects the
resulting dropped operation and emits the same wholesale `.resync(snapshot)`
used for a re-based diff, rather than silently continuing an incremental
sequence the consumer never fully received; a full `.bufferingNewest` buffer
always accepts the newest yield (including that resync), evicting an older
buffered operation to make room.

Terminal-generated replies (for example DA/DSR answers to device queries) are
captured while a diff is applied but are never transmitted. In official Mosh the
server-side emulator answers such queries; a client that echoed them back would
inject duplicate bytes on a re-based diff and hand a hostile server a
keystroke-injection channel.

## Resilience And Liveness API

`MoshSessionResilienceConfiguration` (on `MoshSessionConfiguration.resilience`)
governs automatic recovery from transport death. When the datagram link fails,
the session rebuilds it on a fresh local socket while preserving the same crypto
session and SSP send sequence, then retransmits unacknowledged state. Each
attempt is separated by exponential backoff so a genuinely-down network never
tight-loops:

- `maximumLinkRebuildAttempts`: consecutive rebuild attempts before the session
  gives up and tears down with `MoshSessionError.linkRebuildAttemptsExhausted`
  (or the last rebuild failure if one was recorded). An attempt only stops
  counting as consecutive once the server is actually heard on a rebuilt link —
  merely installing a fresh socket proves nothing, since `NWConnection.start()`
  returns before any contact — so a dead network cannot launder the counter
  through installs that "succeed" and immediately fail again. Defaults to `nil`,
  which retries indefinitely (bounded by backoff), matching Mosh's promise that
  a session survives arbitrarily long outages. The host application decides when
  to stop a never-recovering session; by default the package keeps trying.
- `initialRebuildBackoffMilliseconds` (default 200) and
  `maximumRebuildBackoffMilliseconds` (default 10000): the backoff schedule,
  doubling each attempt up to the cap.
- `portHopIntervalMilliseconds` (default 10000, matching official Mosh's
  `PORT_HOP_INTERVAL`): covers silent transport death — a NAT mapping that
  expires or a UDP path that blackholes never faults the socket, so an
  error-driven rebuild can never fire for it. When the server has been silent
  for at least this long on a link that is itself at least that old, the
  maintenance loop proactively rebuilds the link (a fresh socket is a fresh
  source port). `0` disables the time-driven hop.
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
- `recordedSendErrorDescription`: a description of the most recent recorded and
  swallowed `link.send` failure, or `nil` if the last send succeeded. This is
  the host's immediate signal of an outbound outage, ahead of the slower
  `.noContact` diagnostic, and mirrors official Mosh's `Connection::send_error`.

### Diagnostic Events

`MoshSession.diagnosticEvents` (`MoshSessionEvent`) is an informational stream;
session correctness does not depend on a consumer draining it. The cases are:

- `.started(host:port:)`: the session started against this endpoint. It carries
  only the non-secret host and port, never the session key.
- `.datagramsSent(packetCount:)` and `.hostStateReceived(number:operationCount:)`.
  `.datagramsSent` is suppressed for a batch whose sends were all
  recorded-and-swallowed (transient send tolerance), so it never reads as
  healthy outbound traffic while sends are failing; the failure is visible via
  `liveness.recordedSendErrorDescription`.
- `.reconnecting(attempt:)`: the transport failed (or the port-hop interval
  elapsed) and the session is rebuilding the link (attempt counts from 1).
  Recovery is automatic; the session is not torn down while reconnecting.
- `.reconnected`: the server was actually heard from again on a rebuilt link.
  It is deliberately NOT emitted when a fresh link is merely installed — a
  socket that opens against a dead network proves nothing — so this event means
  real recovery, mirroring official Mosh crediting `last_roundtrip_success`.
- `.noContact(millisecondsSinceLastHeard:)`: the no-contact threshold was
  crossed. Emitted once per outage; informational only.
- `.peerShutdown`: the server initiated shutdown. The session sends the
  acknowledgement (`ack = UInt64.max`) before stopping, then emits this event
  and finishes its streams cleanly. Distinct from `.stopped`, the generic
  terminal event.
- `.stopped`: terminal event for any stop path.

## Transport And Datagram Sizing

The default outbound fragment budget
(`MoshSSPDatagramBudget.defaultMaximumSerializedFragmentByteCount`) is 472 bytes,
chosen to keep encrypted datagrams within a conservative path MTU. Override it
via `MoshSessionConfiguration.maximumSerializedFragmentByteCount` only when the
host app has a proven reason.

Inbound fragment reassembly (`MoshFragmentAssembly`) bounds the cumulative
compressed bytes it will retain for one in-flight instruction to
`MoshFragmentAssembly.maximumCumulativeCompressedByteCount`, checked before
every fragment is stored rather than only after the final fragment arrives.
This is `MoshCompressor.defaultMaximumOutputByteCount` plus zlib's own
worst-case compressed-expansion margin, so a legitimate peer's instruction can
never be rejected by it regardless of how incompressible its content is.

Terminal dimensions from a peer resize are bounded on two axes:
`MoshTerminalDimensions.maximumDimension` (2048) per axis, and
`MoshTerminalDimensions.maximumCellCount` (250,000) on the product of both,
so two dimensions that each individually pass the per-axis cap cannot still
reach an oversized combined allocation. Oversized requests clamp — shrinking
whichever dimension is larger while preserving the smaller one — rather than
rejecting, since a resize that threw would tear down an otherwise healthy
session.

## Key Handling

`MoshSessionKey` never renders its bytes: its `description` and
`debugDescription` are redacted, as is `MoshEndpoint`'s, so logging or string
interpolation cannot leak key material. Call `MoshSessionKey.wipe()` when the
host application is done with the key to zero the underlying bytes; the shared
key buffer is also zeroed when its last reference is released. The crypto layer
enforces a session-lifetime block limit. The cipher's own key material — the raw
AES-128 key plus the derived OCB L table — lives in a single shared, wipeable
buffer and is zeroed (`memset_s`) when the last reference to the cipher chain
deallocates, matching official Mosh's `ae_clear`. One honest limitation remains:
CommonCrypto expands and releases its own AES key schedule inside each `CCCrypt`
call, and that internal copy is outside our control.

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
