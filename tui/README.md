# nulya-tui

A driver client for `nulya session *`. It renders the ledger, takes user input,
and spawns steps — nothing else. Design contract and milestones live in
[`../docs/tui.md`](../docs/tui.md); the kernel's side of the wire is
[`../docs/DESIGN.md`](../docs/DESIGN.md) §3.4 (session file) and §14 (`session
step --stream`).

Status: **T8 — complete**. Cards and folding, `tui.toml` settings and keymap
overrides, `/sessions` `/ext` `/usage` `/settings` `/help`, sub-session tabs,
observer mode, a single-file build, `/model` and `/effort`, `/compact`, and the
slow loop's front end: `/outcome`, `/evolve`, `/mode`.

A session has exactly one writer. When somebody else holds it — a driver script,
another TUI, a parent session's shell — this one attaches as an **observer**: it
follows the ledger with `session events --follow`, can still `append` (the turn
waits in the inbox for the other writer's next step boundary), and offers
`press ↵ to take over` once the lease is free again.

## Install (Windows 11 + Windows Terminal)

Everything below is a normal PowerShell prompt inside Windows Terminal. Git Bash
works the same way with the obvious path changes.

```powershell
# 1. the kernel. Zig 0.16; the repo pins it through build.zig.zon.
cd C:\code\zig\nulya
zig build                       # produces zig-out\bin\nulya.exe

# 2. the front end. Bun 1.3+.
cd tui
bun install

# 3. run it, from the directory you want the agent to work in
cd C:\code\zig\nulya
bun run tui\src\main.tsx
```

The first frame is an empty transcript with a fresh session id in the header.
Type, press `Enter`. (Look and leave instead, and that fresh session is
un-created on the way out: a session the TUI itself made and never recorded
anything in does not stay behind as an empty row in `/sessions`. Sessions with
events, sessions with a turn still queued, and sessions opened with `--session`
are never touched.)

**Which `nulya.exe` gets used**, in order:

1. `$env:NULYA_BIN` — an absolute or workspace-relative path. Set this if you
   run the TUI outside the repo:
   `$env:NULYA_BIN = "C:\code\zig\nulya\zig-out\bin\nulya.exe"`
2. `zig-out\bin\nulya.exe` at or above the **workspace** (the directory the TUI
   was started in, or `--workspace`), then at or above this package.
3. `nulya.exe` on `PATH`.

If none resolve, the TUI says so and names all three candidates instead of
starting.

**The workspace** is the current directory unless `--workspace <dir>` says
otherwise. It is the directory that owns `.nulya\` (sessions, extensions, usage
journal) and the cwd every kernel call runs in — so start the TUI in the project
you want the agent to work on.

### A single executable

```powershell
cd C:\code\zig\nulya\tui
bun run compile                 # writes dist\nulya-tui.exe (~120 MB, Bun runtime included)
dist\nulya-tui.exe --session s-…
```

The compiled binary bundles only `src/`; it still needs `nulya.exe` at run time
and finds it by the same three rules (there is no `tui/` directory next to it,
so in practice: set `NULYA_BIN`, or run it from inside a repo checkout).

One trap: run it from your workspace, **not** from `tui\` itself. Bun reads
`bunfig.toml` from the current directory, and this package's is a development
preload the compiled binary neither has nor needs — starting it inside `tui\`
fails with `preload not found "@opentui/solid/preload"`.

### Choosing the provider and model

Start `nulya`, press `F5` (or type `/model`), pick a row, Enter. That is the
whole procedure — you should never have to open a config file to switch models.

The picker is one flat list: every model of every profile the kernel knows,
read from `nulya config show --json`. `↑↓` moves, `←→` turns the reasoning
effort dial of the highlighted row (`auto` = the provider's default, then the
levels that model accepts), Enter starts a session on it. A session freezes its
model when it is created (physics #2), so "switch model" always means "new
session on that model": on a fresh, untouched tab the new session simply takes
its place; on a tab you have used, a second tab opens. Rows whose profile has no
usable key stay in the list, dimmed (`no key · s to paste one`); Enter on one
only tells you why.

**Keys are entered on screen too.** Highlight a row, press `s`, paste the API
key, Enter. It is written into your user config
(`~/.nulya/config.toml` — on Windows `C:\Users\<you>\.nulya\config.toml`) as
that profile's `api_key`, in a small marked block the TUI can find and replace
later; the rest of the file is never touched, and the row turns
`ready · key in config`. Setting the profile's env var (`DEEPSEEK_API_KEY`, …)
works as well; a key in the config wins over the env var. Keys never enter a
session file or a tool's environment.

What you picked is remembered in `tui-state.json` next to that config, so the
next `nulya` starts on it. If nothing remembered or configured can run (no key),
the first screen IS the picker, with the reason under its title, on top of an
offline session — pick a row marked `ready`, or press `s` on one and paste.

Effort is not frozen: `/effort high` (or `/effort auto`) changes the current
tab's effort and the next step runs with it (`session step --effort`).

To skip the picker, name it on the command line (a one-off, not remembered):

```powershell
bun run tui\src\main.tsx --profile codex
bun run tui\src\main.tsx --profile deepseek --model deepseek-v4-pro --effort off
```

Profiles ("how to reach a provider, and which model ids it serves") and the
model catalog ("what each id is") live in `default.toml` at the repo root, merged
with the system/user/project config chain (`../docs/DESIGN.md` §9.5) — `nulya
config show` prints the three paths and every profile's state. Built in:
`openai`, `anthropic`, `deepseek`, `deepseek-anthropic`, `openrouter` (each takes
an API key), `codex` (uses whatever `codex login` left in `~/.codex/auth.json`),
`scripted` (offline). To add an endpoint that is not built in, put a
`[[provider.profiles]]` block with `kind`, `base_url`, `models` into
`~/.nulya/config.toml`; it then shows up in `/model` like the others.
Inside the TUI, `/new` opens another session on the last pick;
`/new --profile <p> [--model <id>]` on a named one.

Offline, with no key of any kind:

```powershell
$env:NULYA_SCRIPTED_MODE = "finish"
bun run tui\src\main.tsx --profile scripted
```

### Flags

`--session <id>` reopen · `--new` fresh session (the default) ·
`--profile <p>` `--model <id>` `--effort <e>` · `--workspace <dir>` ·
`--max-steps <n>` (a per-step budget the kernel clamps to its own ceiling).

## A round trip

Read the kernel, edit it, run the tests, cancel something, come back later:

```powershell
cd C:\code\zig\nulya
bun run tui\src\main.tsx --profile codex
```

1. **Ask.** `read src/emit.zig and make the head/tail budget configurable`,
   `Enter`. The agent reads the kernel with `nulya src` (a `⌕ read kernel` card),
   edits with the `edit` tool (an `✎` card whose diff is expanded by default),
   and runs `zig build test` in a `$` shell card (collapsed — `Ctrl+O`, a click
   on the head line, or `Esc` then `j`/`k` and `Space` opens it).
2. **Cancel.** `Esc` while a step is running is `nulya session cancel`: the
   kernel stops at its next step boundary, so the tool that is already running
   finishes and the ledger stays legal. If you need the process gone right now,
   `Ctrl+C` kills the step (press it again to quit the TUI); the next open
   repairs the interrupted batch. The kill takes the step's process tree with
   it (`taskkill /T` on Windows), so a `zig build` the agent started stops too.
3. **Leave and come back.** `Ctrl+C` twice quits. Reopen exactly where you were:

   ```powershell
   bun run tui\src\main.tsx --session s-1786820965784-617765
   ```

   The id is in the header line, and `F3` lists every session in the workspace
   (newest first, `● live` when another process holds the writer lease).
   A replayed session draws the same transcript the live stream did — that
   equality is pinned by a test.
4. **Watch the evolution.** When the agent builds an extension and activates it,
   a `⚡ capability` banner appears mid-transcript. `F2` shows the store: version
   line, which version this session froze, which one the *next* session will
   pick up, and the tool-usage counts behind promotion.

## Keys

| Key | Action |
|---|---|
| `Enter` | send |
| `Shift+Enter` / `Ctrl+J` | newline |
| `↑` / `↓` (empty composer) | walk the message history; keeps walking while the buffer is still the recalled entry |
| `Esc` (stepping) | `session cancel` — the kernel stops at its next step boundary |
| `Esc` (idle, empty composer) | browse mode: `j`/`k` move, `Space` folds, `Esc` returns |
| click a head line | fold / unfold that card |
| `Ctrl+O` | fold / unfold the most recent tool or thinking card |
| `Ctrl+Shift+O` | expand everything (again to collapse everything) |
| `Ctrl+C` | kill the running step (and, on Windows, its whole process tree); press again within a few seconds to quit. Idle: quit |
| `Enter` (observer, empty composer) | take over the session once the lease is free |
| `Enter` (browse, sub-session card) | open that session as a second tab |
| `F1` | `/help` — every binding, as currently bound |
| `F2` | `/ext` — the extension store |
| `F3` | `/sessions` — the session store |
| `F4` | next tab (tabs appear once a second session is open) |
| `F5` | `/model` — pick profile, model and effort; Enter starts a session on it |
| `Ctrl+W` | close the current tab (with one tab it is the composer's delete-word, as in a shell) |

Inside `/sessions`: `j`/`k` move, `Enter` opens, `n` starts a new session, `r`
refreshes, `Esc` closes. Inside `/ext`: `j`/`k` move, `Tab` switches pane
(extensions → versions → usage table), `a` activates and `r` rolls back the
highlighted version (confirm with `y`), `u` jumps to the usage table. Inside
`/usage`: `r` refreshes.

Slash commands: `/model` (F5), `/effort <level|auto>`,
`/new [--profile p] [--model id]`, `/sessions`, `/ext`, `/usage`, `/settings`,
`/compact [focus]`, `/outcome <success|partial|failure> [note]`, `/evolve`,
`/mode <id>[@version]`, `/help`, `/step` (continue after a spent step budget),
`/cancel`, `/fold`, `/quit`. Anything else starting with `/` is sent to the
model verbatim.

`/outcome` records how a session went in the outcome journal beside the ledger —
recording nothing means *unjudged*, which is not the same as failure, so nothing
is written until you say so. `/evolve` builds the `extensions/evolution` package
that ships with nulya and starts a session carrying it; `/mode <id>` does the
same with any built extension. Neither activates anything: the package is a
member of that one session's composition, and the next session is untouched.

`/compact` asks this session for a continuation brief and moves the tab to a new
session that points back at it — the old file stays on disk, whole. The
procedure lives in `extensions/compact`, another package that ships with nulya;
the TUI builds it, runs it, and watches. While it works it holds the session's
writer lease, so the tab shows itself as an observer and the two turns appear as
they land. Building it the first time needs a Zig toolchain (`NULYA_ZIG`, an
embedded build, or a `zig` on PATH); if the brief never arrives, nothing moves
and the notice says so.

Every key in the first table above is rebindable — see `[keys]` below. `/help`
reads the live keymap, so it shows your bindings, not these defaults.

## Settings

`tui.toml`, user layer first then project layer — see `../docs/tui.md` §7.
`/settings` shows the values in force and which file each came from; the TUI
never writes them.

- `%APPDATA%\nulya\tui.toml` (Windows) or `~/.config/nulya/tui.toml`
- `<workspace>\.nulya\tui.toml`

```toml
[transcript]
edit_diff      = "expanded"    # expanded | collapsed
tool_output    = "collapsed"   # collapsed | expanded
thinking       = "collapsed"   # collapsed | hidden | expanded
max_width      = 100
history_window = 400           # cards mounted at once, newest first; 0 = all
ascii          = false         # plain glyphs for fonts without the box drawing set

[ui]
theme  = "nulya-dark"          # nulya-dark | nulya-light   (NO_COLOR wins over both)
motion = true                  # spinner and streaming cursor

[keys]                         # action = binding; names are the rows of /help
cancel  = "escape"
fold    = "ctrl+o"
foldAll = "ctrl+shift+o"
help    = "f1"
ext     = "f2"
sessions = "f3"
nextTab = "f4"
closeTab = "ctrl+w"
redraw  = "ctrl+l"
quit    = "ctrl+c"
```

## Test

```powershell
bun run typecheck
bun test
```

No API key and no network: every test drives the real `nulya.exe` in scripted
mode. `test/cli.test.ts` asserts the `--stream` line protocol, the cancel path,
and that a replay lands on the same transcript as the live stream.
`test/registry.test.ts` covers every row of the evolution table without a
renderer. `test/render.test.tsx` snapshots each card and drives the app with
injected keys and mouse clicks. `test/files.test.ts` covers the `.nulya/`
projections. `test/observer.test.ts` runs `test/fixtures/driver-loop.ts` as a
real second driver and asserts the whole observer path. `test/views.test.tsx`
covers `/help`, `/settings`, `/usage` and a `[keys]` override end to end.
`test/perf.test.tsx` builds a 5000-event session and holds the T4 bar: it opens
in well under a second and streaming stays under a frame. `test/lifecycle.test.tsx`
pins what a TUI process leaves behind. `test/driver.test.ts`
pins the driver's honesty (one step at a time, a kill is not a crash, a crash is
not silence, an old error does not outlive the next step); `test/ledger.test.ts`
the shell-result parsing; `test/composer.test.tsx` history walking and the
consumed-key rule.

## Layout

```
src/nulya/   the only place that knows the CLI protocol and the .nulya/ layout
src/state/   session view state, driver/observer attachment, tabs, settings
src/render/  registry (the only name/prefix matching) + theme + cards
src/ui/      App, Transcript, Composer, StatusBar, TabBar, overlays/
build.ts     bun build --compile → dist/nulya-tui[.exe]
```
