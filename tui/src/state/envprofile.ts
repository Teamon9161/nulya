/**
 * Per exec-target-KIND tool-face profile (`tui.toml` `[env.local]` / `[env.wsl]`
 * / `[env.ssh]`, tui.md §11 T88).
 *
 * `/env` (T86, DESIGN §8.1) moves where a session's `shell` commands run, but
 * the screen's own composition choices — which packages ride along as
 * `--with`, which extra tools get `--pin`ned, which packages render this
 * session's opening prompt — do not automatically follow. `ext:std/read` reads
 * THIS machine's filesystem; on an `ssh:` target that is a filesystem the
 * commands never touch, so pinning it there manufactures "not found" rather
 * than a working tool. `ground`'s opening facts (this cwd, this branch, this
 * git status) are wrong for the same reason. `local` and `wsl` do not have
 * this problem — WSL shares the host filesystem through `/mnt/`, so a `std`
 * pin or `ground`'s facts are exactly as true there as on the host.
 *
 * Nothing here talks to disk or the kernel. `resolveEnvProfile` is a pure
 * merge of a per-kind zero-config default with whatever `tui.toml` overrode,
 * so it is the one place both `App.tsx`'s `sessionExtras()` (what actually
 * gets composed) and its tool-count display can read from — one function, two
 * call sites, never two answers to "what does this env compose".
 */

/**
 * The four kinds `/env`'s spec grammar can name (DESIGN §8.1, goals/
 * remote-env.md §3.9). `remote` covers the whole `remote:` family — `wsl` vs
 * `ssh` vs `exec` moves the CHANNEL, not what this profile should compose,
 * and the reasoning below (§3.9's own: no `std` pin, no `ground`, `--bare`)
 * applies identically to all three, unlike the old `wsl`/`ssh` split where
 * `wsl` keeps today's defaults and `ssh` does not.
 */
export type ExecTargetKind = "local" | "wsl" | "ssh" | "remote"

/**
 * Classify an exec target spec into which KIND it is, for picking a profile —
 * not a second validator. `session new` still owns whether the spelling is
 * any good (`nulya/cli.ts`'s `NewSessionOptions.execEnv`); a spec this
 * function does not recognise is treated as `local` here, which is the
 * conservative reading (the fuller composition, not the stripped one) and
 * costs nothing extra since the kernel will refuse the bad spelling anyway.
 *
 * `remote:` is checked before `wsl`/`ssh` on purpose: `remote:wsl:distro` and
 * `remote:ssh:host` both start with neither of those two prefixes, so order
 * would not actually matter here — but a `remote:` spec that DID happen to
 * read as one of the shorter prefixes first would be the wrong kind of wrong,
 * composing a workspace-moving session with the old shell-only profile.
 */
export function execTargetKind(spec: string): ExecTargetKind {
  const trimmed = spec.trim()
  if (trimmed.length === 0 || trimmed === "local") return "local"
  if (trimmed.startsWith("remote:")) return "remote"
  if (trimmed === "wsl" || trimmed.startsWith("wsl:")) return "wsl"
  if (trimmed.startsWith("ssh:")) return "ssh"
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
  ssh?: EnvProfileOverride
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
 * `ssh` and `remote` only have `shell`/the workspace itself: no members, no
 * renderers, and `--bare` so the config's own standing packages (which were
 * configured with a local filesystem in mind) do not creep in either. `remote`
 * gets the same treatment as `ssh` rather than `wsl`'s, and for the SAME
 * reason `ssh` does not get `wsl`'s: this is a different machine's filesystem,
 * `std`'s read/grep/glob would answer questions about the wrong one, and
 * `ground`'s facts (this cwd, this branch) would describe the host, not the
 * workspace the session is actually about (goals/remote-env.md §3.2).
 */
function defaultProfile(
  kind: ExecTargetKind,
  sessionWith: readonly string[],
  sessionPrompts: readonly string[],
): ResolvedEnvProfile {
  if (kind === "ssh" || kind === "remote") return { bare: true, with: [], pins: [], session_prompts: [] }
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
