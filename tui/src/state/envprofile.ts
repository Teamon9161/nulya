/**
 * Per exec-target-KIND tool-face profile (`tui.toml` `[env.local]` / `[env.wsl]`
 * / `[env.remote]`, tui.md §11 T88).
 *
 * `/env` (T86, DESIGN §8.1) moves where a session's `shell` commands run, but
 * the screen's own composition choices — which packages ride along as
 * `--with`, which extra tools get `--pin`ned, which packages render this
 * session's opening prompt — do not automatically follow, and the two halves
 * of `remote:` have DIFFERENT reasons for not following (goals/ground-remote.md
 * §5-§6).
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
 * Phase 3 (goals/remote-env.md §6.4) a SESSION's extension calls run on the
 * machine holding the workspace, so a pinned `ext:std/read` there would read
 * the far filesystem, correctly — it is not pointed at the host any more. What
 * actually keeps it off this list is that the far machine needs a build of
 * `std` for ITS target pushed first, or `session new`'s `exec_version` lookup
 * fails and the session does not open at all. Same default, honest reason: the
 * old one read as "a remote session cannot have file tools in principle", and
 * it is one `ext push` away.
 *
 * `local` and `wsl` have neither problem — WSL shares the host filesystem
 * through `/mnt/`, so a `std` pin or `ground`'s facts are exactly as true there
 * as on the host.
 *
 * (The exec-target `ssh:<dest>` spelling this file used to carry a third kind
 * for was retired 2026-08-30, goals/remote-env.md §7.1 — it wrapped the shell
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
 * The three kinds `/env`'s spec grammar can name (DESIGN §8.1, goals/
 * remote-env.md §3.9). `remote` covers the whole `remote:` family — `wsl` vs
 * `ssh` vs `exec` moves the CHANNEL, not what this profile should compose,
 * and the reasoning below (§3.9's own: no `std` pin, no `ground`, `--bare`)
 * applies identically to all three.
 *
 * There used to be a fourth, `ssh`, for the bare `ssh:<dest>` exec-target
 * spelling — retired 2026-08-30 (goals/remote-env.md §7.1). `[env.ssh]` is
 * therefore an unrecognised key in `tui.toml` now (`settings.ts` no longer
 * reads it), and a spec still typed that way reads as `local` below, same as
 * any other spelling this classifier does not know.
 */
export type ExecTargetKind = "local" | "wsl" | "remote"

/**
 * Classify an exec target spec into which KIND it is, for picking a profile —
 * not a second validator. `session new` still owns whether the spelling is
 * any good (`nulya/cli.ts`'s `NewSessionOptions.execEnv`); a spec this
 * function does not recognise is treated as `local` here, which is the
 * conservative reading (the fuller composition, not the stripped one) and
 * costs nothing extra since the kernel will refuse the bad spelling anyway —
 * `ssh:<dest>` included, now that `session new` refuses it too.
 *
 * `remote:` is checked before `wsl` on purpose: `remote:wsl:distro` does not
 * start with `wsl:`, so order would not actually matter here — but a
 * `remote:` spec that DID happen to read as the shorter prefix first would be
 * the wrong kind of wrong, composing a workspace-moving session with the
 * shell-only profile.
 */
export function execTargetKind(spec: string): ExecTargetKind {
  const trimmed = spec.trim()
  if (trimmed.length === 0 || trimmed === "local") return "local"
  if (trimmed.startsWith("remote:")) return "remote"
  if (trimmed === "wsl" || trimmed.startsWith("wsl:")) return "wsl"
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
  pins?: string[]
  session_prompts?: string[]
}

/** `tui.toml`'s `[env.*]` tables, keyed by kind. Any or all may be absent. */
export interface EnvProfiles {
  local?: EnvProfileOverride
  wsl?: EnvProfileOverride
  remote?: EnvProfileOverride
}

/** The profile after defaults and override have been merged — always complete. */
export interface ResolvedEnvProfile {
  /** `--bare`: skip the config's standing `[extensions] with` and `pinned_native_tools`. */
  bare: boolean
  /** Package ids to bring in with `--with` (in place of `extensions.session_with`). */
  with: readonly string[]
  /** Extra native tool ids to `--pin`, unioned with what the `with` members ask for. */
  pins: readonly string[]
  /** Package ids whose `render` becomes this session's `--prompt` (in place of `extensions.session_prompts`). */
  session_prompts: readonly string[]
}

/**
 * Zero-config defaults, one per kind. `local` and `wsl` are the screen's
 * existing behaviour verbatim — the front end's `session_with` /
 * `session_prompts` lists, no extra pins, the standing tables left alone.
 * `remote` only has `shell`/the workspace itself: no members, no renderers,
 * and `--bare` so the config's own standing packages (which were configured
 * with a local filesystem in mind) do not creep in either — this is a
 * different machine's filesystem, `std`'s read/grep/glob would answer
 * questions about the wrong one, and `ground`'s facts (this cwd, this branch)
 * would describe the host, not the workspace the session is actually about
 * (goals/remote-env.md §3.2).
 */
function defaultProfile(
  kind: ExecTargetKind,
  sessionWith: readonly string[],
  sessionPrompts: readonly string[],
): ResolvedEnvProfile {
  if (kind === "remote") return { bare: true, with: [], pins: [], session_prompts: [] }
  return { bare: false, with: sessionWith, pins: [], session_prompts: sessionPrompts }
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
    pins: over.pins ?? base.pins,
    session_prompts: over.session_prompts ?? base.session_prompts,
  }
}
