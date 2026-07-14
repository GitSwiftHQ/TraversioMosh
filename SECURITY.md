# Security Policy

TraversioMosh processes authenticated UDP traffic, terminal control sequences,
and cryptographic key material. Please report suspected vulnerabilities
privately.

## Supported Versions

| Version | Supported |
| --- | --- |
| 1.0.x | Yes |
| Earlier development snapshots | No |

Security fixes are made on the current supported release line. Users should
upgrade to the latest patch release before reporting an issue already addressed
in release notes.

## Reporting a Vulnerability

Use the repository's **Security → Report a vulnerability** flow when available.
If private vulnerability reporting is unavailable, contact the repository owner
privately through the GitSwiftHQ organization before sharing technical details.

Do not open a public issue for a potentially exploitable problem involving:

- session keys, nonces, encryption, authentication, or replay handling;
- SSH bootstrap output or host-identity confusion;
- malformed packet, protobuf, compressed, fragmented, or terminal input;
- memory or CPU exhaustion reachable from network traffic;
- terminal control sequences crossing an application security boundary; or
- lifecycle behavior that exposes another user's session or terminal content.

Include the affected version or commit, Apple platform and OS version, Swift
toolchain version, server implementation/version, expected and observed
behavior, and the smallest safe reproduction. Redact credentials, session keys,
raw `MOSH CONNECT` lines, private hostnames, and user terminal content.

## Disclosure

Please allow maintainers time to reproduce, fix, validate, and publish an update
before public disclosure. Once a fix is available, the release notes will
describe the user-visible impact and upgrade requirement without publishing
active secrets or unnecessary exploit detail.
