---
name: mcp
description: How to put an MCP server behind Nulya tools — generating a package from a server, giving it its credentials, choosing which of its tools a session carries, and moving to a new version when the server changes. Read this before running mcp_add or editing a file under .nulya/mcp/.
---

# Putting an MCP server behind Nulya tools

One MCP server becomes one **generated extension package**. The generator starts
the server once, reads its `tools/list`, and freezes that list into an immutable
version. Nothing asks the server what it can do again: the frozen manifest is the
answer, and a server that grows a tool is a regeneration, not a surprise
mid-session.

The package is `mcp` itself. It is never a member of a session — both its tools
are `internal` — so you reach them over the shell:

```
nulya ext run mcp mcp_add '{"name":"…","command":"…"}'
nulya ext run mcp mcp_list
```

## 1. Generate

```
nulya ext run mcp mcp_add '{
  "name": "github",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-github"],
  "env": ["GITHUB_TOKEN"]
}'
```

| field | what it is |
|---|---|
| `name` | the short name: package id `mcp.github`, the prefix on every tool, the stem of the config file. Letters, digits, `-`, `_`. |
| `command` + `args` | how the server starts, on **stdio**. This version speaks no other transport; a `url` is refused. |
| `env` | the **names** of the variables the server needs. Only the names go into the package. |

It writes a draft to `.nulya/extensions/mcp.<name>/` and runs `nulya ext build`,
then prints the version. It **activates nothing** and puts nothing on any
model's tool face.

The generated tool names are `<name>_<server tool>` — `github_create_issue`.
The prefix is not decoration: two servers that both offer `search` would
otherwise collide, and a tool-name collision fails the whole `session new` by
name.

## 2. Give it its credentials

The transport's **shape** is inside the package and part of its version. The
**values** never are — a version directory is content-addressed and readable by
anything on the machine, and the harness strips secret-shaped variables out of an
extension's environment before it starts. So the values live in one of two files:

| file | layer |
|---|---|
| `.nulya/mcp/<name>.json` | this workspace — wins |
| `<NULYA_HOME or ~/.nulya>/mcp/<name>.json` | this machine |

```json
{ "env": { "GITHUB_TOKEN": "ghp_…" } }
```

**The nearest file wins whole**, not key by key: whichever of the two exists
first is the one that answers, so a workspace file must carry everything that
server needs. Nothing merges them, and nothing else reads them — the kernel does
not know these directories exist.

Until the values are there, every call to that package is one clean **failed
call** naming the variable, both file paths, and this manual. Nothing is broken;
it is not configured yet.

## 3. Choose which tools a session carries

Every generated tool is `surface: "manual"` and `recommended: false`. So
activating the package puts **nothing** on a model's face, and a fifty-tool
server does not cost fifty names:

```
nulya ext activate mcp.github <version>
```

then name the ones you want — by their **generated** names, prefix included —
either for one session

```
nulya session new --with mcp.github:github_create_issue,github_list_prs
```

or standing, in `[extensions] with` in your config:

```toml
[extensions]
with = ["std:read,edit", "mcp.github:github_create_issue"]
```

A session's tool budget counts only the tools it actually selected, so the
number that matters is the length of that line.

## 4. When the server changes

Run `mcp_add` again with the same `name`. If the server's tool face is unchanged
you get the **same version id** back — the version is a hash of the frozen
snapshot, so identical input is identical output and nothing is written. If it
grew or lost a tool, you get a new version, and the old one stays where it is:

```
nulya ext activate mcp.github <new version>   # switch
nulya ext activate mcp.github <old version>   # and that is also the rollback
```

A session already running keeps the version it froze at. That is the point: a
server cannot change what a conversation's tools mean while the conversation is
happening.

## What this version does not do

- **Only stdio.** No HTTP/SSE transport.
- **Only tools.** MCP resources, prompts, sampling and elicitation are not
  bridged. Sampling would need the server to call back into the model, and this
  harness's extension wire has no channel pointing that way.
- **No live tool discovery.** `tools/list_changed` is ignored by construction:
  the manifest is the truth, and it is frozen.
- One process per call. The server starts, answers one `tools/call`, and stops.

## Seeing what is there

```
nulya ext run mcp mcp_list     # every mcp.* package, its command, its tools, whether it is configured
nulya ext list                 # the same packages among all the others
nulya ext inspect mcp.github   # the frozen manifest, tool by tool
```
