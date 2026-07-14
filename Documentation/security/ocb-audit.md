<!--
Copyright (c) 2026 GitSwift LLC

Licensed under the MIT License.
See LICENSE for details.
-->

# OCB Audit Checklist

TraversioMosh implements the Mosh data-plane AEAD as AES-128-OCB with a
128-bit tag. The implementation is intentionally limited to byte-aligned inputs,
AES-128 keys, 1...15 byte RFC 7253 nonces, and 16-byte tags.

## Source Requirements

- RFC 7253 is the algorithm source for OCB3.
- CommonCrypto is the AES block primitive.
- Official Mosh source is reference-only evidence for Mosh parameter choices:
  16-byte AES key, 12-byte nonce, and 16-byte OCB tag.
- Do not copy GPL Mosh OCB source into TraversioMosh.

## Required Tests

- RFC 7253 Appendix A AES-128/TAGLEN128 vectors.
- Seal/open round trip for every vector.
- Authentication failure when the tag is modified.
- Invalid nonce length rejection.
- Ciphertext shorter than tag rejection.
- Mosh packet nonce known-answer vectors, plus encrypted-datagram
  interoperability against real `mosh-server`.

## Review Points

- Nonce construction must follow RFC 7253 formatting exactly.
- Mosh packet nonce construction must partition client/server sequence space
  before live interoperability claims.
- `double()` must avoid branches on secret block bits.
- Tag comparison must be constant-time for equal-length tags.
- Decryption must not expose plaintext when authentication fails.
- Key material lifetime and zeroization must hold up under repeated
  seal/open cycles and session teardown, not only at construction.
- CommonCrypto failure paths must remain fail-closed.
- Performance optimizations must not change exact RFC vector results.

## Current Status

- RFC 7253 AES-128/TAGLEN128 vectors pass.
- CommonCrypto AES block encryption/decryption is wired through the Swift
  package without an extra C target.
- Mosh packet-level nonce construction (`MoshPacketNonce`) is implemented: a
  12-byte nonce packs a 63-bit sequence number and a 1-bit client/server
  direction flag, partitioning the sequence space per direction the way
  official Mosh does, with the wire-visible 8-byte suffix and round-trip
  construction covered by tests.
- `MoshDatagramSequencer` enforces official Mosh's per-session AES block
  budget (2^47 blocks under one key, matching `crypto.cc`'s
  `Session::encrypt` bound) and fails closed: the datagram that would cross
  the limit is never sealed. It also tracks send/receive sequence per
  direction, classifying an authenticated but out-of-order datagram as a
  replay rather than accepting it as fresh state.
- `double()` (RFC 7253's GF(2^128) doubling used to derive the OCB L table)
  is branch-free on secret block bits: the carry-out bit is extracted with a
  shift and folded back in through a bitmask, not a conditional.
- Tag comparison (`constantTimeEquals`) is constant-time. `open()` computes
  the full candidate plaintext and expected tag internally, then compares
  before ever returning a value, so an authentication failure returns no
  plaintext bytes through the public API.
- Session key material — the raw AES-128 key and the derived OCB L table —
  lives in one shared, wipeable buffer, zeroed with `memset_s` when the last
  reference to the cipher chain deallocates. This is exercised by a
  dedicated deinit-observer test suite, not only inspected by hand. One
  known limitation remains outside this package's control: CommonCrypto
  expands and releases its own AES key schedule inside each `CCCrypt` call.
- Encrypted-datagram interoperability against real `mosh-server` has been
  validated extensively across multiple Linux distributions and a
  source-built current-Mosh target, covering baseline traffic, packet loss,
  roaming, malformed datagrams, and full-screen workloads. That live
  coverage runs outside this repository. See [Release Notes](../release-notes.md)
  for the release validation summary and [Live Testing](../live-testing.md) for
  a reproducible physical-device checklist.
