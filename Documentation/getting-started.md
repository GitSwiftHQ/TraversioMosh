<!--
Copyright (c) 2026 GitSwift LLC

Licensed under the MIT License.
See LICENSE for details.
-->

# Getting Started

This guide connects a host application's SSH bootstrap result to a live
`MoshSession`, renders exact screen snapshots, sends input, resizes the terminal,
and shuts the session down.

## 1. Add the Package

```swift
dependencies: [
    .package(
        url: "https://github.com/GitSwiftHQ/TraversioMosh.git",
        from: "1.0.0"
    )
]
```

Add the two application-facing products:

```swift
.target(
    name: "TerminalApp",
    dependencies: [
        .product(name: "TraversioMoshBootstrap", package: "TraversioMosh"),
        .product(name: "TraversioMoshCore", package: "TraversioMosh"),
    ]
)
```

## 2. Start `mosh-server` Over SSH

The host application must authenticate the SSH server and verify its host key.
It then runs a command created by `MoshBootstrapCommandConfiguration` and passes
the command output to `MoshBootstrapParser`.

```swift
import TraversioMoshBootstrap

let command = try MoshBootstrapCommandConfiguration().makeCommand()
let output = try await sshExecutor.runBootstrapCommand(command)
let bootstrap = try MoshBootstrapParser.parse(output)
```

`sshExecutor` is an application adapter around an SSH library. The
[SSH Bootstrap](ssh-bootstrap.md) guide includes a complete adapter for
[Traversio](https://github.com/GitSwiftHQ/Traversio).

Use the address reached by the SSH connection as the Mosh endpoint. Resolve a
DNS name once before constructing the session and keep that address stable for
link rebuilds.

## 3. Create the Session

```swift
import TraversioMoshCore

let dimensions = try MoshTerminalDimensions(columns: 80, rows: 24)
let session = MoshSession(
    configuration: MoshSessionConfiguration(
        endpoint: MoshEndpoint(
            host: resolvedServerAddress,
            port: bootstrap.port,
            sessionKey: bootstrap.sessionKey
        ),
        initialTerminalDimensions: dimensions,
        transportFactory: MoshNWSessionTransportFactory()
    )
)
```

`MoshNWSessionTransportFactory` is the normal Network.framework UDP backend.
Use a custom transport factory only for a specialized network path, packet
capture, proxy, or deterministic test.

## 4. Consume Rendering and Diagnostics

Start stream consumers before `start()` so the application observes the first
frame and lifecycle events:

```swift
let renderTask = Task {
    for try await _ in session.renderOperations {
        let screen = await session.screenSnapshot
        await renderer.draw(screen)
    }
}

let diagnosticTask = Task {
    for await event in session.diagnosticEvents {
        await statusModel.consume(event)
    }
}

try await session.start()
```

Reading `screenSnapshot` after each render event gives an exact, renderer-ready
frame including rows, cursor, text attributes, title, and terminal modes. A
consumer that applies `renderOperations` incrementally must handle
`.resync(snapshot)` by replacing its entire displayed frame.

Do not use `hostOperations` as the only display source. It intentionally omits
re-based wire diffs and cannot guarantee an exact incremental display.

## 5. Send Input and Resize

Raw UTF-8 and control bytes can be sent directly:

```swift
try await session.sendTerminalInput(Array("uname -a\n".utf8))
```

If the host app owns cursor-key translation, use the current screen mode:

```swift
let screen = await session.screenSnapshot
try await session.sendTerminalInput(
    keyBytes,
    applicationCursorKeysEnabled: screen.isApplicationCursorKeysEnabled
)
```

Forward terminal geometry changes to the session:

```swift
try await session.resize(columns: 120, rows: 40)
```

The application remains responsible for synthesizing mouse reports, escape-key
UX, scrollback, selection, clipboard policy, and persistence.

## 6. Stop or Shut Down

`stop()` tears down local resources immediately and is idempotent:

```swift
await session.stop()
_ = try? await renderTask.value
await diagnosticTask.value
```

For a cooperative remote shutdown, call `shutdown()`. It sends the Mosh shutdown
state and waits for the server acknowledgement. If that task is cancelled, the
session remains alive until the application explicitly stops it.

```swift
do {
    try await session.shutdown()
} catch is CancellationError {
    await session.stop()
}
```

See [Sessions and Resilience](session-and-resilience.md) for terminal errors,
reconnection, no-contact reporting, and stream completion semantics.
