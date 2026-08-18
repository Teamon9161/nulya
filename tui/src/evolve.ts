/**
 * `/evolve` and `/mode` — putting a package in front of the model for ONE
 * session (DESIGN §7.5, PLAN §3.7.9).
 *
 * Both are the same two moves: build a draft into the store, then start a
 * session `--with` that exact version. Neither activates anything, and that is
 * the point — `activate` moves a store pointer that every later session then
 * freezes, while `--with` is membership in this composition and no other. So a
 * mode can be worn and taken off without the workspace remembering, and the
 * evolution package can look at the machinery it is about to change without
 * becoming a permanent part of it.
 *
 * What the session then sees is a system prompt and a skill catalog entry, not a
 * privilege: a data extension contributes text. The intelligence — what to build,
 * what is worth keeping — is in that text, above the kernel, where it belongs
 * (physics #8).
 */
import { extBuild, type NewSessionOptions } from "./nulya/cli.ts"
import { bundledDraftPath } from "./extensions.ts"
import type { Workspace } from "./nulya/bin.ts"

/**
 * The evolution package's draft, relative to the workspace, when the workspace
 * is nulya's own source tree. Anywhere else the binary's embedded copy is
 * seeded into the user store and built from there (`bundledDraftPath`), so
 * `/evolve` works wherever the binary goes.
 */
export const evolution_draft = "extensions/evolution"

export const evolution_id = "evolution"

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

/**
 * Build the evolution draft and name the version to bring in.
 *
 * Building every time is deliberate: a version id is a hash of the draft, so an
 * unchanged package rebuilds to the version already in the store and costs a
 * directory walk. Edit the prompt or the skill and `/evolve` picks it up on the
 * next run without anybody remembering to rebuild.
 */
export async function buildEvolution(ws: Workspace): Promise<WithRef> {
  const draft = await bundledDraftPath(ws, evolution_id, evolution_draft)
  return { id: evolution_id, version: await extBuild(ws, draft) }
}

/** `session new` options that carry one `--with` member. */
export function withOptions(ref: WithRef): Pick<NewSessionOptions, "with"> {
  return { with: [formatWithRef(ref)] }
}
