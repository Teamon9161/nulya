---
name: evolve
description: Recipes and the report template for a slow-loop pass — how to read Nulya's evidence (sessions, tool usage, outcomes, prior reports) with aggregate shell commands, and the exact five-section report to write.
---

# Running an evolution pass

The identity, the procedure and the hard rules are already in your system
prompt. This is the reference: what to type, and what to write.

## 1. Evidence recipes

Two dialects; use the one matching `shell_dialect`. Every command is read-only
and aggregates — never `cat` a whole ledger, the output budget will truncate it
and you will have learned less than a count would have told you.

### bash

```bash
# The window: every session, newest first, with cost and verdict.
nulya session list --json | head -c 4000

# Your own memory: the most recent report.
ls -1 .nulya/evolution/ 2>/dev/null | tail -3
tail -c 4000 "$(ls -1 .nulya/evolution/*.md 2>/dev/null | tail -1)"

# What recurs: the shape of shell commands across every session.
grep -ho '"command":"[^"]*"' .nulya/sessions/*.jsonl |
  sed 's/"command":"//; s/"$//' | awk '{print $1, $2}' | sort | uniq -c | sort -rn | head -20

# What fails: failed tool results, and which session they are in.
grep -l '"ok":false' .nulya/sessions/*.jsonl
grep -ho '"ok":false,"output":"[^"]\{0,120\}' .nulya/sessions/*.jsonl | sort | uniq -c | sort -rn | head -20

# Tool usage: totals and failures per stable id.
sort .nulya/tool-usage.jsonl | uniq -c | sort -rn | head -20

# Outcomes, and the sessions that have none (unknown is not failure).
# A line with "source":"agent" was written from a session's own shell — and one
# whose "by" equals its "session" is a self-grade: a claim, not ground truth.
cat .nulya/session-outcomes.jsonl 2>/dev/null

# Capability notes: what got built mid-conversation.
grep -ho '"kind":"capability_note","id":"[^"]*","version":"[^"]*"' .nulya/sessions/*.jsonl | sort -u

# What exists but is never invoked.
nulya ext list
```

### powershell

```powershell
# The window.
nulya session list --json | Select-Object -First 1

# Your own memory.
Get-ChildItem .nulya\evolution\*.md -EA SilentlyContinue | Select-Object -Last 1 | Get-Content -Tail 60

# What recurs.
Select-String -Path .nulya\sessions\*.jsonl -Pattern '"command":"([^"]*)"' -AllMatches |
  ForEach-Object { $_.Matches } | ForEach-Object { ($_.Groups[1].Value -split ' ')[0..1] -join ' ' } |
  Group-Object | Sort-Object Count -Descending | Select-Object Count, Name -First 20

# What fails.
Select-String -Path .nulya\sessions\*.jsonl -Pattern '"ok":false' -List | Select-Object Filename
Select-String -Path .nulya\sessions\*.jsonl -Pattern '"ok":false,"output":"(.{0,120})' -AllMatches |
  ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
  Group-Object | Sort-Object Count -Descending | Select-Object Count, Name -First 20

# Tool usage.
Get-Content .nulya\tool-usage.jsonl | Group-Object | Sort-Object Count -Descending | Select-Object Count, Name -First 20

# Outcomes. ("source":"agent" is a claim; "by" == "session" is a self-grade.)
Get-Content .nulya\session-outcomes.jsonl -EA SilentlyContinue

# What exists but is never invoked.
nulya ext list
```

### Joining the two

An extension with built versions and **zero lines** in `tool-usage.jsonl` is
`manufactured but never invoked` — negative evidence, and the strongest kind you
have. A skill in the catalog that no session ever loaded (`nulya skill load`
never appears in any `"command"`) is the same fact for knowledge.

