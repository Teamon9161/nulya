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
  but `--with`); `manual` (membership is not enough, someone must name this
  tool — and it is the ONLY surface `--pin` / `pinned_native_tools` accepts);
  `internal` (never on the model face; front ends and scripts call it with
  `nulya ext run`). The word is per tool, so one package may use all three: the
  tools it exists FOR are `auto` and arrive with membership, the extras only
  some sessions want are `manual` and are turned on one at a time by whoever
  wants them, and its plumbing is `internal`. That mix is how a package offers
  a working default set without deciding the whole tool face for everyone.
  This manifest is the only source of truth for a tool's shape and placement.
  A `manual` tool may also say `recommended: false`: `manual` otherwise means
  on-once-installed and closable one tool at a time (the difference from `auto`
  is the switch, not the default), so this is how a package marks an extra that
  should stay off until somebody asks for it. It is advice to whoever installs
  the package — `nulya ext activate` names the recommended pins and writes no
  config, and a front end's own switch writes exactly those.
- `contributes.skills[]` — directories holding a `SKILL.md`.
- `contributes.system_prompts[]` — files that join the system blocks of every
  session this package is a member of. Which sessions those are is mostly not
  the package's to say: see the two axes below. An entry is a bare path, or
  `{"path": "<p>", "position": "early"|"normal"|"late"}` when this text has to
  sit before or after what other packages contribute (`normal` is the default).
  That is its whole scope — the kernel's own block stays first, `session new
  --prompt` text stays after every package's, and the skills catalog stays last.
- `apply` — top level, not under `contributes`, because it is not a
  contribution: it is what the author thinks INSTALLING this package should
  mean. `manual` (the default, and every manifest that omits it) means the
  package joins the sessions that name it. `auto` means that while it has a
  `current`, it is a member of every new session on this machine — what a mode
  wants. It is a default and not a ceiling: `[extensions] with` still adds a
  `manual` package, and `nulya ext deactivate <id>` still stops an `auto` one.
- `nulya ext api manifest` lists every other field, grouped by who reads it.

A tool receives its arguments, a working directory and a sanitized environment
— never the conversation; it cannot read or append to the session. On the
model's tool face a call is killed at 30s unless the manifest raises
`timeout_ms` (600000 maximum); `nulya ext run` applies no timeout unless given
`--timeout-ms`.

**Two independent axes, each with a standing form and a per-session one.**
`activate` is on neither: it says which version `<id>` means, and that is all
it does — except that for a package declaring `apply: "auto"`, having a
`current` IS the standing membership, so `activate` says one line about that
and points at `nulya ext deactivate`.

- MEMBERSHIP — the package is in this session: its skills in the catalog, its
  system prompts in the system blocks, its `surface:"auto"` tools on the model
  face, its tools callable through the CLI. However a package became a member,
  it contributes all of that: there is no lesser kind of membership.
  Standing: `[extensions] with` in config, or the package's own `apply: "auto"`.
  One session: `nulya session new --with <id>[@<version>]`. A `--with` naming an
  id that a standing layer already brought in wins, version and all.
- TOOL FACE — a tool takes a native slot the model can call. For
  `surface:"manual"` tools, standing form is `[registry] pinned_native_tools`;
  one-session form is `nulya session new --pin ext:<id>/<tool>`. A pin brings
  its own package in — as a full member, so that package's `surface:"auto"`
  tools arrive with it — so a pin alone is enough. For `surface:"auto"` tools —
  the default — the tool face follows the membership axis instead: compose the
  package and those tools appear, with no pin and nothing else to write.
  `surface:"internal"` tools never join this face.

Both take effect from the next session onward; `nulya config show` prints the
two standing config lists, and `nulya ext list` marks an `apply: "auto"` package
`standing`. `nulya session new --bare` reads none of the standing layers and
composes from its own flags alone. Activating a new version mid-session changes
what the CLI runs immediately; the natively exposed form changes only in the
next session.

Compile (Zig, a `bin/` entry) when the tool must parse JSON or behave
identically under both shells. In a nulya checkout, `extensions/compact` and
`extensions/handoff` are the worked examples, and `extensions/std` (read /
write / append / edit / grep / glob as one package — build it `--user`,
activate it, pin `ext:std/<tool>` for the ones you want — its six tools are
`surface:"manual"` precisely so you assemble that face yourself) is the one to
copy for a tool that returns text: whatever it prints reaches the model
verbatim.

Store and scope:

- `nulya ext build <path>` freezes whatever directory you point at — the draft
  may live anywhere — and files the result under the store by its manifest id.
- `--user` on `init` / `build` / `sync` / `prune` / `activate` /
  `deactivate` uses the user store, which every workspace on this machine sees.
  **A tool you want everywhere belongs there.**
- **The least-effort install: put the source in `<root>/<id>/` and run `nulya ext
  sync [--user]`.** It builds every draft in that root, one line each, and one
  bad manifest does not stop the rest. Add `--activate` to point `current` at
  what it just built (and at ids that have none) — it never moves a `current`
  that names something else, so going back to an older version survives. `--dry-run` says what it
  would do and writes nothing. Add `--seed` to bring in this binary's own
  bundled drafts (`extensions/{agent,ask,compact,evolution,guide,handoff,plan,std}`
  and any later ones) first — `nulya ext sync --seed --user` on a machine that
  has never seen this checkout writes and builds all of them in one call.
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
- A `system_prompt` is the opposite: every byte joins the system blocks of
  every session that package is a member of, and is paid for on every step.
- A mode is a data extension contributing a system prompt. Left at the default
  `apply: "manual"` and out of `[extensions] with`, it reaches only the sessions
  that name it: `nulya session new --with <id>`. Written with `"apply": "auto"`,
  activating it IS installing it — every new session carries it until `nulya ext
  deactivate <id>`. In a nulya checkout, `extensions/evolution` is one of the
  first kind.
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
- Where the bundled `agent` package is in play, a sub-agent is a markdown file:
  `.nulya/agents/<name>.md` (or the same under this machine's nulya home). Its
  front matter is a set of `session new` arguments — `readonly`, `pins`,
  `model: <profile>[/<id>]`, `max_steps`, `max_exchanges`, `agents` — and its
  body is the system prompt. `runner:` says which harness holds the
  conversation: `nulya` (the default, a session of its own) or `codex` (a Codex
  thread over `codex app-server`). An external runner has its own catalogue, so
  it takes `runner_model:` — an opaque string in that harness's words — where a
  nulya one takes `model:`; the fields for the other harness are dropped with a
  warning, and an unknown `runner:` costs the whole definition.
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
