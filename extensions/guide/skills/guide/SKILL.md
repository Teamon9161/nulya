---
name: guide
description: How this harness works — configuring it, writing and installing an extension, skill, system prompt or session driver, reading the kernel's own source, and driving sessions.
---

# Nulya, from the inside

Pointers and the shortest recipe. The truth lives in the commands — `nulya
help`, `nulya ext api`, `nulya src`, `nulya config show` — and they are built
from the same code that runs, so when this page and a command disagree, the
command is right.

`nulya` may not be on PATH. The running binary's path is always in the
`NULYA_EXE` environment variable: `"$NULYA_EXE" help` in sh, `& $env:NULYA_EXE
help` in PowerShell. Below, `nulya` means whichever of the two applies.

## What Nulya is

- The kernel is one durable session file and one step: the model answers, its
  tool calls run in order, one batch of results goes back. That is the loop.
- `shell` is the only builtin tool, permanently. Every other capability —
  including reading and editing files — is an extension, a skill, a system
  prompt or a driver: all outside the kernel, all writable.
- A session's composition — its tools, skills, system prompts and the exact
  extension versions — freezes at `session new` and never changes. Changing it
  means starting a new session.
- The session file only grows. Events are appended, never rewritten; a
  correction is one more event.
- Extension versions are content-addressed and immutable. `activate` moves a
  pointer; nothing is ever overwritten, and going back is `activate` again.

## Finding your way

- `nulya help` — every verb, one line each. A bare `nulya ext`, `nulya session`
  or `nulya skill` prints just that family.
- `nulya src` lists the kernel's own source tree; `nulya src prompt.zig` prints
  one file with its test blocks stripped, `--tests` keeps them. There is no
  filter flag — pipe it: `nulya src | grep session`.
- `nulya ext api` prints the real tool wire-protocol source; `nulya ext api
  manifest` what a manifest may say and who reads it; `nulya ext api examples`
  worked sequences.
- `nulya config show` (add `--json`) — effective profiles, whether each
  credential is usable right now, the model catalog, the standing member list
  and `max_tools`, and the config paths in use. Never a secret.
- `nulya session list` (add `--json`) — every session here: composition, event
  count, cost, fork root, latest verdict.
- `nulya skill list` — the catalog; `nulya skill load <ref>` prints one frozen
  `SKILL.md` in full.

## Configuring

- Four layers merge in order: built-in defaults, system, user
  (`~/.nulya/config.toml`), project (`.nulya/config.toml`). `nulya config show`
  prints the exact paths, so that is where to write.
- The project layer may only narrow: select an already-defined profile, lower
  `max_tools`, set the member list, tighten the environment backend. Defining a profile
  or editing the model catalog is ignored there — a checkout cannot re-route
  requests or redefine what a model id means.
- Two tables describe models. `[[provider.profiles]]` says how to reach a
  provider (kind, base URL, which env var holds the key) and which ids it
  serves; `[[models]]` says what an id is (label, effort dial, context window).
- `[extensions] with = ["<id>[@<version>][:<tool>,…]"]` is the standing member
  list: which packages every session opened here composes, and which of their
  tools take a slot on the model's tool face. Each selected tool costs a slot of
  `max_tools` and carries its name, description and schema in every future
  session's prompt. Name a workspace-local package in the **project** file: a
  member the store cannot resolve makes every `session new` under that layer
  refuse to start. `nulya config show` prints the
  merged list — that is how to see today's composition.
- Config files can hold credentials. Read the key you need, never print a whole
  config into a transcript.
- Per session: `nulya session new --profile <name> --model <id>`. Per step:
  `nulya session step <id> --effort <low|medium|high|…>`.

## Building an extension

Reach for a script first — it needs no compiler and no toolchain:

```
nulya ext init my.helper do_thing             # draft in .nulya/extensions/my.helper
# it scaffolds src/run.sh + src/run.ps1; edit the one(s) for your platforms
nulya ext build .nulya/extensions/my.helper   # prints v-<hash>
nulya ext run my.helper@v-<hash> do_thing --arg name=world
nulya ext activate my.helper v-<hash>
nulya session new --with my.helper            # the tool is on the next session's
                                              # face: the scaffold writes no
                                              # `surface`, which means `auto`
```

