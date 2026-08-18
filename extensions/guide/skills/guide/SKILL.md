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
- `shell` and `edit` are the only builtin tools, permanently. Every other
  capability is an extension, a skill, a system prompt or a driver — all of them
  outside the kernel, all of them writable.
- A session's composition — its tools, skills, system prompts and the exact
  extension versions — freezes at `session new` and never changes. Changing it
  means starting a new session.
- The session file only grows. Events are appended, never rewritten; a
  correction is one more event.
- Extension versions are content-addressed and immutable. `activate` and
  `rollback` move a pointer; nothing is ever overwritten.

## Finding your way

- `nulya help` — every verb, one line each. A bare `nulya ext`, `nulya session`
  or `nulya skill` prints just that family.
- `nulya src` lists the kernel's own source tree; `nulya src prompt.zig` prints
  one file with its test blocks stripped, `--tests` keeps them. There is no
  filter flag — pipe it: `nulya src | grep session`.
- `nulya ext api` prints the real tool wire-protocol source; `nulya ext api
  permissions` the authority model; `nulya ext api examples` worked sequences.
- `nulya config show` (add `--json`) — effective profiles, whether each
  credential is usable right now, the model catalog, the pinned tools and
  `max_tools`, and the config paths in use. Never a secret.
- `nulya session list` (add `--json`) — every session here: composition, event
  count, cost, fork root, latest verdict.
- `nulya skill list` — the catalog; `nulya skill load <ref>` prints one frozen
  `SKILL.md` in full.

## Configuring

- Four layers merge in order: built-in defaults, system, user
  (`~/.nulya/config.toml`), project (`.nulya/config.toml`). `nulya config show`
  prints the exact paths, so that is where to write.
- The project layer may only narrow: select an already-defined profile, lower
  `max_tools`, set pins, tighten the environment backend. Defining a profile,
  editing the model catalog or adding extension paths is ignored there — a
  checkout cannot re-route requests or redefine what a model id means.
- Two tables describe models. `[[provider.profiles]]` says how to reach a
  provider (kind, base URL, which env var holds the key) and which ids it
  serves; `[[models]]` says what an id is (label, effort dial, context window).
- `[registry] pinned_native_tools = ["ext:<id>/<tool>"]` is the standing list of
  extension tools on the model's tool face. Each one costs a slot of
  `max_tools` and carries its name, description and schema in every future
  session's prompt. Pin a workspace-local tool in the **project** file: a pin
  that no store root can resolve makes every `session new` under that layer
  refuse to start, so a user-layer pin for a tool built in one workspace breaks
  every other workspace on the machine. `nulya config show` prints the merged
  list — that is how to see today's pins.
- Config files can hold credentials. Read the key you need, never print a whole
  config into a transcript.
- Per session: `nulya session new --profile <name> --model <id>`. Per step:
  `nulya session step <id> --effort <low|medium|high|…>`.

## Building an extension

Reach for a script first — it needs no compiler and no toolchain:

```
nulya ext init --script my.helper do_thing    # draft in .nulya/extensions/my.helper
# edit src/run.sh (or src/run.ps1)
nulya ext build .nulya/extensions/my.helper   # prints v-<hash>
nulya ext run my.helper@v-<hash> do_thing --arg name=world
nulya ext activate my.helper v-<hash>
```

`extension.json` is the whole declaration; nothing is asked of the binary:

- `runtime.entry` — a `bin/<name>` path means "compile this"; anything else
  (`src/run.sh`) is frozen and run as it is. `runtime.interpreter` names what
  runs it (`sh`, `powershell`, `python`).
- `contributes.tools[]` — `{name, description, input, timeout_ms?}`. `input` is
  the JSON Schema the model sees. This manifest is the only source of truth for
  a tool's shape.
- `contributes.skills[]` — directories holding a `SKILL.md`.
- `contributes.system_prompts[]` — files that join every session's system blocks
  once this version is active.
- `permissions` — declarative today. `nulya ext api permissions` says exactly
  what is and is not enforced.

The wire contract is one JSON-RPC request in on stdin, one response out on
stdout, then exit. `nulya ext api` prints the exact source. A tool receives its
arguments, a working directory and a sanitized environment — never the
conversation; it cannot read or append to the session. It is killed at 30s
unless the manifest raises `timeout_ms` (600000 maximum).

