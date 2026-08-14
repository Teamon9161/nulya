# Nulya

A minimal, self-evolving AI agent harness in Zig.

The kernel is intentionally tiny and immutable: an **append-only conversation
ledger** (for a stable prompt-cache prefix), a **batched agent loop** (many tool
calls per turn, one result turn back), one **output-discipline primitive**
(`emit`), and exactly **two builtin tools** — `shell` and `edit`. Every other
capability is meant to be grown by the model itself as a compiled Zig extension,
not baked into the core.

## Design

The reasoning behind every constraint lives in [`docs/`](docs/):

- [`DESIGN.md`](docs/DESIGN.md) — architecture, cache generation, ledger, loop,
  extension model, execution environment.
- [`base-tools.md`](docs/base-tools.md) — the `emit` primitive and output discipline.
- [`agents-and-review.md`](docs/agents-and-review.md) — subagent-as-self-invocation
  and the tool-review gate.

## Status

Walking skeleton. `src/` stands up the ledger, the tool boundary
(`ToolRequest{ args, ctx_header }` → `ToolResult`), `emit`, the two builtins, and
a loop that runs one scripted step. The model is a stub; the real provider drops
in behind `loop.Model` without changing the loop.

## Build

Requires Zig 0.16.

```sh
zig build run     # run the one-step skeleton demo
zig build test    # run unit tests
```
