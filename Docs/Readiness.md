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

## Current Validation

The package test suite covers crypto vectors, packet wire formats, protobuf2
messages, compression, fragmentation, SSP sender/receiver behavior, datagram
sequencing, terminal parser/framebuffer behavior, local prediction, session
lifecycle, transport boundaries, shutdown, cancellation, and public stream
failure semantics.

Parent-workspace live validation runs the package against real `mosh-server`
targets on Ubuntu, Alpine, and a source-built current Mosh target. The current
matrix includes baseline output, user input, resize, maintenance sends,
malformed datagrams, packet loss, roaming, terminal queries, display-state
probes, and full-screen workloads including `less`, `nano`, `tmux`, and `top`.

## Remaining Completion Gates

Before treating the package as complete for SwiftServer adoption, finish these
package-level gates:

- final transport/path-change diagnostic review
- package readiness docs/examples review against the final public API
- final selected parent live matrix and soak run from a clean checkout
- explicit record of any accepted non-goals or host-application
  responsibilities

SwiftServer integration should start only after those gates are complete or
explicitly accepted as out of scope.
