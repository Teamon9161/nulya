# nulya-tui

A driver client for `nulya session *`. It renders the ledger, takes user input,
and spawns steps — nothing else. Design contract and milestones live in
[`../docs/tui.md`](../docs/tui.md); the kernel's side of the wire is
[`../docs/DESIGN.md`](../docs/DESIGN.md) §3.4 (session file) and §14 (`session
step --stream`).

Status: **T8 — complete**. Cards and folding, `tui.toml` settings and keymap
overrides, `/sessions` `/ext` `/usage` `/settings` `/help`, sub-session tabs,
observer mode, a single-file build, `/model` `/provider` `/effort`, `/compact`, the
slow loop's front end (`/outcome`, `/evolve`, `/as`), and the permission mode:
every tool call is gated, `/mode` says whether you see it first.

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

The first frame is an empty transcript over a draft: no session exists yet. The
line under the composer names the model the next session will run on
(`gpt-5.6-luna (medium) · tools 2+5 · …`; click it for `/model`), and anything
you change in `/ext` or `/model` before typing goes into that session. The
session is created the moment you send the first message — look and leave
instead, and nothing was ever written to `.nulya/sessions/`. (Sessions opened
with `--session <id>` are real from the start and are never touched.)

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

Two screens, two questions. `F5` (or `/model`) picks **what the next session
runs on**; `F6` (or `/provider`) is where **endpoints and their keys** live.
Either way you should never have to open a config file to switch models.

