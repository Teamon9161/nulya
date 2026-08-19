# Nulya

A minimal, self-evolving AI agent harness in Zig.

The kernel is intentionally tiny and immutable: an **append-only conversation
ledger** (for a stable prompt-cache prefix), a **batched agent loop** (many tool
calls per turn, one result turn back), one **output-discipline primitive**
(`emit`), and exactly **one builtin tool** — `shell`. Every other
capability is meant to be grown by the model itself as an extension, versioned
immutably, and promoted into the model-facing tool set at session boundaries
based on real usage — not baked into the core.

## Docs

- [`CLAUDE.md`](CLAUDE.md) — entry point for AI collaborators: physics, module
  map, current status, conventions. Start here.
- [`docs/DESIGN.md`](docs/DESIGN.md) — **what exists**: the implemented
  architecture and invariants, kept in sync with `src/`.
- [`docs/PLAN.md`](docs/PLAN.md) — **what's next**: direction, roadmap, and
  designs not yet implemented (durable ledger, session CLI, script extensions,
  evolution layer, drivers, slow loop).
- [`docs/base-tools.md`](docs/base-tools.md) — the `emit` primitive and output discipline.
- [`docs/agents-and-review.md`](docs/agents-and-review.md) — subagent and
  review-gate design (not yet implemented; see PLAN).

## Status

v0.1 self-evolution core is frozen and proven end-to-end (`tests/e2e.zig`, real
binaries, no mocks): a session exposing only `shell` builds and activates
its own extension via the `nulya` CLI, usage is journaled, and the next session
promotes that extension into the native tool set at zero cache cost.

Not yet: durable ledger / resume, interactive frontend (bare `nulya` runs a
fixed-prompt demo), compaction, subagents, sandbox, Anthropic provider, script
extensions. See `docs/PLAN.md`.

## Build

Requires Zig 0.16.

```sh
zig build test    # unit tests
zig build e2e     # extension closed-loop end-to-end tests
zig build run     # fixed-prompt demo (scripted provider without an API key)
```

Release builds embed the pinned Zig toolchain:
`zig build -Dembed-toolchain -Dzig-archive=<path-to-zig-0.16-archive>`.
