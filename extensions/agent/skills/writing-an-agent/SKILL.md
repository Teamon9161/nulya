---
name: writing-an-agent
description: How to write an agent definition for delegation — where the file goes, every front matter field it accepts, and what each one does. Read this before creating or editing a file under .nulya/agents/ or ~/.nulya/agents/.
---

# Writing an agent definition

A definition is a markdown file. Its front matter is a set of `session new`
arguments; its body is the sub-agent's system prompt. `agent{name: "<stem>"}`
delegates to it.

## Where it goes

| Path | Layer |
|---|---|
| `.nulya/agents/<name>.md` | this workspace — wins a name collision |
| `<NULYA_HOME or ~/.nulya>/agents/<name>.md` | this machine |
| shipped inside this package | `explore`, `general`, `plan`, `orchestrator` — the floor nobody installs |

Flat, `.md` only, one definition per file. The loser of a name collision is
never dropped, only marked `shadowed`; `nulya ext run agent list` shows every
definition, its layer and what it resolved to.

`.nulya/agents/` is relative to **the workspace this session was opened in**,
which is not necessarily the cwd your shell calls are running in. Write the file
with an absolute path, or with the same cwd the session reports as its working
directory; a definition under any other directory is invisible to `agent{name}`
even though a `list` run from that directory will happily show it. Definitions
are read fresh every delegation, so there is nothing to reload once it is in the
right place.

## Front matter

The dialect is deliberately small: `key: value`, `key: [a, b]`, and the `- item`
block form. No nesting.

| Key | Value |
|---|---|
| `name` | the agent's name. Defaults to the file stem, so it is usually redundant. |
| `description` | one line, shown in the catalogue the `agent` tool prints when a name does not exist. Write it for the model that will pick between agents. |
| `permissions` | `readonly`, `default` (assumed) or `unsafe` — the ceiling every runner translates into its own harness's terms and refuses rather than exceed. A policy, not a sandbox. The older `readonly: true` is refused outright, never read as `default`. |
| `runner` | which harness holds this conversation: `nulya` (assumed — a session of its own, driven by a background task), `codex`, `claude`, `pi`, or `ext:<id>` for a harness some other extension knows how to talk to. An unknown word costs the whole definition rather than a warning: a persona quietly running on something other than what it asked for is worse than one that is not there. |
| `model` | for the `nulya` runner. `<profile>`, `<profile>/<model-id>`, or `@<rung>`. |
| `runner_model` | for every OTHER runner: a model name in that harness's own vocabulary, passed through untouched. Write one vocabulary or the other, decided by your `runner:`; the wrong one is dropped with a warning. |
| `max_steps` | positive whole number: how many steps one delegation turn may take. |
| `max_exchanges` | positive whole number: how many turns this agent may exchange. |
| `with` | list of members for the sub-session, `<id>[@<version>][:<tool>,…]` each. |
| `agents` | list of agent names this agent may itself delegate to. Absent means it cannot delegate at all. |

Anything else is ignored. A field written but unreadable is dropped with a
warning and the definition still loads — except `permissions` and `runner`,
where a wrong word fails the whole definition.

## `model: @<rung>` — ask for a role, not a model

A rung is a named model choice staffed by a profile
(`[provider.profiles.roles]` in config, `nulya config show`). `model: @explore`
asks for whatever the profile this delegation inherits calls `explore`, so
changing the model a conversation runs on changes what its delegations run on,
in one move. A profile that staffs no such rung falls back to plain inheritance
— that is not an error.

**A definition that writes no `model:` at all rides a rung of its own name.**
So a file named `scout.md` asks for `@scout` without saying so. A `model:` that
is written but unreadable inherits instead — it never falls back to the implicit
rung, because that would send the persona somewhere its author never named.

## The body

Everything after the front matter is the sub-agent's system prompt, frozen into
its session at creation. Write it for someone who sees nothing of the
conversation that delegated to them and cannot ask questions: say what the job
is, what counts as finished, and what to report back.

## A whole one

```markdown
---
name: explore
description: Read-only reconnaissance that returns a report
permissions: readonly
model: @explore
with: ["std:read,grep,glob"]
---
# nulya exploration sub-agent

You are a read-only exploration specialist. Investigate the caller's request and
return a concise, self-contained report.
```

## Checking your work

`nulya ext run agent list` parses every definition and prints what each resolved
to — layer, permissions, runner, rung. Warnings from a definition that loaded
with a field dropped appear there. Read it after writing a file: a definition
that silently lost a field still runs, just not as written.