There is nothing between the script and the caller, so the script is the whole
tool:

```sh
#!/bin/sh
# stdin: this call's arguments as one JSON object. NULYA_ARG_<key> holds each
# simple argument, NULYA_TOOL the tool's name. Whatever you print is the
# result; exit non-zero to fail the call (stderr becomes the message).
printf 'hello %s\n' "${NULYA_ARG_name:-world}"
```

`extension.json` is the whole declaration; nothing is asked of the binary:

- `runtime.entry` — a `bin/<name>` path means "compile this" (`nulya ext init
  --zig` scaffolds one); anything under `src/` is frozen and run as it is.
  `runtime.interpreter` names what runs it (`sh`, `powershell`, `python`). Both
  may be written per OS — `{"windows": "src/run.ps1", "default": "src/run.sh"}`
  — so one version runs everywhere.
- `contributes.tools[]` — `{name, description, input, surface?, timeout_ms?,
  readonly?, ui?}`. `input` is the JSON Schema the model sees. `surface` answers
  one question — *given that this package is a session member, does this tool
  reach the model?* — with three words: `auto` (**the default**: it reaches the
  model as soon as the package does, so a scaffolded tool works with nothing
  but `--with <id>`); `manual` (membership is not enough, the member must name
  this tool: `--with <id>:<tool>`);
  `internal` (never on the model face; front ends and scripts call it with
  `nulya ext run`). The word is per tool, so one package may use all three: the
  tools it exists FOR are `auto` and arrive with membership, the extras only
  some sessions want are `manual` and are turned on one at a time by whoever
  wants them, and its plumbing is `internal`. That mix is how a package offers
  a working default set without deciding the whole tool face for everyone.
  This manifest is the only source of truth for a tool's shape and placement.
