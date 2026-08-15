# nulya-tui

A driver client for `nulya session *`. It renders the ledger, takes user input,
and spawns steps — nothing else. Design contract and milestones live in
[`../docs/tui.md`](../docs/tui.md); the kernel's side of the wire is
[`../docs/DESIGN.md`](../docs/DESIGN.md) §3.4 (session file) and §14 (`session
step --stream`).

Status: **T1 (skeleton)**. Transcript with user / assistant / generic tool
cards, streaming, cancel, `--session` replay. The full card table, fold
interaction, `/sessions`, `/ext` and observer mode are T2–T4.

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
| `Esc` | `session cancel` — the kernel stops at its next step boundary |
| `Ctrl+O` | fold / unfold the most recent tool or thinking card |
| `Ctrl+Shift+O` | expand everything |
| `Ctrl+C` | kill the running step; press again to quit |

Slash commands: `/step` (continue after a spent step budget), `/cancel`,
`/fold`, `/help`, `/quit`. Anything else starting with `/` is sent to the model
verbatim.

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
replay lands on the same transcript as the live stream. `test/render.test.tsx`
snapshots each card through `@opentui/core/testing` and drives the app with
injected keystrokes.

## Layout

```
src/nulya/   the only place that knows the CLI protocol and the .nulya/ layout
src/state/   session view state, driver state machine, settings
src/render/  registry (the only name/prefix matching) + theme + cards
src/ui/      App, Transcript, Composer, StatusBar
```
