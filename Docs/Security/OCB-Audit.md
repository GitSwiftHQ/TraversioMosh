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
- Future Mosh packet vectors once wire packets are implemented.

## Review Points

- Nonce construction must follow RFC 7253 formatting exactly.
- Mosh packet nonce construction must partition client/server sequence space
  before live interoperability claims.
- `double()` must avoid branches on secret block bits.
- Tag comparison must be constant-time for equal-length tags.
- Decryption must not expose plaintext when authentication fails.
- Key material lifetime and zeroization need a follow-up audit before
  production-readiness claims.
- CommonCrypto failure paths must remain fail-closed.
- Performance optimizations must not change exact RFC vector results.

## Current Status

- RFC 7253 AES-128/TAGLEN128 vectors pass.
- CommonCrypto AES block encryption/decryption is wired through the Swift
  package without an extra C target.
- Mosh packet-level nonce construction is not implemented yet.
- No real `mosh-server` encrypted packet interoperability has been run yet.