- `contributes.skills[]` — directories holding a `SKILL.md`.
- `contributes.system_prompts[]` — files that join the system blocks of every
  session this package is a member of. Which sessions those are is not the
  package's to say: see membership below. An entry is a bare path, or
  `{"path": "<p>", "position": "early"|"normal"|"late"}` when this text has to
  sit before or after what other packages contribute (`normal` is the default).
  That is its whole scope — the kernel's own block stays first, `session new
  --prompt` text stays after every package's, and the skills catalog stays last.
- `nulya ext api manifest` lists every other field, grouped by who reads it.

A tool receives its arguments, a working directory and a sanitized environment
— never the conversation; it cannot read or append to the session. On the
model's tool face a call is killed at 30s unless the manifest raises
`timeout_ms` (600000 maximum); `nulya ext run` applies no timeout unless given
`--timeout-ms`.

**One axis: membership, with a standing form and a per-session one.**
`activate` is on neither: it says which version `<id>` means, and that is all it
does.

A member is written `<id>[@<version>][:<tool>,<tool>…]`. Being a member puts the
package's skills in the catalog, its system prompts in the system blocks, its
`surface:"auto"` tools on the model face, and all its tools within reach of the
CLI. The part after `:` names the `surface:"manual"` tools this session also puts
on the face; `:none` means a member with nothing on the face at all;
`surface:"internal"` tools are reachable by no selection. A tool the version does
not declare refuses the whole `session new` rather than starting a session
quietly missing it.

Standing form: `[extensions] with` in config. One session: `nulya session new
--with <spec>`, repeatable. A `--with` naming an id the standing list already
brought in wins, version and selection both.

It takes effect from the next session onward; `nulya config show` prints the
standing list, and `nulya ext list` marks an id that is on it `[with]`. `nulya
session new --bare` reads no standing layer and composes from its own flags
alone. Activating a new version mid-session changes what the CLI runs
immediately; the natively exposed form changes only in the next session.

Compile (Zig, a `bin/` entry) when the tool must parse JSON or behave
identically under both shells. In a nulya checkout, `extensions/compact` and
`extensions/handoff` are the worked examples, and `extensions/std` (read /
write / append / edit / grep / glob as one package — build it, then
activate it, compose `std:<tool>,<tool>` with the ones you want — its six tools
are `surface:"manual"` precisely so you assemble that face yourself) is the one to
copy for a tool that returns text: whatever it prints reaches the model
verbatim.

Store and scope:

- `nulya ext build <path>` freezes whatever directory you point at — the draft
  may live anywhere — and files the result under the store by its manifest id.
- **Built versions live in exactly one place per machine**:
  `<NULYA_HOME | ~/.nulya>/store/<id>/versions/<v>/`, whoever built them. A
  workspace holds drafts and, optionally, a `current` pointer of its own under
  `.nulya/extensions/<id>/` — never versions. The workspace pointer wins over
  the store's; with neither, the id is not activated here.
- `--user` means the store's own directory: on `init` / `seed` / `sync` it says
  where the DRAFT goes, on `activate` / `deactivate` which POINTER layer to
  write. Without it, `activate` writes the workspace layer when this workspace
  already has a `<id>/` directory and the store layer when it does not, and
  `deactivate` drops whichever layer is in effect. `build` takes no `--user`:
  there is one destination.
- **The least-effort install: put the source in `.nulya/extensions/<id>/` (or in
  the store for `--user`) and run `nulya ext sync [--user]`.** It builds every
  draft there into the store, one line each, and one bad manifest does not stop
  the rest. Add `--activate` to point `current` at
  what it just built (and at ids that have none) — it never moves a `current`
  that names something else, so going back to an older version survives. `--dry-run` says what it
  would do and writes nothing. Add `--seed` to bring in this binary's own
  bundled drafts (`extensions/{agent,ask,coding,compact,evolution,ground,guide,handoff,plan,std}`
  and any later ones) first — `nulya ext sync --seed --user` on a machine that
  has never seen this checkout writes and builds all of them in one call.
- A build writes nothing when the store already holds that exact version, which
  is what lets a machine with no toolchain use a compiled tool that arrived by
  `nulya ext push` or that another workspace built.
- `nulya ext prune [<id>]` deletes the versions no `current` here names. The
  cost: a session frozen on a deleted version can no longer resume. The way
  back: the draft is still there, and the same source rebuilds to the same
  version id. An id with no pointer at all is left entirely alone.
- `nulya ext list` prints `id / version / layer`: which version the id means and
  which pointer layer said so, plus what that version contributes.
- `nulya ext migrate` is a one-time move for a machine written by an older
  build, when versions still sat beside the drafts in `.nulya/extensions/` and
  `~/.nulya/extensions/`. It carries them into the store and keeps each pointer
  in the layer that already meant it.

## Skills, prompts, modes

- A skill is a directory with a `SKILL.md`: `---`, `name:`, `description:`,
  `---`, then the body. Only name and description enter a session, one catalog
  line each; the body is read on demand with `nulya skill load <ref>`. Put the
  recipes in the body — that is what makes a skill cheap to carry.
- A `system_prompt` is the opposite: every byte joins the system blocks of
  every session that package is a member of, and is paid for on every step.
- A mode is a data extension contributing a system prompt. Out of `[extensions]
  with`, it reaches only the sessions that name it: `nulya session new --with
  <id>`. In `[extensions] with`, every session opened here carries it. In a nulya
  checkout, `extensions/evolution` is one of these.
- A package reachable by a typed `/name` declares `contributes.commands[]`:
  `{name, description, action}`, `action` one key — `{"with": true}` wears the
  package and waits for whatever the person types next; `{"with": "<text>"}`
  wears it AND sends `<text>` as the opening message immediately, the way
  `/compact` behaves without a package having to say so; `{"run": "<tool>"}`
  calls one of this SAME package's own tools; `{"skill": "<ref>"}` sends a
  skill's body as the turn. Typed text after the command name always wins over
  a `with` default — the person's own words, not the package's. `evolution`'s
  `/evolve` writes the string form so a bare `/evolve` reviews evidence right
  away instead of leaving the person to guess what to type.
- An extension with only skills and prompts needs no compiler, and its version
  is a pure content hash — the same id on every machine.
- Text that belongs to ONE session belongs to `nulya session new --prompt <file>`
  instead: the bytes are read at creation and frozen into that session's header,
  so it needs no package, no version and no install. That is where a rendered
  brief goes — today's facts, a persona, a task statement. Freezing it is the
  point: it sits at the front of the cached prefix, paid for once. The bundled
  `ground` package is the worked example — `nulya ext run ground@<v> render`
  writes this workspace's layout, instruction files, environment and git state
  to a file and answers the path, which the driver then passes to `--prompt`.

## Sessions and drivers

- `nulya session new` freezes composition and prints an id. `append` queues a
  user turn and prints the delivery name it deposited under — the name that
  later shows up as `origin` (or one entry of `origins`) on the drained
  `user_text` event, so a caller can match its own turn against the log rather
  than guessing from text. `step` runs to the end of a turn or its budget.
  `events` tails the log. `cancel` asks it to stop at the next step boundary.
  `outcome` records a verdict. `list` projects them all.
- Only `step` writes the session file. `append`, `note` and `cancel` deposit
  into sibling files that the next step boundary drains, so all three work on a
  session another process is currently running.
- `nulya session prune <id> [--force]` is the only verb that REMOVES a session.
  Without the flag it takes only one that recorded nothing and holds nothing —
  a `session new` nobody ever spoke into. `--force` takes its events and any
  queued turns as well, and says how many it took. Neither form removes one that
  is being stepped, that something else is writing into, that still has a
  running background task (it names the task; `nulya task kill <task>` first),
  or that has one which finished on another machine and whose report nobody has
  collected yet (`nulya task status <task>` collects it).
  What goes with it: the session file, its siblings, and `.nulya/scratch/<id>/`.
  What stays: the journal rows (a verdict is evidence about something that
  happened), and any session forked from it with `--parent`.
- `nulya session new --parent <id>:<seq>` forks: a new file continuing an
  existing one. Compaction and handover are both this. Composition is not
  inherited — pass `--with` again if the fork needs it. `--env`
  and `--workspace` ARE inherited, though: leave `--env` off and a fork picks
  up the parent's `environment` and `remote_workspace` verbatim (they are
  creation-time identity, like the model), so a fork of a session running on a
  remote machine does not silently fall back to this host. Name `--env` at all
  (even `local`) to opt out and take a fresh machine from argv instead; naming
  only `--workspace` on an inherited `--env` just picks a different directory
  on the same machine.
- `nulya session new --parent <id>:<seq> --carry` is how a conversation already
  under way changes model, tools or system prompt: it is the same fork, and
  `--carry` copies the parent's events 1..seq into the child, which then runs
  under whatever `--profile` / `--model` / `--with` / `--prompt` this command
  resolves. A session's own identity and composition are frozen for its whole
  file — this is the primitive, and there is no verb that changes them in
  place. Naming no `--profile` / `--model` inherits the parent's. The parent is
  not modified: it stays on disk, steppable, as it was.
  What does not come along: the `reasoning` of every copied turn (it is opaque
  and belongs to the model that produced it) — so expect the child's first step
  to pay for the whole prefix again on a cold prompt cache. It refuses, and
  creates nothing, if `seq` is past the parent's last event, or if the copied
  turns hold images and the child's model has no `[[models]]` entry saying
  `vision = true`. Which models are worth switching between is your call, not
  the kernel's: it holds no compatibility table.
- `nulya session new --env <spec>` chooses WHERE this session's `shell` commands
  run: `local` (the default) or a `remote:…` spec that moves the whole
  workspace there too. It is frozen in the header, so `step` takes no such
  flag and a resume that cannot reach the target fails rather than running
  the commands here instead.
  (There used to be exec-target spellings that moved only the shell while the
  workspace, extensions and every spilled file stayed on this host —
  `wsl[:<distro>]`, and before that a bare `ssh:<destination>`. Both are
  retired now (`ssh:` in 2026-08-30, `wsl` in 2026-09-02): `--env ssh:…` /
  `--env wsl…` are refused, each pointing at its `remote:` replacement below.
  Want a machine reachable over ssh or WSL but only for `shell`, with the
  workspace staying here? Nothing offers that today — the `remote:` family
  moves the workspace along with it.)
- **When the WORKSPACE itself lives on the other machine**, `--env` takes a
  second family of spellings: `remote:wsl`, `remote:wsl:<distro>`,
  `remote:ssh:<destination>`, or the general `remote:exec:<argv…>` — which is
  simply the command that starts a process over there (a container runtime, or
  a nulya you name by path); `remote serve` is appended for you. The named
  forms assume a `nulya` on that machine's PATH. Add
  `--workspace <absolute dir>` to say which directory over there this session
  works in; it is accepted only with a `remote:` spec, and frozen alongside it.
  The far end is a `nulya remote serve` reached through one long-lived channel,
  so there is no per-command connection, cancelling a step really does kill the
  command's process tree over there, and **that machine never needs an API key
  — the model connection stays here**. `remote:` moves `shell`, extension tools,
  and the workspace files the harness itself writes: a spilled tool output lands
  over there at the workspace-relative path its footer names, and a tool like
  `read` or `grep` reads the files `shell` sees rather than this machine's, so
  the two finally answer about the same repository. A tool whose package has not
  been pushed to that machine comes back as a failed call naming
  `nulya ext push` — the session goes on. A pushed version lands in THAT
  machine's own store, which is the only place its version bytes live, so a
  checkout over there cannot stand in front of what you pushed. A background task (`shell` with
  `background: true`, or `nulya task run`) runs over there too: its supervisor,
  its log and its status live in that workspace, so it keeps running when the
  channel closes, and its report still arrives here as the same note
  turn a local one produces — collected by whichever `nulya task` verb or step
  next asks that machine. `nulya task list|status|wait|kill` work on it
  unchanged; a task whose machine will not answer reads `unreachable`, which is
  neither `done` nor `lost` — nothing is known about it, and it is probably
  still running. Two verbs answer the questions a
  driver has before offering a machine to someone: `nulya remote check --env
  <spec>` reports what answered, and `nulya remote ls --env <spec> [<dir>]`
  lists a directory over there exactly, names and kinds.
- **Getting an extension onto that machine** is two commands, and it needs no
  toolchain and no checkout over there:

      nulya ext build extensions/std --target x86_64-linux   # prints v-<hash>
      nulya ext push std@v-<hash> --env remote:ssh:me@box

  `--target <arch>-<os>` compiles the binary for another machine. The two words
  are a closed set — `x86_64` or `aarch64`, then `linux`, `windows` or `macos` —
  and they are exactly what a compiled version's identity already records, so a
  per-target build is simply another version of the same package, sitting beside
  the host one. It is refused for a package with no compiled runtime: those are
  the same version everywhere. `ext push` copies one immutable version into that
  machine's user store; it validates your copy here first, and the far side
  validates what arrived against its own seal before the version becomes visible
  at all, so a broken transfer leaves nothing rather than something half there.
  Pushing a version that is already there does nothing and says so — the version
  id is a content hash, which is the whole of the check. Push does not activate
  anything over there; which machine holds which capability stays a decision
  somebody makes, and the record of it is that store's own contents.

  A remote session composes a compiled package as TWO frozen versions: the one
  this machine reads its manifest, prompts and skills from, and the build for
  that machine's target, which is what actually runs a call. `session new`
  works the second one out by asking the machine what it is and looking for the
  same package bytes built for it — so build for that target BEFORE creating
  the session, or creation stops and tells you the two commands above. Data and
  script packages need none of this: they are the same version everywhere.
- `nulya session note <id> --source <label> [--meta <json>] <text>` queues a
  MACHINE fact rather than a user turn — what a driver, a watcher or a plugin
  observed. It reaches the model at the next step boundary exactly as an append
  does; what differs is that the log does not claim a person said it. `--source`
  is your own short label, carried and never interpreted; `--meta` is one JSON
  value kept verbatim for readers that should not parse the text.
- `nulya session step <id>` prints a line protocol as it runs: transient
  `{"stream":…}` lines interleaved with the same event lines the log receives,
  ending in a `{"stream":"run","event":"done",…}` verdict; a failure is a
  `{"stream":"run","event":"error",…}` line plus a non-zero exit — never a bare
  text line on either stream. `--gate` asks stdin to approve each tool call on
  the same lines, no other flag needed. `--stream` is accepted and does
  nothing, kept for one release for a caller that still passes it.
- A driver is any script that composes those verbs — nothing more. In a nulya
  checkout, `drivers/goal.sh` and `drivers/goal.ps1` are the first: they step
  one step at a time, watch for a handover brief, fork through the bundled
  `compact` tool and carry on in the child, keeping control lines on stdout and
  the stream on stderr.
- Where the bundled `agent` package is in play, a sub-agent is a markdown file:
  `.nulya/agents/<name>.md` (or the same under this machine's nulya home). Its
  front matter is a set of `session new` arguments — `permissions`, `with`,
  `model: <profile>[/<id>]`, `max_steps`, `max_exchanges`, `agents` — and its
  body is the system prompt. Leave `max_steps` out unless you mean it: without
  it a sub-agent runs on the kernel's own runaway guard, which is what the
  bundled personas do, and a small one cuts the investigation off in the middle
  where everything it found is in a session the caller never reads. `runner:` says which harness holds the
  conversation: `nulya` (the default, a session of its own), `codex` (a Codex
  thread over `codex app-server`), `claude` (a Claude Code session over
  `claude -p`'s stream-json stdio) or `pi` (a pi session over `pi --mode rpc`).
  An external runner needs its own harness installed and on PATH, has its own
  catalogue, and so takes `runner_model:` — an opaque string in that harness's
  words — where a nulya one takes `model:`; the fields for the other harness
  are dropped with a warning, and an unknown `runner:` costs the whole
  definition.
  The file is read ONCE, when a delegation opens: everything it asked for is
  frozen into that delegation's record. So editing it changes the next
  delegation and never one already under way, and deleting it strands nothing —
  a conversation that exists keeps its own persona, ceiling and budget.
- `permissions:` is how much a delegation may do, in three words, and every
  runner translates it into its own harness's terms:

  | | `readonly` | `default` (the unwritten one) | `unsafe` |
  |---|---|---|---|
  | `nulya` | gated: only tools declaring `readonly` run | no gate | no gate |
  | `codex` | `read-only` sandbox, confirmed | `workspace-write` | `danger-full-access` |
  | `claude` | read-only tools + `dontAsk`, confirmed | `acceptEdits` | `bypassPermissions` |
  | `pi` | `--tools read,grep,find,ls` | everything built in | everything built in |

  Only `readonly` is a CEILING: a runner that cannot hold its harness to
  reading refuses the delegation rather than run it wider than it asked for.
  `unsafe` is reached only because a definition or an `agent` call wrote the
  word — never inherited from a parent, a front end's mode, or the
  environment — and that call passes the parent session's own approval gate, so
  a person may see it and say no. A word that is not one of the three, or the
  older `readonly: true` this field replaced, costs the whole definition:
  reading a persona that asked to be held to reading as an ordinary one is
  exactly what the field exists to prevent. On the nulya runner `default` and
  `unsafe` behave the same today (there is no gate between them — real
  isolation is a sandbox, not a guess at command strings); the difference is
  frozen into the delegation's record either way.
- **Standing widenings belong in each harness's own configuration, not here.**
  `permissions` says what a delegation may reach for; how a harness answers the
  things it is asked to approve is that harness's own setting, and it applies
  to every agent that runs there. In Claude Code that is `permissions.allow`
  rules in `.claude/settings.json` (or `settings.local.json` for one machine);
  in Codex it is `~/.codex/config.toml`'s sandbox and approval keys; in nulya's
  own TUI it is `tui.toml`'s `[approvals]` tables plus `/mode`. Reach for those
  when the same command is being approved over and over — and for `unsafe` only
  when a single delegation genuinely needs the guard rails off.
- `runner: ext:<id>` holds the conversation on a harness NOBODY here has heard
  of. That extension declares one `internal` tool named exactly `agent_runner`,
  and answers two operations (its arguments arrive as `NULYA_ARG_<key>`, and as
  JSON on stdin, like every other tool):

  | | `op=open` | `op=round` |
  |---|---|---|
  | in | `delegation` `persona` `permissions` `model?` | those, plus `remote` `message_file` `interrupt` |
  | out | `{"remote":"<handle>"}` | `{"text":"<this round's answer>"}` |
  | exit ≠ 0 | refuses the whole delegation; stderr says why | this round failed; the message waits for the next one |

  `persona` and `message_file` are PATHS (a task is as long as it needs to be).
  `interrupt` is a marker file: while a turn is in flight, watch it — if it
  appears, delete it, stop the turn however the harness allows, and answer
  `{"text":"","interrupted":true}`. `permissions` is one of `readonly`,
  `default`, `unsafe`: refuse `op=open` when it is `readonly` and the harness
  cannot be held to reading — that refusal is the ceiling — and refuse a word
  you do not recognise, because reading a level you never understood as your
  own default is how a ceiling gets quietly widened.
  Everything else — the delegation's identity and journal, its message queue,
  the exchange budget, the report reaching the parent — is the `agent` package's
  and needs nothing from you. Install it like any extension (`nulya ext build
  <path>` then `nulya ext activate <id> <version>`); the version in effect when
  a delegation opens is frozen into it, so activating a newer one changes what
  the next delegation runs on, never a conversation already under way.
- Handover is the model's half of that: a tool that writes a brief and stops,
  leaving the driver to decide whether to act on it. The shape is the same in
  any workspace even where those particular files are not.
- Write your own driver in whatever runs here. Where Python is available it is
  the simplest: one file for every platform, `subprocess` for the verbs, `json`
  for the event lines (the bundled pair is sh + PowerShell only because a nulya
  checkout assumes nothing beyond its own binary). The skeleton is always:

  ```python
  import json, os, subprocess
  N = os.environ.get("NULYA_EXE", "nulya")
  run = lambda *a: subprocess.run([N, *a], capture_output=True, text=True, check=True).stdout
  sid = run("session", "new").strip()
  run("session", "append", sid, "the goal, and how you want it worked")
  while True:
      events = [json.loads(l) for l in run("session", "step", sid, "--max-steps", "1").splitlines() if l]
      last = [e for e in events if e.get("kind") == "assistant"]
      if last and not last[-1].get("calls"): break     # end of turn: decide, append, or stop
  ```

## Persisting state across calls

A tool is a fresh process every call — nothing survives between them except
what you write to disk. If that state needs the same discipline the three
kernel journals use (one complete JSON line per event, safe under concurrent
writers, a crash-torn tail repaired rather than glued onto), reach for
A tool that wants per-session state keys it by `NULYA_SESSION_ID` — the
session's identity, set for everything a step runs, and true on whichever
machine the tool runs on. `NULYA_SESSION` is a different thing: the path of the
session's file, which exists only where the harness runs, so reach for it only
when you genuinely need that file. Use
`"$NULYA_EXE" journal append/read` instead of writing your own file lock:

```sh
# append: the record comes from STDIN, not argv — one line, valid JSON, or
# nothing is written at all.
echo '{"seen":"'"$NULYA_TOOL"'"}' | "$NULYA_EXE" journal append .nulya/scratch/my.log.jsonl

