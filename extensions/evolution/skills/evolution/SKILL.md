---
name: evolution
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

# Outcomes.
Get-Content .nulya\session-outcomes.jsonl -EA SilentlyContinue

# What exists but is never invoked.
nulya ext list
```

### Joining the two

An extension with built versions and **zero lines** in `tool-usage.jsonl` is
`manufactured but never invoked` — negative evidence, and the strongest kind you
have. A skill in the catalog that no session ever loaded (`nulya skill load`
never appears in any `"command"`) is the same fact for knowledge.

## 2. Leaving something behind — smallest form first

The order is: **notes / skill entry → script extension → compiled tool →
driver**. Go one step down only when the step above provably cannot do it.

A script extension draft, which needs no toolchain:

```bash
nulya ext init --script my.helper do_thing      # draft in .nulya/extensions/my.helper
# edit src/run.sh (or run.ps1): read one JSON-RPC request on stdin, write one response
nulya ext build .nulya/extensions/my.helper     # prints v-<hash>
nulya ext activate my.helper v-<hash>           # only if the report says why
```

The script contract is one request in, one response out:

```sh
#!/bin/sh
request=$(cat)                      # {"jsonrpc":"2.0","id":1,"method":"tool/call","params":{...}}
id=$(printf '%s' "$request" | sed 's/.*"id":\([0-9]*\).*/\1/')
printf '{"jsonrpc":"2.0","id":%s,"result":{"text":"…"}}' "$id"
```

`nulya ext api` prints the real protocol source if you need the exact shape.

For a knowledge proposal there is no extension at all: `edit` the relevant
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
- **<name>** (kind: notes | skill entry | script tool | tool v2 | driver)
  - Evidence: <session ids — at least three>.
  - Smallest form: <what exactly was written or scaffolded; for an extension, its `<id>@<version>` from `ext build`>.
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
- [ ] Nothing promoted, nothing pinned, no journal or session file touched.
- [ ] Final message ≤ 5 lines.
