/**
 * A session MEMBER, and the whole of what a session composes.
 *
 * `<id>[@<version>][:<tool>,<tool>…]` is the one spelling the kernel takes, in
 * config's `[extensions] with` and in `session new --with`. A bare id brings the
 * package's `surface:"auto"` tools; a selection adds its `manual` ones by name;
 * `:none` brings nothing onto the model's tool face at all. Nothing is
 * activated by any of it — `activate` moves a store pointer every later session
 * then freezes, while a member is this composition and no other, so a mode can
 * be worn and taken off without the workspace remembering.
 *
 * What the session then sees is a system prompt and a skill catalog entry, not a
 * privilege: a data extension contributes text. The intelligence — what to build,
 * what is worth keeping — is in that text, above the kernel, where it belongs
 * (physics #8).
 */
import type { NewSessionOptions } from "./nulya/cli.ts"

export interface WithRef {
  id: string
  /** Absent means the store's `current`; the kernel fails if there is none. */
  version?: string
  /**
   * The tools this member puts on the model's face beyond the package's own
   * `surface:"auto"` default.
   *
   * `undefined` = nothing written after the id, so the package decides.
   * `[]` = `:none`, a member with nothing on the face at all. The two are
   * different answers and the kernel reads them differently, so they stay
   * different values here.
   */
  tools?: readonly string[]
}

/** The word an empty selection is written with, so `:` alone is never needed. */
const none_word = "none"

/** `id`, `id@v-…`, `id:read,grep`, `id@v-…:none` — the `--with` spelling. */
export function parseWithRef(word: string): WithRef | null {
  const trimmed = word.trim()
  if (trimmed.length === 0) return null
  // Neither an extension id nor a version contains `:`, so the first one starts
  // the tool selection.
  const colon = trimmed.indexOf(":")
  const head = colon < 0 ? trimmed : trimmed.slice(0, colon)
  const ref = parseHead(head)
  if (!ref) return null
  if (colon < 0) return ref
  return { ...ref, tools: parseSelection(trimmed.slice(colon + 1)) }
}

function parseHead(head: string): WithRef | null {
  const at = head.indexOf("@")
  if (at < 0) return head.length === 0 ? null : { id: head }
  const id = head.slice(0, at)
  const version = head.slice(at + 1)
  if (id.length === 0 || version.length === 0) return null
  return { id, version }
}

function parseSelection(text: string): string[] {
  const trimmed = text.trim()
  if (trimmed.length === 0 || trimmed === none_word) return []
  return trimmed
    .split(",")
    .map((name) => name.trim())
    .filter((name) => name.length > 0)
}

export function formatWithRef(ref: WithRef): string {
  const head = ref.version ? `${ref.id}@${ref.version}` : ref.id
  if (!ref.tools) return head
  return ref.tools.length === 0 ? `${head}:${none_word}` : `${head}:${ref.tools.join(",")}`
}

/** `session new` options that carry one `--with` member. */
export function withOptions(ref: WithRef): Pick<NewSessionOptions, "with"> {
  return { with: [formatWithRef(ref)] }
}

// --- a member list, seen as the tool face it selects ------------------------
//
// The panel that draws checkboxes thinks in stable tool ids; the kernel and
// every config file think in member specs. These four functions are the whole
// translation, so neither side has to learn the other's shape.

/** A stable tool id, the form the gate and the usage journal use. */
export function toolId(extension: string, tool: string): string {
  return `ext:${extension}/${tool}`
}

/** Split `ext:<id>/<tool>`, or null when it is not one. */
export function splitToolId(id: string): { extension: string; tool: string } | null {
  if (!id.startsWith("ext:")) return null
  const rest = id.slice("ext:".length)
  const slash = rest.indexOf("/")
  if (slash <= 0 || slash === rest.length - 1) return null
  return { extension: rest.slice(0, slash), tool: rest.slice(slash + 1) }
}

/** Every stable tool id the members' selections name, in list order. */
export function selectedToolIds(members: readonly string[]): string[] {
  const ids: string[] = []
  for (const spec of members) {
    const ref = parseWithRef(spec)
    for (const tool of ref?.tools ?? []) {
      const id = toolId(ref!.id, tool)
      if (!ids.includes(id)) ids.push(id)
    }
  }
  return ids
}

/**
 * Add one tool to a member list, creating the member when the list has none.
 *
 * A member already there keeps its version: a selection asks for the tool, not
 * for a version.
 */
export function selectTool(members: readonly string[], id: string): string[] {
  const split = splitToolId(id)
  if (!split) return [...members]
  const out = [...members]
  for (let i = 0; i < out.length; i++) {
    const ref = parseWithRef(out[i]!)
    if (!ref || ref.id !== split.extension) continue
    const tools = ref.tools ?? []
    if (tools.includes(split.tool)) return out
    out[i] = formatWithRef({ ...ref, tools: [...tools, split.tool] })
    return out
  }
  out.push(formatWithRef({ id: split.extension, tools: [split.tool] }))
  return out
}

/**
 * Take one tool off a member list, leaving the MEMBERSHIP alone: a member that
 * ends up selecting nothing becomes a bare id, because dropping it would take
 * away that package's skills and system prompts too — a different decision,
 * and one this key never made.
 */
export function deselectTool(members: readonly string[], id: string): string[] {
  const split = splitToolId(id)
  if (!split) return [...members]
  const out: string[] = []
  for (const spec of members) {
    const ref = parseWithRef(spec)
    if (!ref || ref.id !== split.extension || !ref.tools) {
      out.push(spec)
      continue
    }
    const tools = ref.tools.filter((tool) => tool !== split.tool)
    out.push(formatWithRef(tools.length === 0 ? { id: ref.id, version: ref.version } : { ...ref, tools }))
  }
  return out
}

/** Drop a package from a member list entirely — membership and all. */
export function dropMember(members: readonly string[], id: string): string[] {
  return members.filter((spec) => parseWithRef(spec)?.id !== id)
}

/**
 * Rewrite a member list so its selections are exactly `toolIds`, leaving every
 * MEMBERSHIP decision alone: an entry somebody wrote as a bare id stays bare,
 * one written `:none` stays `:none`, and an entry whose last selected tool went
 * away drops back to a bare id rather than out of the list.
 *
 * The panel owns which tools are selected; it does not own who is a member.
 */
export function applySelection(members: readonly string[], toolIds: readonly string[]): string[] {
  const wanted = new Map<string, string[]>()
  for (const id of toolIds) {
    const split = splitToolId(id)
    if (!split) continue
    const list = wanted.get(split.extension) ?? []
    if (!list.includes(split.tool)) list.push(split.tool)
    wanted.set(split.extension, list)
  }
  const out: string[] = []
  for (const spec of members) {
    const ref = parseWithRef(spec)
    if (!ref) {
      out.push(spec)
      continue
    }
    const tools = wanted.get(ref.id)
    wanted.delete(ref.id)
    if (tools && tools.length > 0) {
      out.push(formatWithRef({ ...ref, tools }))
      continue
    }
    out.push(formatWithRef({ id: ref.id, version: ref.version, tools: ref.tools?.length === 0 ? [] : undefined }))
  }
  for (const [id, tools] of wanted) out.push(formatWithRef({ id, tools }))
  return out
}
