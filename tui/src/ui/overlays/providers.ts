/**
 * The three facts about a provider that both screens ask (tui.md §11, T21).
 *
 * `/model` and `/provider` are two views over the same `nulya config show
 * --json` rows, and exactly three questions are put on both: which model ids a
 * profile offers, whether its credential is an API key this front end could
 * write, and — when it cannot run — what is missing. One answer each, here, so
 * the two screens cannot drift into two.
 *
 * Everything else about a provider (the sentence naming its endpoint, its ready
 * chip, the wires the add form offers) is asked on `/provider` alone and lives
 * there. This module is the intersection, not a provider layer: it grew when
 * the second consumer appeared and holds nothing that only one of them uses.
 */
import type { ProfileView } from "../../nulya/cli.ts"

/** The model ids a profile offers, default first if it named one. */
export function modelIdsOf(profile: ProfileView): string[] {
  return profile.models.length > 0 ? profile.models : profile.model ? [profile.model] : []
}

/** Profiles whose credential is an API key we can write for them. */
export function keyable(profile: ProfileView): boolean {
  return profile.kind === "openai" || profile.kind === "anthropic"
}

/**
 * Why a profile cannot run, as a bare fact. What would FIX it is added by
 * whichever screen is showing it — `s` on the provider list, `/provider` from
 * the models — because the remedy is a different sentence in each place and a
 * key that is not on this screen is worse than no advice at all.
 */
export function blockedReason(profile: ProfileView): string {
  if (profile.credential) return ""
  if (profile.kind === "codex") return "run `codex login`"
  if (keyable(profile)) return "no key"
  return "no credential"
}
