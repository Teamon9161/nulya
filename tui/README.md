# nulya-tui

A driver client for `nulya session *`. It renders the ledger, takes user input,
and spawns steps — nothing else. Design contract and milestones live in
[`../docs/tui.md`](../docs/tui.md); the kernel's side of the wire is
[`../docs/DESIGN.md`](../docs/DESIGN.md) §3.4 (session file) and §14 (`session
step --stream`).

Status: **T3 (nulya views)**. The full card table of `../docs/tui.md` §4.2, fold
interaction by mouse and keyboard, `tui.toml` settings, theme tokens and an ascii
fallback (T2), plus `/sessions`, `/ext`, sub-session tabs and observer mode (T3).
`/settings`, `/usage` and a compiled single file are T4.

A session has exactly one writer. When somebody else holds it — a driver script,
another TUI, a parent session's shell — this one attaches as an **observer**: it
follows the ledger with `session events --follow`, can still `append` (the turn
waits in the inbox for the other writer's next step boundary), and offers
`press ↵ to take over` once the lease is free again.

## Run

```bash
bun install
zig build            # in the repo root: the TUI needs a nulya binary
bun run src/main.tsx                 # new session in the current directory
bun run src/main.tsx --session s-…   # reopen one
```

Flags: `--session <id>`, `--model <profile>`, `--workspace <dir>`,
`--max-steps <n>`.

The binary is found via `NULYA_BIN`, then `zig-out/bin/nulya[.exe]` at or above
the workspace (or above this package), then `PATH`.

With no API key configured the kernel falls back to its deterministic scripted
provider, so the TUI is usable offline:

```bash
NULYA_SCRIPTED_MODE=finish bun run src/main.tsx --model scripted
```

## Keys

| Key | Action |
|---|---|
| `Enter` | send |
| `Shift+Enter` / `Ctrl+J` | newline |
| `↑` (empty composer) | previous message |
| `Esc` (stepping) | `session cancel` — the kernel stops at its next step boundary |
| `Esc` (idle, empty composer) | browse mode: `j`/`k` move, `Enter` folds, `Esc` returns |
| click a head line | fold / unfold that card |
| `Ctrl+O` | fold / unfold the most recent tool or thinking card |
| `Ctrl+Shift+O` | expand everything (again to collapse everything) |
| `Ctrl+C` | kill the running step; press again to quit |
| `Enter` (observer, empty composer) | take over the session once the lease is free |
| `F2` | `/ext` — the extension store |
| `F3` | `/sessions` — the session store |
| `F4` | next tab (tabs appear once a second session is open) |
| `Ctrl+W` | close the current tab |
| `Enter` (browse, sub-session card) | open that session as a second tab |

Inside `/sessions`: `j`/`k` move, `Enter` opens, `n` starts a new session, `r`
refreshes, `Esc` closes. Inside `/ext`: `j`/`k` move, `Tab` switches pane
(extensions → versions → usage table), `a` activates and `r` rolls back the
highlighted version (confirm with `y`), `u` jumps to the usage table.

Slash commands: `/new [--model p]`, `/sessions`, `/ext`, `/step` (continue after
a spent step budget), `/cancel`, `/fold`, `/help`, `/quit`. Anything else
starting with `/` is sent to the model verbatim.

## Settings

`tui.toml`, user layer first then project layer — see `../docs/tui.md` §7.

- `%APPDATA%\nulya\tui.toml` (Windows) or `~/.config/nulya/tui.toml`
- `<workspace>/.nulya/tui.toml`

## Test

```bash
bun test
```

`test/cli.test.ts` drives the real binary in scripted mode (no API key, no
network) and asserts the `--stream` line protocol, the cancel path, and that a
replay lands on the same transcript as the live stream. `test/registry.test.ts`
covers every row of the evolution table without a renderer.
`test/render.test.tsx` snapshots each card through `@opentui/core/testing` and
drives the app with injected keys and mouse clicks. `test/files.test.ts` covers
the `.nulya/` projections (session store, writer lease, extension store, usage
journal). `test/observer.test.ts` runs `test/fixtures/driver-loop.ts` as a real
second driver and asserts the whole observer path: role discovery, live events,
append-while-observing, and take-over.

## Layout

```
src/nulya/   the only place that knows the CLI protocol and the .nulya/ layout
src/state/   session view state, driver/observer attachment, tabs, settings
src/render/  registry (the only name/prefix matching) + theme + cards
src/ui/      App, Transcript, Composer, StatusBar, TabBar, overlays/
```
