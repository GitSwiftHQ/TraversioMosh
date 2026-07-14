<!--
Copyright (c) 2026 GitSwift LLC

Licensed under the MIT License.
See LICENSE for details.
-->

# Configuration

`MoshSessionConfiguration` groups the endpoint, initial terminal size, transport,
timing, prediction, and resilience settings for one Mosh session. The defaults
match the normal application path; override them only for a concrete product or
network requirement.

## Endpoint and Terminal Size

```swift
let endpoint = MoshEndpoint(
    host: resolvedServerAddress,
    port: bootstrap.port,
    sessionKey: bootstrap.sessionKey
)

let dimensions = try MoshTerminalDimensions(columns: 80, rows: 24)
```

Use the UDP port and session key returned by the same `mosh-server` process.
Keep the selected host address stable for the life of the session so a rebuilt
datagram link returns to the same server.

Terminal columns and rows must be positive. Peer-provided and local dimensions
are bounded to prevent oversized framebuffer allocations.

## Transport

Use `MoshNWSessionTransportFactory` for the standard Apple-platform UDP path:

```swift
transportFactory: MoshNWSessionTransportFactory()
```

Implement `MoshSessionTransportFactory` and `MoshDatagramLink` when an
application needs a custom datagram backend, packet capture, proxy, or test
transport.

Applications that display Network.framework state should retain the
`MoshNWDatagramLink` created by their custom factory and consume its `events`
stream. The default factory deliberately does not impose application logging,
storage, or UI policy.

## Resilience

`MoshSessionResilienceConfiguration` controls recovery from a failed or silently
blackholed UDP path:

```swift
let resilience = MoshSessionResilienceConfiguration(
    maximumLinkRebuildAttempts: nil,
    initialRebuildBackoffMilliseconds: 200,
    maximumRebuildBackoffMilliseconds: 10_000,
    portHopIntervalMilliseconds: 10_000,
    noContactThresholdMilliseconds: 60_000
)
```

- `maximumLinkRebuildAttempts`: `nil` retries indefinitely. A finite value lets
  the package stop after that many consecutive rebuilds without real server
  contact.
- `initialRebuildBackoffMilliseconds` and
  `maximumRebuildBackoffMilliseconds`: exponential retry bounds.
- `portHopIntervalMilliseconds`: replaces a link after this much silence even
  when the socket has not reported an error. Set `0` to disable time-driven
  port hopping.
- `noContactThresholdMilliseconds`: emits one informational `.noContact` event
  per outage. It does not stop the session.

An installed socket is not considered recovered. The rebuild attempt count is
reset and `.reconnected` is emitted only after an authenticated server datagram
arrives on the new link.

## Local Prediction

```swift
let prediction = MoshPredictionConfiguration(
    displayPreference: .adaptive,
    predictsOverwrite: false
)
```

Available display preferences are `.always`, `.never`, `.adaptive`, and
`.experimental`. `.adaptive` is the normal default. Prediction affects the
renderer-ready `screenSnapshot`; it does not change bytes received from the
server.

## Stream Buffers

`MoshSession` accepts separate buffering choices for raw host operations,
display operations, and diagnostics:

```swift
let session = MoshSession(
    configuration: configuration,
    hostOperationBufferingPolicy: .bufferingNewest(512),
    renderOperationBufferingCapacity: 512,
    diagnosticEventBufferingPolicy: .bufferingNewest(512)
)
```

`renderOperationBufferingCapacity` must be at least one. When a slow render
consumer fills the buffer, TraversioMosh emits a wholesale `.resync(snapshot)`
so the display can recover instead of silently applying an incomplete
incremental sequence.

For an always-exact display, treat render events as invalidation signals and
read `session.screenSnapshot`. Raw `hostOperations` do not carry resync events.

## Datagram Sizing

`maximumSerializedFragmentByteCount` defaults to 472 bytes, keeping encrypted
datagrams within a conservative path MTU. Increase it only when the complete
network path is known to support the resulting datagram size.

Inbound decompression, fragment reassembly, terminal grids, and retained SSP
states have independent limits. These are safety bounds, not tuning knobs.

## SSP Timing

`MoshSSPSendTimingConfiguration` exposes acknowledgement, retry, adaptive send
interval, round-trip estimator, and shutdown attempt settings. Its defaults are
intended for production sessions.

Fixed send or timeout values are primarily useful for deterministic tests:

```swift
let timing = MoshSSPSendTimingConfiguration(
    sendIntervalMilliseconds: 50,
    timeoutMilliseconds: 250
)
```

Changing SSP timing affects retransmission, latency estimation, shutdown, and
network load. Prefer the adaptive defaults unless validation demonstrates a
specific need.