`/model` is one row per model of every profile that can run right now, read from
`nulya config show --json` — `provider · label · id · context · ‹ effort › ·
✓ current`. `↑↓` moves, `←→` turns the reasoning effort dial of the highlighted
row (`auto` = the provider's default, then the levels that model accepts), Enter
starts a session on it. A session freezes its model when it is created
(physics #2), so "switch model" always means "new session on that model": on a
fresh, untouched tab the new session simply takes its place; on a tab you have
used, a second tab opens. Profiles without a usable key are not in this list at
all — that is what keeps it short. The model line in the title bar and in the
composition card is a click target for the same screen.

A row's context window and effort levels come from the profile's own endpoint
when that endpoint reports them, and only otherwise from the shared `[[models]]`
catalog: `codex` lists what your ChatGPT subscription actually serves, read from
the Codex CLI's model cache, and `nulya config show --refresh` re-fetches it. So
the same id can honestly show different numbers under two different providers.

`/provider` lists every profile, runnable or not: `name · wire · endpoint ·
N models · state`, with its model ids on the detail line under the list
(browsing is never gated — only starting a session is). Enter on a provider that
can run goes to `/model` landed on its first model — that is "pick a provider,
then its model". Enter on a keyless OpenAI/Anthropic endpoint goes straight to
pasting its key; `codex` says it signs in with `codex login` instead.

**Keys are entered on screen too.** In `/provider`, highlight a row, press `s`,
paste the API key, Enter. It is written into your user config
(`~/.nulya/config.toml` — on Windows `C:\Users\<you>\.nulya\config.toml`) as
that profile's `api_key`, in a small marked block the TUI can find and replace
later; the rest of the file is never touched, and the row turns
`ready · key in config`. Setting the profile's env var (`DEEPSEEK_API_KEY`, …)
works as well; a key in the config wins over the env var. Keys never enter a
session file or a tool's environment. `a` (or the last row) adds an OpenAI- or
Anthropic-compatible endpoint: name → wire → base URL → model ids → key.

What you picked is remembered in `tui-state.json` next to that config, so the
next `nulya` starts on it. If nothing remembered or configured can run (no key),
the first screen is the one that can fix it, with the reason under its title, on
top of an offline session: `/model` when something else could have run, and
`/provider` when no provider works at all.

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
`~/.nulya/config.toml` (or let `/provider`'s `a` write it for you); it then shows
up in `/model` like the others.
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

   `F3` lists every session in the workspace with its id (newest first,
   `● live` when another process holds the writer lease).
   A replayed session draws the same transcript the live stream did — that
   equality is pinned by a test.
4. **Watch the evolution.** When the agent builds an extension and activates it,
   a `⚡ capability` banner appears mid-transcript. `F2` shows the store: every
   id in every root (source that never built included, with the kernel's own
   sentence about why), an `●`/`○` switch per extension (`Enter` turns it on
   for the next session — activate + pin its tools — or off), the version line,
   which version this session froze, and the tool-usage counts behind promotion.

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
| `F5` | `/model` — the models that can run, with effort; Enter picks what the next session runs on (a draft tab just changes its pick; a started tab gets a new draft beside it) |
| `F6` | `/provider` — endpoints and their keys; `s` pastes a key, `a` adds a compatible endpoint, Enter on a ready one goes to its models |
| `Ctrl+W` | close the current tab (with one tab it is the composer's delete-word, as in a shell) |
| click the model under the composer | `/model` |

Inside `/sessions`: `j`/`k` move, `Enter` opens, `n` starts a new session, `r`
refreshes, `Esc` closes. Inside `/ext`: `j`/`k` move, `Tab` switches pane
(extensions → versions → tools → usage table), `Enter` (or a click on the
`●`/`○`) turns the highlighted extension on or off for the next session,
`b` builds the source in its store directory, `Space` in the tools pane pins
one tool and `A` makes that pin permanent, `a` activates the highlighted version
on the version line (confirm with `y`) — pointing at an older one is the
rollback, there is no second verb — `p` prunes old versions, `u` jumps to the
usage table. Inside `/usage`: `r` refreshes.

Slash commands: `/model` (F5), `/provider` (F6), `/mode [ask|auto]`,
`/effort <level|auto>`, `/new [--profile p] [--model id]`, `/sessions`, `/ext`,
`/usage`, `/settings`, `/compact [focus]`,
`/outcome <success|partial|failure> [note]`, `/evolve`, `/as <id>[@version]`,
`/help`, `/step` (continue after a spent step budget), `/cancel`, `/fold`,
`/quit`. Anything else starting with `/` is sent to the model verbatim.

`/mode` is the permission mode. Every step this TUI runs is gated: the kernel
asks before each tool call (`nulya session step --gate`) and the TUI answers. In
`ask` — the default — a call no rule settles waits for you under its own card:
`y` allows, `n` denies, `N` denies with a reason the model reads, `a` allows and
stops asking about that tool (or that `shell` command's first word) for the rest
of the run. In `auto` the same calls just run. The chip on the status line shows
which, and a click flips it; the choice is remembered in `tui-state.json`.
Standing rules live in `tui.toml`:

```toml
[driver]
mode = "ask"                       # where a run starts; the chip and /mode win

[approvals]
allow = ["ext:std/read", "shell:git status"]
ask   = ["shell:git push"]         # asked even in auto
deny  = ["shell:rm -rf /"]         # never asked, never run
manifest_readonly = true           # believe a tool's own "readonly": true
```

An entry is either a tool (`ext:std/read`, `shell`, `edit`) or a `shell` command
prefix (`shell:git`). `deny` outranks everything, `ask` outranks the mode, and a
tool the manifest calls `readonly` is allowed unless you switch that off. None of
it is a security boundary — an extension runs with the same authority as `shell`
(DESIGN §9); it is about what you want to look at.

`/outcome` records how a session went in the outcome journal beside the ledger —
recording nothing means *unjudged*, which is not the same as failure, so nothing
is written until you say so. `/evolve` builds the `extensions/evolution` package
that ships with nulya and starts a session carrying it; `/as <id>` does the
same with any built extension. Neither activates anything: the package is a
member of that one session's composition, and the next session is untouched.

The model can propose the same move itself. Every session this TUI starts
carries the bundled `handoff` package (`[extensions] handoff`), whose tool
writes `.nulya/handoffs/<session>-<n>.md` and stops — that file IS the proposal,
and nothing has happened yet. In `ask` the brief appears above the composer with
`Enter follow · Esc dismiss`; in `auto` the fork happens and a line says so.
Following one is `/compact` with the brief already written, so it is the same
fork and the old session stays whole on disk.

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
composition    = "collapsed"   # collapsed | expanded — the session card at the top
max_width      = 100
history_window = 400           # cards mounted at once, newest first; 0 = all
ascii          = false         # plain glyphs for fonts without the box drawing set

[ui]
theme  = "nulya-dark"          # nulya-dark | nulya-light   (NO_COLOR wins over both)
motion = true                  # spinner and streaming cursor

[driver]
mode = "ask"                   # ask | auto — where a run starts (see /mode above)

[approvals]                    # standing answers to the gate; see /mode above
allow = []
ask   = []
deny  = []
manifest_readonly = true

[extensions]
sync_on_start = true           # build the drafts in the store roots on the way in
auto_activate = true           # let that pass point `current` at what it built
handoff       = true           # every session carries the `handoff` tool, pinned

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
