<!--
Copyright (c) 2026 GitSwift LLC

Licensed under the MIT License.
See LICENSE for details.
-->

# Security

TraversioMosh handles an authenticated UDP protocol after an SSH bootstrap. A
secure application must preserve both halves of that boundary: SSH establishes
the server identity and delivers the session secret; TraversioMosh authenticates
the subsequent Mosh datagrams.

Report suspected vulnerabilities privately according to
[`SECURITY.md`](../SECURITY.md).

## SSH Trust Boundary

TraversioMosh does not authenticate SSH servers, manage known hosts, choose
credentials, or execute remote commands itself. The host application must:

- apply an explicit host-key trust policy;
- protect passwords, private keys, agents, and interactive authentication;
- run the generated `mosh-server` command on the intended SSH connection; and
- reject failed or ambiguous bootstrap output.

The [Traversio](https://github.com/GitSwiftHQ/Traversio) adapter in
[SSH Bootstrap](ssh-bootstrap.md) is one integration option. TraversioMosh does
not require Traversio.

## Datagram Authentication

Mosh packets use AES-128-OCB as specified by
[RFC 7253](https://www.rfc-editor.org/rfc/rfc7253). TraversioMosh validates the
session key, constructs direction-specific nonces, authenticates datagrams
before decoding their payloads, rejects direction mismatches, and enforces send
sequence and per-key encrypted-block limits.

Unauthenticated, truncated, malformed, replayed, or wrong-direction packets do
not become terminal output. Malformed authenticated protocol state fails closed
when continuing would make the synchronized session ambiguous.

The detailed cipher review record is available in the
[OCB Audit Checklist](security/ocb-audit.md).

## Key Handling

`MoshSessionKey` and `MoshEndpoint` redact their `description` and
`debugDescription`. Cipher key material and derived OCB values are kept in a
shared wipeable buffer and cleared when the last cipher reference is released.
Applications can call `MoshSessionKey.wipe()` after the complete session and all
copies of the bootstrap result are no longer needed.

Do not log:

- raw `MOSH CONNECT` output;
- `MoshSessionKey.rawBytes` or `encodedRepresentation`;
- packet plaintext captured below the session boundary; or
- credentials and host-trust decisions from the SSH bootstrap.

Swift values, operating-system frameworks, crash reports, and debugger memory
can create copies outside the package's wipeable buffers. Key wiping reduces
retention; it is not a guarantee that a secret never existed elsewhere in
process memory.

## Resource Limits

Peer-controlled inputs are bounded before materialization where practical,
including:

- protobuf lengths and nesting;
- decompressed output;
- cumulative fragment reassembly bytes;
- terminal dimensions and total framebuffer cells;
- retained synchronized-state count and aggregate estimated memory; and
- render stream buffering.

These bounds reduce denial-of-service risk but cannot make an interactive
network client immune to CPU, memory, radio, or bandwidth exhaustion. Host apps
should still apply user-visible session limits and stop sessions they no longer
need.

## Network and Application Responsibilities

- Restrict inbound UDP on the server to the port or range used for Mosh.
- Keep the package and server implementation updated.
- Treat network path events as diagnostics, not authentication signals.
- Decide when an indefinitely reconnecting session should be stopped.
- Apply application policy to clipboard, hyperlinks, notifications, telemetry,
  background execution, and persisted terminal content.
- Render terminal control sequences defensively; do not turn remote title,
  clipboard, or hyperlink values into privileged application actions.
