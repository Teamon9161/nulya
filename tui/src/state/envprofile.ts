/**
 * Per exec-target-KIND tool-face profile (`tui.toml` `[env.local]` /
 * `[env.remote]`).
 *
 * `/env` moves where a session's `shell` commands run, but
 * the screen's own composition choices — which packages ride along as
 * `--with` and which packages render this session's opening prompt — do not
 * automatically follow.
 *
 * `ground` renders host facts — this cwd, this branch, this git status — and on
 * a `remote:` target the workspace those describe is somewhere else. It is a
 * driver-side `ext run` on THIS machine, before any session exists, so nothing
 * moves it; a map of the wrong machine frozen into the header is worse than no
 * map, because the model will not check it. Rendering it over there was costed
 * out and deferred (`ground` is compiled, so it would mean a cross-build and a
 * push per remote machine, for one consumer).
 *
 * `std` is a different story and the reason here used to be wrong. Since
 * Phase 3 a SESSION's extension calls run on the
 * machine holding the workspace, so a pinned `ext:std/read` there would read
 * the far filesystem, correctly — it is not pointed at the host any more. What
 * actually keeps it off this list is that the far machine has its own store:
 * without a build of `std` for ITS target pushed there first, every call the
 * model makes comes back "no copy of that version on this machine". Same
 * default, honest reason: the old one read as "a remote session cannot have
 * file tools in principle", and it is one `ext push` plus one `[env.remote]
 * with` away.
 *
 * `local` has neither problem — it IS the host filesystem, so a `std` pin or
 * `ground`'s facts are exactly as true there as anywhere.
 *
 * (Two other kinds used to live here. The exec-target `ssh:<dest>` spelling
 * was retired 2026-08-30, goals/remote-env.md §7.1; `wsl` (the exec-target
 * spelling, not `remote:wsl`) was retired 2026-09-02. Both wrapped the shell
 * elsewhere while leaving `std`/`ground` pointed at the host, exactly the
 * mismatch this profile exists to route around, so removing the word removed
 * the kind rather than leaving an unreachable branch behind.)
 *
 * Nothing here talks to disk or the kernel. `resolveEnvProfile` is a pure
 * merge of a per-kind zero-config default with whatever `tui.toml` overrode,
 * so it is the one place both `App.tsx`'s `sessionExtras()` (what actually
 * gets composed) and its tool-count display can read from — one function, two
 * call sites, never two answers to "what does this env compose".
 */

/**
 * The two kinds `/env`'s spec grammar can name. `remote` covers the whole
 * `remote:` family — `wsl` vs `ssh` vs `exec` moves the CHANNEL, not what
 * this profile should compose, and the reasoning below (no `std` pin, no
 * `ground`, `--bare`) applies identically to all three.
 *
 * `[env.ssh]` / `[env.wsl]` are unrecognised keys in `tui.toml` (`settings.ts`
 * does not read them), and a bare `ssh:<dest>` or `wsl[:<distro>]` spec reads
 * as `local` below, same as any other spelling this classifier does not know.
 */
export type ExecTargetKind = "local" | "remote"

/**
 * Classify an exec target spec into which KIND it is, for picking a profile —
 * not a second validator. `session new` still owns whether the spelling is
 * any good (`nulya/cli.ts`'s `NewSessionOptions.execEnv`); a spec this
 * function does not recognise is treated as `local` here, which is the
 * conservative reading (the fuller composition, not the stripped one) and
 * costs nothing extra since the kernel will refuse the bad spelling anyway —
 * `ssh:<dest>` and `wsl[:<distro>]` included, now that `session new` refuses
 * both.
 */
export function execTargetKind(spec: string): ExecTargetKind {
  const trimmed = spec.trim()
  if (trimmed.startsWith("remote:")) return "remote"
  return "local"
}

/**
 * What `tui.toml` may say about one kind. A field left out of the file keeps
 * the zero-config default for that kind; a field written REPLACES it outright
 * (same discipline as `settings.ts`'s `session_with` — a nearer layer that
 * wants fewer things must be able to say so, not have its list unioned away).
 */
export interface EnvProfileOverride {
  bare?: boolean
  with?: string[]
  session_prompts?: string[]
}

/** `tui.toml`'s `[env.*]` tables, keyed by kind. Any or all may be absent. */
export interface EnvProfiles {
  local?: EnvProfileOverride
  remote?: EnvProfileOverride
}

/** The profile after defaults and override have been merged — always complete. */
export interface ResolvedEnvProfile {
  /**
   * Nothing standing rides along: not the kernel config's `[extensions] with`
   * (which is what the `--bare` flag itself says) and not this front end's own
   * remembered members either (`tui-state.json`'s `session_with`, the `/ext`
   * picks — `state/tabs.ts`'s `SessionExtras.bare`). One word for both,
   * because they are the same kind of thing: a list somebody wrote down once,
   * for the machine they were on at the time.
   */
  bare: boolean
  /**
   * Members to bring in with `--with` (in place of `extensions.session_with`),
   * each `<id>[:<tool>,…]`. Without a selection the package's own `manual` tools
   * are all taken, which is what turning a package on has always meant here.
   */
  with: readonly string[]
  /** Package ids whose `render` becomes this session's `--prompt` (in place of `extensions.session_prompts`). */
  session_prompts: readonly string[]
}

/**
 * Zero-config defaults, one per kind. `local` is the screen's existing
 * behaviour verbatim — the front end's `session_with` / `session_prompts`
 * lists, the standing table left alone.
 * `remote` only has `shell`/the workspace itself: no members, no renderers,
 * and `bare` so neither standing list creeps in either — not the config's
 * `[extensions] with`, not this front end's own `/ext` picks. Both were
 * written down with a local machine in mind: `ground`'s facts (this cwd, this
 * branch) would describe the host rather than the workspace the session is
 * about, and `std` is not in that machine's store at all.
 */
function defaultProfile(
  kind: ExecTargetKind,
  sessionWith: readonly string[],
  sessionPrompts: readonly string[],
): ResolvedEnvProfile {
  if (kind === "remote") return { bare: true, with: [], session_prompts: [] }
  return { bare: false, with: sessionWith, session_prompts: sessionPrompts }
}

/**
 * The profile a session composed for `kind` should use: the zero-config
 * default for that kind with `tui.toml`'s `[env.<kind>]` table applied field
 * by field on top. No table for `kind`, or an empty one, is exactly the
 * default — this is total and never throws.
 */
export function resolveEnvProfile(
  kind: ExecTargetKind,
  sessionWith: readonly string[],
  sessionPrompts: readonly string[],
  overrides: EnvProfiles,
): ResolvedEnvProfile {
  const base = defaultProfile(kind, sessionWith, sessionPrompts)
  const over = overrides[kind]
  if (!over) return base
  return {
    bare: over.bare ?? base.bare,
    with: over.with ?? base.with,
    session_prompts: over.session_prompts ?? base.session_prompts,
  }
}
