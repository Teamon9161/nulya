---
name: configuring-a-front-end
description: Where a session driver's own settings live and how to find out what they take — the shipped front ends are nulya-tui (tui.toml) and nulya-acp (acp.toml). Read this when asked to configure the program someone is talking to Nulya through, rather than Nulya itself.
---

# Configuring the program that drives a session

A **driver** is any program that composes `nulya session new` / `step` /
`append` into something a person uses. It is not an extension: it has no
manifest, contributes no tools and no skills, and its settings are **not** a
Nulya config layer — `nulya config show` will never mention them.

This page is an index, not a manual. It says where each file is and which
command prints what that file takes. **The command is the manual**, because it
is built from the same code that reads the file; a table copied onto this page
would be a second author of the same fact and would go stale at the next
release.

## The two this repository ships

| program | settings file | what it is |
|---|---|---|
| `nulya-tui` | `tui.toml` | the terminal interface |
| `nulya-acp` | `acp.toml` | the Agent Client Protocol adapter an editor spawns |

Both files have the same two layers, nearer wins, neither has to exist:

1. `$NULYA_HOME/<file>`, else `~/.nulya/<file>` (Windows: `%USERPROFILE%\.nulya\<file>`)
2. `<workspace>/.nulya/<file>`

Same directory as the kernel's own `config.toml`, and the same discipline for
list-shaped keys: a nearer layer **replaces** a list rather than merging into
it, so narrowing is always available.

## What a file takes

Ask the program:

```
nulya-tui --settings-help
nulya-acp --settings-help
```

Each prints every key it reads, the values that key accepts, and its default.
`--help` on either prints its command line.

**Finding the binary.** It may not be on PATH; it is not `$NULYA_EXE`, which is
the kernel. If a driver reported itself when this session started, the opening
context has a `driver` line and a `driver settings` line naming the exact
command — look there first. Otherwise ask the person which one they are using
and where it lives.

## Two things not in either file

- **What was chosen on screen** — model, permission mode, which packages the
  interface composes, sidebar, tabs — lives in `tui-state.json` beside
  `tui.toml`. That file is **written by the program**, is a record of what a
  person picked, and is not a place to configure anything. Do not edit it.
- **`nulya-acp`'s permission mode** is `--mode ask|unsafe` on its command line,
  because an editor already spawns one process per workspace. An editor that
  launches it has that line in its own configuration.

## Which half of a question is which

Some things a person calls "settings" belong to Nulya rather than to the
driver, and those are configured once for every driver:

- **Which packages a session wears**, at the kernel level: `[extensions] with`
  in `config.toml`. A front end may add more on top for the sessions IT opens —
  that half is in its own file.
- **Profiles, models, credentials, `max_tools`**: `config.toml`. `nulya config
  show` prints the effective result and the exact paths.
- **What any package accepts**: that package's own skill. `nulya skill list`,
  then `nulya skill load <ref>`.

`skill load guide` covers the mechanisms behind all three.
