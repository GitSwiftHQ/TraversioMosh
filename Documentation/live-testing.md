<!--
Copyright (c) 2026 GitSwift LLC

Licensed under the MIT License.
See LICENSE for details.
-->

# Ubuntu and Physical-Device Testing

This guide prepares a real Ubuntu host for an Apple-device session and provides
a focused acceptance checklist for any application embedding TraversioMosh,
including SwiftServer.

Mosh bootstraps over SSH and then moves to UDP. The official documentation uses
UDP ports `60000` through `61000` by default; `mosh-server` also supports a fixed
port or a narrower range. See the [Mosh usage guide](https://mosh.org/) and the
Ubuntu [`mosh-server` manual](https://manpages.ubuntu.com/manpages/jammy/man1/mosh-server.1.html).

## 1. Install the Server

On Ubuntu 22.04 or 24.04:

```bash
sudo apt update
sudo apt install --yes mosh openssh-server python3 less nano tmux
sudo systemctl enable --now ssh
mosh-server --version
```

Ubuntu publishes Mosh through its normal package archive; available versions can
be checked in the [Ubuntu package index](https://packages.ubuntu.com/search?keywords=mosh).

Confirm that the account intended for the test can log in over SSH with the same
host, port, credentials, and host-key policy the application will use:

```bash
ssh user@server.example.com
command -v mosh-server
locale
```

Do not start `mosh-server` manually for the application test. The application
bootstrap should start it and consume its one-time port and session key.

## 2. Open UDP Access

For a simple single-session test, use one fixed UDP port such as `60001`:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 60001/udp
sudo ufw status
```

If the machine is behind a cloud firewall, router, NAT gateway, or security
group, allow or forward the same UDP port there. SSH success proves only TCP
reachability; it does not prove that the device can reach the Mosh UDP port.

For multiple simultaneous sessions, allow a small range and configure the same
range in the application:

```bash
sudo ufw allow 60000:60020/udp
```

The official default is `60000:61000/udp`, but a narrower range reduces exposed
surface when the deployment does not need hundreds of concurrent sessions.

## 3. Configure the Bootstrap

Use the same fixed port in `MoshBootstrapCommandConfiguration`:

```swift
let bootstrapConfiguration = MoshBootstrapCommandConfiguration(
    bindAddress: .sshConnectionLocalAddress,
    portRange: MoshBootstrapPortRange(port: 60001)
)

let bootstrap = try await MoshBootstrapRunner.run(
    configuration: bootstrapConfiguration,
    executor: sshBootstrapExecutor
)
```

Configure the host application or SwiftServer machine with:

- the SSH host, port, username, authentication, and explicit host-key policy;
- Mosh as the terminal transport;
- UDP port `60001`, or the same allowed range if the application exposes it;
- a server address reachable directly from the physical Apple device; and
- an 80×24 or larger initial terminal size.

The application should run the SSH bootstrap itself. Do not copy a `MOSH
CONNECT` key into logs, screenshots, issue reports, or persistent settings.

## 4. Basic Device Acceptance

Run these checks from a physical iPhone, iPad, or Mac before testing roaming:

1. Connect and confirm the shell prompt appears.
2. Run `uname -a`, `pwd`, and `locale`; verify output is complete.
3. Enter and edit ASCII plus non-ASCII text such as `你好 — café`.
4. Rotate or resize the terminal and verify rows, columns, cursor position, and
   wrapping update without reconnecting.
5. Run `less`, `nano`, `top`, and a `tmux` session; exercise arrows, page keys,
   alternate screen, color, and exit paths.
6. Close normally, reconnect, and confirm no orphaned terminal UI remains.

When a display is driven incrementally, verify that a `.resync` operation
replaces the complete frame. A snapshot-driven renderer should read
`MoshSession.screenSnapshot` after render invalidations.

## 5. Large Output

Generate more than 4 MiB of terminal output in one session:

```bash
python3 -c 'import sys; sys.stdout.write(("0123456789abcdef" * 128 + "\n") * 2048); sys.stdout.flush()'
```

Confirm that:

- the final prompt returns;
- the UI remains responsive;
- output does not duplicate or become permanently scrambled;
- memory settles after the workload; and
- input and resize still work afterward.

## 6. One-Hour Single-Session Soak

Keep one session alive for at least an hour. This command emits a timestamp
every three seconds without replacing the session:

```bash
i=0; while [ "$i" -lt 1200 ]; do date -u +'%Y-%m-%dT%H:%M:%SZ'; sleep 3; i=$((i + 1)); done
```

During the soak, occasionally type input, resize the terminal, enter and leave
`tmux`, and inspect liveness. Success means the same session reaches the final
prompt with no unexplained reconnect loop, no growing input delay, and no
unbounded memory growth.

## 7. Real Network Transitions

Exercise both initial no-route behavior and recovery of an established session.

### Initial `.waiting`

1. Disable Wi-Fi and cellular data, or enable airplane mode.
2. Attempt to start a new Mosh session.
3. Confirm the Network.framework link reports `.waiting` when the host app
   consumes `MoshNWDatagramLink.events`.
4. Confirm the start/send path fails promptly with
   `MoshDatagramTransportError.notConnected` instead of hanging indefinitely.
5. Restore connectivity and create a new session.

The default `MoshNWSessionTransportFactory` intentionally hides link-specific
UI state. A host that must display exact Network.framework events should use a
small capturing `MoshSessionTransportFactory` and retain its
`MoshNWDatagramLink`.

### Established Session Recovery

1. Start a session on Wi-Fi and run a command every few seconds.
2. Switch from Wi-Fi to cellular or a phone hotspot without closing the
   terminal.
3. Enable airplane mode for 30–60 seconds, then restore connectivity.
4. Verify `.reconnecting` appears during recovery and `.reconnected` appears
   only after authenticated server traffic resumes.
5. Confirm the same shell and `tmux` process survive, then send input and resize
   again.

Also background and foreground the host application according to its supported
lifecycle policy. TraversioMosh preserves protocol state while it is allowed to
run; the application owns platform background-execution decisions.

## 8. Cleanup and Troubleshooting

Remove a temporary firewall rule when the test is finished:

```bash
sudo ufw delete allow 60001/udp
```

If SSH works but the Mosh screen never appears, check:

- the returned UDP port matches the host and cloud firewall rules;
- `MoshEndpoint.host` is reachable from the device and is not a container-only
  or loopback address;
- the bootstrap starts a fresh server and the client contacts it within 60
  seconds;
- no previous server process already owns the fixed port;
- `-s` selected the intended interface on a multihomed host; and
- both the server and application are using a UTF-8 locale.

Capture diagnostics without recording the session key. Useful evidence includes
the OS and Mosh versions, timestamps, non-secret endpoint and port, session
events, liveness snapshots, terminal dimensions, and whether the failure occurs
before or after authenticated UDP traffic is received.
