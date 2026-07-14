<!--
Copyright (c) 2026 GitSwift LLC

Licensed under the MIT License.
See LICENSE for details.
-->

# SSH Bootstrap

Mosh uses SSH only to authenticate the user, verify the server, and start
`mosh-server`. The server then prints a UDP port and a one-time session key;
TraversioMosh owns the encrypted UDP session from that point onward.

TraversioMosh deliberately does not choose an SSH library or trust policy. It
provides `MoshBootstrapExecutor`, a small adapter protocol that applications can
implement with [Traversio](https://github.com/GitSwiftHQ/Traversio), another SSH
client, or a test fixture.

## Construct the Remote Command

The default configuration produces the equivalent of:

```text
mosh-server new -c 256 -s
```

Create it through the typed builder instead of concatenating untrusted values:

```swift
let configuration = MoshBootstrapCommandConfiguration()
let command = try configuration.makeCommand()
```

Common options include:

```swift
let localeVariables = try MoshBootstrapLocaleFallback.variables(
    from: ProcessInfo.processInfo.environment
)

let configuration = MoshBootstrapCommandConfiguration(
    serverPath: "/usr/bin/mosh-server",
    bindAddress: .sshConnectionLocalAddress,
    portRange: try MoshBootstrapPortRange(60000...61000),
    colorCount: 256,
    localeVariables: localeVariables,
    remoteCommand: [],
    verboseLevel: 0
)
```

Use a fixed port such as `60001` for a simple test server with a narrow firewall
rule. Use a range when the server must support multiple concurrent sessions.

## Traversio Adapter

The following adapter turns a
[`Traversio`](https://github.com/GitSwiftHQ/Traversio) `SSHConnection` into a
`MoshBootstrapExecutor`. It shell-quotes each command argument before passing
the command string to the remote shell.

```swift
import Foundation
import Traversio
import TraversioMoshBootstrap

enum MoshBootstrapExecutionError: Error {
    case commandFailed(status: UInt32?, standardError: String)
}

struct TraversioBootstrapExecutor: MoshBootstrapExecutor {
    let connection: SSHConnection

    func runBootstrapCommand(
        _ command: MoshBootstrapCommand
    ) async throws -> String {
        let commandLine = ([command.executablePath] + command.arguments)
            .map(shellQuote)
            .joined(separator: " ")

        let result = try await connection.execute(commandLine)
        guard result.exitStatus == 0 else {
            throw MoshBootstrapExecutionError.commandFailed(
                status: result.exitStatus,
                standardError: String(
                    decoding: result.standardError,
                    as: UTF8.self
                )
            )
        }

        return String(decoding: result.standardOutput, as: UTF8.self)
    }
}

private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
```

Run and parse the bootstrap in one call:

```swift
let bootstrap = try await MoshBootstrapRunner.run(
    configuration: MoshBootstrapCommandConfiguration(),
    executor: TraversioBootstrapExecutor(connection: connection)
)
```

The SSH connection may close after a successful bootstrap; the detached
`mosh-server` process waits for the UDP client. Start the `MoshSession` promptly:
an uncontacted `mosh-server` normally exits after 60 seconds.

## Endpoint Selection

`MoshEndpoint.host` is the UDP destination. For predictable roaming and link
rebuilds:

- resolve the server once and retain the selected address for the session;
- make sure that address is reachable from the Apple device, not only from the
  machine running SSH;
- use the port returned by `MoshBootstrapParser`; and
- allow that UDP port through host and cloud firewalls.

The connect line contains secret session key material. Do not log the raw
bootstrap output. `MoshSessionKey` and `MoshEndpoint` redact their own string
representations, but an application log of the original command output would
bypass that protection.

## Bootstrap Errors

- `MoshBootstrapCommandError` means the local command configuration is invalid.
- `MoshBootstrapParseError` means no unique valid `MOSH CONNECT` line was found.
- An SSH or executor error means authentication, trust, command execution, or
  server setup failed before the UDP session began.
- A later `MoshSession.start()` error belongs to UDP transport or Mosh protocol
  setup, not SSH bootstrap.

For Ubuntu installation and firewall setup, see
[Ubuntu and Physical-Device Testing](live-testing.md).