**Getting a tool onto the model's tool face is a separate decision from
versions.** Only a pin does it — `[registry] pinned_native_tools` or `nulya
session new --pin ext:<id>/<tool>` — and only from the next session onward.
`--with` composes an extension into a session (its skills, its system prompts,
its tools callable through the CLI) but grants no native slot. Activating a new
version mid-session changes what the CLI runs immediately; the natively exposed
form changes only in the next session.

Compile (Zig, a `bin/` entry) when the tool must parse JSON or behave
identically under both shells. In a nulya checkout, `extensions/compact` and
`extensions/handoff` are the worked examples, and `extensions/std` (read /
write / append / grep / glob as one package — build it `--user`, activate it,
pin `ext:std/<tool>` for the ones you want) is the one to copy for a tool that
returns text: a string `result` reaches the model verbatim.

Store and scope:

- `nulya ext build <path>` freezes whatever directory you point at — the draft
  may live anywhere — and files the result under the store by its manifest id.
- `--user` on `init` / `build` / `sync` / `prune` / `activate` / `rollback` /
  `deactivate` uses the user store, which every workspace on this machine sees.
  **A tool you want everywhere belongs there.**
- **The least-effort install: put the source in `<root>/<id>/` and run `nulya ext
  sync [--user]`.** It builds every draft in that root, one line each, and one
  bad manifest does not stop the rest. Add `--activate` to point `current` at
  what it just built (and at ids that have none) — it never moves a `current`
  that names something else, so a rollback survives. `--dry-run` says what it
  would do and writes nothing.
- A build takes a copy instead of compiling when another root already holds that
  exact version, which is what lets a machine with no toolchain install a
  compiled tool the user store already carries.
- `nulya ext prune [--user] [<id>]` deletes the versions `current` does not
  name. The cost: a session frozen on a deleted version can no longer resume.
  The way back: the draft is still there, and the same source rebuilds to the
  same version id. An id with no `current` is left entirely alone.
- Search order is workspace `.nulya/extensions`, then the user store, then
  configured paths. The first root with an active copy of an id wins; `nulya ext
  list` marks the losers `(shadowed)` and shows what each version contributes.
- A workspace store that arrived with a checkout takes part in no session until
  someone runs `nulya ext trust` once on this machine. Read it first — `ext
  list` and `ext inspect` are never gated, which is the point.

## Skills, prompts, modes

- A skill is a directory with a `SKILL.md`: `---`, `name:`, `description:`,
  `---`, then the body. Only name and description enter a session, one catalog
  line each; the body is read on demand with `nulya skill load <ref>`. Put the
  recipes in the body — that is what makes a skill cheap to carry.
- A `system_prompt` is the opposite: every byte joins every session's system
  blocks for as long as that version is active. Activate one deliberately.
- A mode is a data extension contributing a system prompt that is built but
  deliberately **not** activated, then brought into one session with `nulya
  session new --with <id>@<version>`. In a nulya checkout,
  `extensions/evolution` is one.
- An extension with only skills and prompts needs no compiler, and its version
  is a pure content hash — the same id on every machine.

## Sessions and drivers

- `nulya session new` freezes composition and prints an id. `append` queues a
  user turn. `step` runs to the end of a turn or its budget. `events` tails the
  log. `cancel` asks it to stop at the next step boundary. `outcome` records a
  verdict. `list` projects them all.
- Only `step` writes the session file. `append` and `cancel` deposit into
  sibling files that the next step boundary drains, so both work on a session
  another process is currently running.
- `nulya session new --parent <id>:<seq>` forks: a new file continuing an
  existing one. Compaction and handover are both this. Composition is not
  inherited — pass `--with` and `--pin` again if the fork needs them.
- `nulya session step <id> --stream` adds a line protocol: transient
  `{"stream":…}` lines while it runs, interleaved with the same event lines the
  log receives. Behaviour is otherwise identical to a plain step.
- A driver is any script that composes those verbs — nothing more. In a nulya
  checkout, `drivers/goal.sh` and `drivers/goal.ps1` are the first: they step
  one step at a time, watch for a handover brief, fork through the bundled
  `compact` tool and carry on in the child, keeping control lines on stdout and
  the stream on stderr.
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
  already, possibly shadowed.
