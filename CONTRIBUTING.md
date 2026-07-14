# Contributing

Thanks for helping improve TraversioMosh.

## Development Requirements

- macOS with an Xcode toolchain containing Swift 6.2 or newer
- the Apple platform SDK needed for the target being changed
- no running Mosh server for the deterministic package test suite

## Local Validation

Run the complete deterministic suite:

```bash
swift test
```

Run the strict Release build used for changes to concurrency or public APIs:

```bash
swift build -c release \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency \
  -Xswiftc -warnings-as-errors
```

Use a focused filter while iterating, then run the complete suite before opening
a pull request:

```bash
swift test --filter MoshSession
swift test --filter MoshSSPReceiver
swift test --filter MoshDatagramCipher
```

Finish with:

```bash
git diff --check
```

## Engineering Guidelines

- Start bug fixes from observable packet bytes, state transitions, transport
  events, task ownership, or terminal behavior and identify the failed
  invariant before changing code.
- Keep packet parsing, serialization, crypto inputs, and SSP transitions
  deterministic and fixture-testable.
- Add a focused regression for every protocol, lifecycle, or security fix.
- Prefer actors for shared mutable state, value types for protocol models, and
  explicit cancellation and teardown ownership.
- Keep SSH trust, application UI, persistence, telemetry, and lifecycle policy
  outside the package.
- Do not copy source or tests from third-party Mosh implementations.

Security-sensitive changes should cite the relevant RFC, official Mosh behavior,
or Apple platform contract and explain why failure remains conservative.

## Documentation

Public API or behavior changes should update the relevant guide under
`Documentation/`. Keep the README focused on installation, basic usage, and
links to task-oriented guides.

Code examples should use public APIs, avoid application-internal types, and be
checked against the current package products and platform minimums.

## Pull Requests

Describe:

- the user-visible or developer-visible behavior changed;
- why the change is needed;
- tests, builds, and live probes run; and
- compatibility or security effects.

For non-trivial commits, prefer:

```text
type(scope): short imperative summary

Why:

- reason for the change

What:

- main changes

Validation:

- commands or probes run
```

Common types are `feat`, `fix`, `refactor`, `test`, `docs`, and `chore`.
