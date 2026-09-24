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
  designs not yet implemented (sandbox, policy hooks, evolution layer,
  watcher protocol).
- [`docs/tui.md`](docs/tui.md) — the Bun + OpenTUI frontend, the first full driver.
- [`docs/base-tools.md`](docs/base-tools.md) — the `emit` primitive and output discipline.
- [`docs/agents-and-review.md`](docs/agents-and-review.md) — subagent and
  review-gate design (not yet implemented; see PLAN).

## Status

A session is a durable append-only ledger file (one file = one generation =
one prompt-cache scope); the kernel projects it into a PromptIR whose turns
are a stable prefix, runs one step at a time (batched tool calls, one
`tool_results` turn back, cancellable, every call optionally gated), and
freezes the whole capability surface at `session new`. Changing model, tools or system
prompt means forking with history: `session new --parent <id>:<seq> --carry`.

Everything above `shell` is an extension: content-addressed immutable versions
in one per-machine store, a `current` pointer per layer, and one wire
(stdin/stdout/exit code). Ten extensions ship inside the binary (`nulya ext
seed`), including `std` (file tools), `agent` (delegation to nulya / codex /
claude / pi / another extension), `compact`, `handoff`, `plan`, `ask`,
`ground`, `coding`, `evolution`, `guide`. Providers: `openai`, `anthropic`,
`codex` (ChatGPT subscription) and an offline `scripted` stand-in; real cache
hits are measured by `zig build integration`. A workspace can live on another
machine (`--env remote:wsl|ssh|exec`). Drivers talk to it through the CLI only:
the TUI in `tui/`, and `drivers/goal.{sh,ps1}` in under 70 lines each.

Not yet: OS-enforced sandbox, policy hooks, the reactive-extension watcher
protocol, automatic compaction triggers, persistent extension runtimes. See
`docs/PLAN.md`.

## Build

Requires Zig 0.16.

```sh
zig build test    # unit tests
zig build e2e     # end-to-end tests against real built binaries (five suites)
zig build run     # fixed-prompt demo (scripted provider without an API key)
```

Release builds embed the pinned Zig toolchain:
`zig build -Dembed-toolchain -Dzig-archive=<path-to-zig-0.16-archive>`.

## Install and update

Release assets contain two executables for Linux, macOS, and Windows on x86_64
and aarch64: `nulya` (the kernel, carrying Zig 0.16.0) and `nulya-tui` (the
compiled frontend, carrying Bun). The installers place both in the same
directory. No separate Zig or Bun installation is needed.

On Linux or macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/Teamon9161/nulya/main/install.sh | sh
```

On Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/Teamon9161/nulya/main/install.ps1 | iex
```

The installers verify both release SHA-256 checksums. After installation, run
`nulya` to open the TUI. `nulya --version` reports the installed kernel version;
`nulya help` lists its command-line interface. `nulya update` checks the latest
GitHub Release and upgrades both executables after verifying their checksums.
On Windows, close a running TUI to let replacement finish. The update command
does not modify sessions, extensions, or configuration.

Releases are published by pushing a `v<version>` tag matching `build.zig.zon`.
The release workflow builds both executables for all six targets, verifies the
downloaded Zig archives against Zig's published SHA-256 values, and publishes
`checksums.txt`.
