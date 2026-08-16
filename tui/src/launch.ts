/**
 * What to start on, decided before the screen exists (tui.md §1.2 D8).
 *
 * The order is: what the command line names > what the user picked last time
 * (`tui-state.json`) > the kernel's active profile. But a choice is only worth
 * starting on if it can run — a profile with no usable credential would freeze
 * a *scripted* session (DESIGN §3), and a person who asked for DeepSeek and got
 * a canned stand-in has been misled. So each candidate is checked against
 * `nulya config show`, and when nothing implicit can run, the session that is
 * created is the honest offline one AND the picker opens on top of it with the
 * reason: the way out is the first thing on screen.
 */
import type { ConfigView } from "./nulya/cli.ts"
import type { ModelPick } from "./state/tui_state.ts"

export interface LaunchArgs {
  profile?: string
  model?: string
  effort?: string
}

export interface LaunchPlan {
  /** Passed to `session new`; undefined = the kernel's own default. */
  pick?: ModelPick
  /** Set when the plan is not what was asked for: open `/model` with this line. */
  guide?: string
  /** Stop with this message instead of starting: an explicit ask that cannot be met. */
  refuse?: string
}

function reason(config: ConfigView, profile: string): string {
  const p = config.profiles.find((entry) => entry.name === profile)
  if (!p) return `no profile named '${profile}'`
  if (p.kind === "codex") return `${profile} needs \`codex login\``
  if (p.kind === "openai" || p.kind === "anthropic") return `${profile} has no API key`
  return `${profile} has no credential`
}

function runnable(config: ConfigView, profile: string): boolean {
  return config.profiles.some((p) => p.name === profile && p.credential)
}

export function planLaunch(args: LaunchArgs, last: ModelPick | undefined, config: ConfigView): LaunchPlan {
  // Explicit: run it or say exactly why not. Never quietly substitute.
  if (args.profile) {
    if (!runnable(config, args.profile)) {
      return {
        refuse: `${reason(config, args.profile)} · put api_key in ${config.paths.user || "the user config"} (or press s on it in /model), or see \`nulya config show\``,
      }
    }
    return { pick: { profile: args.profile, model: args.model, effort: args.effort } }
  }
  // Remembered: the whole pick, unless its profile lost its key since.
  if (last && runnable(config, last.profile)) {
    return { pick: { ...last, model: args.model ?? last.model, effort: args.effort ?? last.effort } }
  }
  // The kernel's default.
  const active = config.active_profile
  if (active.length > 0 && runnable(config, active)) {
    return { pick: { profile: active, model: args.model, effort: args.effort } }
  }
  // Nothing implicit can run: start offline, and open the picker with why.
  const why = last && !runnable(config, last.profile) ? reason(config, last.profile) : reason(config, active || "?")
  return {
    pick: { profile: "scripted" },
    guide: `${why} · this session is the offline stand-in · pick a row marked ready, or press s on one to paste its API key`,
  }
}