**Sessions sharing a `root` are one episode.** Compaction and handoff fork a
session, so one task is often several files; `session list --json` gives each
session a `root` (the file its chain starts at) and an `episode_usage` (the whole
chain's cost). **Judge the episode, cite the root**: "3 sessions" that are one
forked task is one piece of evidence, not three, and the cost of that task is
`episode_usage`, not the last file's `usage`. A verdict, though, stays recorded
against the single session id it was given — join it to the episode yourself.

**Who wrote a verdict matters.** `"source":"agent"` means the line came from a
session's own shell, and `"by" == "session"` means that session graded itself.
Treat those as claims: corroborate with what the ledger shows (did the work land?
did a later session redo it?) before resting a proposal on one.

### Tool usage → promotion

`tool-usage.jsonl` never promotes anything by itself — the kernel does not read
it. A tool reaches the model's tool face only because someone composed its
package as a **member**, and that someone can be you (as a proposal, in the
report).

Read the rows first — the `sort | uniq -c` line above is the whole input.
Composing a package is worth proposing when one stable id is invoked **often, across several
sessions, and mostly with `"ok":true`**; a handful of calls inside one session is
a habit of that session, not a capability the tool face should carry. Two rows
that argue against it: many `"ok":false` (fix the tool, do not compose it) and
zero rows for an extension that exists (`manufactured but never invoked`).

The proposal is one line in the project config:

```bash
cat .nulya/config.toml 2>/dev/null      # read what is already composed
# then make the file contain (with an editing tool if you have one, else `shell`):
#   [extensions]
#   with = ["my.helper:do_thing"]
```

```powershell
Get-Content .nulya\config.toml -EA SilentlyContinue
# same edit; the file is TOML, one [extensions] table, one list
```

It takes effect at the **next** `session new` (composition freezes at session
start), and it is not free: each selected tool costs one `max_tools` slot and
carries the tool's name, description and JSON schema in **every** future
session's prompt prefix. Say both in the report — the count of usage rows you
are resting on, and the cost you are asking every future session to pay. That
price is exactly why the tool face is not filled automatically. Retiring is
symmetric: delete the entry, and the next session no longer carries it (the
extension itself stays, still callable through `nulya ext run`).

## 2. Leaving something behind — smallest form first

The order is: **notes / skill entry → script extension → compose an existing
tool onto the face → compiled tool → driver**. Go one step down only when the step above
provably cannot do it.

A script extension draft, which needs no toolchain:

```bash
nulya ext init my.helper do_thing               # draft in .nulya/extensions/my.helper
# edit src/run.sh (and src/run.ps1 for Windows): arguments arrive as NULYA_ARG_<key>
nulya ext build .nulya/extensions/my.helper     # prints v-<hash>
nulya ext activate my.helper v-<hash>           # only if the report says why
```

The script contract (what `ext init` scaffolds): stdin holds the call's
arguments as one JSON object, each simple argument is also `NULYA_ARG_<key>`,
whatever the script prints is the result, and a non-zero exit fails the call:

```sh
#!/bin/sh
printf 'hello %s\n' "${NULYA_ARG_name:-world}"
```

`nulya ext api` prints the wire contract if you need the exact shape.

For a knowledge proposal there is no extension at all: edit the relevant
`SKILL.md` or notes file, and record in the report which file and why.

## 3. The report

Write `.nulya/evolution/<YYYYMMDD-HHMM>-<session-id>.md`. All five sections are
always present; an empty one says `none`.

```markdown
# Evolution pass <YYYY-MM-DD HH:MM>

## Window
Previous report: <path or "none — first pass">.
Sessions examined: <n> (<id>, <id>, …), of which <n> carry a verdict.
Evidence: .nulya/sessions/, tool-usage.jsonl, session-outcomes.jsonl.

## Prior proposals
- <id@version or title> — adopted | unused (deactivated) | superseded (current moved on; left alone) | falsified: <one line of evidence>.
(or: none — first pass)

## Null results
- **<the thing that looked like a pattern>** — why it is not one, citing session
  ids. **Would change my mind:** <the concrete observation that would>.

## Proposals
- **<name>** (kind: notes | skill entry | script tool | member | tool v2 | driver)
  - Evidence: <session ids — at least three; for a member, the usage-row count too>.
  - Smallest form: <what exactly was written or scaffolded; for an extension, its `<id>@<version>` from `ext build`; for a member, the spec and the per-session cost>.
  - Activated: yes/no — <why>.
  - Falsifier: retire if <N sessions with no invocation | no outcome improvement by …>.
(or: none this pass)

## Nothing else found
<What you looked at that produced neither a null result nor a proposal, so the
next pass does not re-walk it.>
```

## 4. Checklist before you stop

- [ ] Read the previous report and settled every one of its proposals.
- [ ] Every claim cites session ids; no proposal rests on fewer than three.
- [ ] At most two proposals; each has a falsifier.
- [ ] At least as much thought in `## Null results` as in `## Proposals`.
- [ ] All five sections present, empty ones say `none`.
- [ ] Nothing written outside `.nulya/evolution/` except one minimal-form change.
- [ ] Any new member cites its usage rows and states the per-session cost.
- [ ] No journal and no session file touched.
- [ ] Final message ≤ 5 lines.