# read: every complete line back; a file that was never written to is empty
# output, exit 0 — not an error to special-case.
"$NULYA_EXE" journal read .nulya/scratch/my.log.jsonl
```

Concurrent callers are safe: `append` holds that file's own lease for the
length of one write, so two calls racing the same path serialize instead of
tearing a line. There is no `put`/`peek`/`ack` — that stronger, consumed-once
contract is what `extensions/agent`'s own mailbox needed and built for itself;
reach for `journal` when a plain fact log is enough.

## Evidence

- `.nulya/tool-usage.jsonl` — one line per tool call: stable id, ok, duration.
  Nothing reads it to decide anything; it is evidence for a person or a later
  pass. A tool with built versions and zero rows is manufactured-but-never-
  invoked, which is the strongest negative evidence there is.
- `.nulya/session-outcomes.jsonl` — `nulya session outcome <id>
  success|partial|failure [--note <text>]`. No line means unknown, which is not
  failure; for one session the last line wins. A verdict written from inside a
  session is recorded as that session's own claim.
- `nulya session list --json` joins composition, cost and the latest verdict,
  and gives each session the `root` of its fork chain — sessions sharing a root
  are one task, however many files it took.

## Etiquette

- Tool output is clipped and budgeted; anything oversized spills to
  `.nulya/scratch/<session>/` and you get a pointer. Aggregate rather than dump:
  `nulya session list --json | head -c 4000`, `grep -c`, `sort | uniq -c`.
- Never `cat` a whole session file, and never edit one. `.nulya/sessions/*.jsonl`
  and the journals beside them are append-only facts.
- Keep working files under `.nulya/` unless the task is about the user's tree.
- Run `nulya ext list` before building something: the capability may exist
  already, perhaps without a pointer.
