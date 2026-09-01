/**
 * `/with` — putting a package in front of the model for ONE session.
 *
 * One move: start a session `--with` a named version. Nothing is activated, and
 * that is the point — `activate` moves a store pointer that every later session
 * then freezes, while `--with` is membership in this composition and no other.
 * So a mode can be worn and taken off without the workspace remembering.
 *
 * What the session then sees is a system prompt and a skill catalog entry, not a
 * privilege: a data extension contributes text. The intelligence — what to build,
 * what is worth keeping — is in that text, above the kernel, where it belongs
 * (physics #8).
 *
 * This file used to be `evolve.ts`, and carried a build of one particular
 * package beside these functions: `/evolve` was hard-wired here to rebuild the
 * shipped evolution draft before wearing it. That package declares its own
 * command now, so what is left is the general machinery `/with`, `/agent`
 * and every package command share, and it is named after it.
 */
import type { NewSessionOptions } from "./nulya/cli.ts"

export interface WithRef {
  id: string
  /** Absent means the store's `current`; the kernel fails if there is none. */
  version?: string
}

/** `id`, `id@v-…` — the shape `session new --with` takes. */
export function parseWithRef(word: string): WithRef | null {
  const trimmed = word.trim()
  if (trimmed.length === 0) return null
  const at = trimmed.indexOf("@")
  if (at < 0) return { id: trimmed }
  const id = trimmed.slice(0, at)
  const version = trimmed.slice(at + 1)
  if (id.length === 0 || version.length === 0) return null
  return { id, version }
}

export function formatWithRef(ref: WithRef): string {
  return ref.version ? `${ref.id}@${ref.version}` : ref.id
}

/** `session new` options that carry one `--with` member. */
export function withOptions(ref: WithRef): Pick<NewSessionOptions, "with"> {
  return { with: [formatWithRef(ref)] }
}
