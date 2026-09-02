/**
 * The model's tool face: which extension tools the NEXT session puts in front
 * of the model.
 *
 * A session composes ONE thing — a list of members, each written
 * `<id>[@<version>][:<tool>,…]` — so putting a tool on the face means naming it
 * in its package's member entry. The kernel keeps two places that list can be
 * written: `[extensions] with` in the config chain, and `session new --with` in
 * argv. `session new` unions them — config says "in this workspace, always",
 * argv says "for this session" — and a union only ever ADDS. That asymmetry is
 * the whole shape of this module, so it is said out loud rather than worked
 * around: there is no way to switch a config selection off for one session, and
 * the panel names the layer instead of pretending.
 *
 * Four states, therefore:
 *
 *  - `always`   — the USER config file selects it. Costs a slot and prefix tokens
 *                 in every session this machine opens, so turning it on is a
 *                 deliberate second key (`A`), never the first toggle.
 *  - `session`  — `tui-state.json` selects it, and every `session new` this TUI
 *                 runs carries it in a `--with`. Program state, not config:
 *                 trying a tool out costs nothing and leaves nothing behind.
 *  - `other`    — the merged projection selects it but the user file does not,
 *                 so a project or system layer wrote it. Read-only here: this
 *                 module writes exactly one key in exactly one file (D3).
 *  - `composed` — nothing selects it, and it will be on the face anyway: its
 *                 package is a member of every session started here (the
 *                 kernel's `[extensions] with`, or `tui.toml`'s `session_with`)
 *                 and the tool declares `surface:"auto"`. Read-only here for the
 *                 same reason `other` is — the decision is membership, not a
 *                 checkbox in this panel.
 *
 * Everything below the write helpers is pure, because "what would the next
 * session's tool face be" is a question that should be answerable without a
 * filesystem. Its currency is the stable tool id; the member specs both config
 * and argv speak are translated at the edges (`with.ts`).
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { applySelection, selectedToolIds, toolId } from "./with.ts"

export { toolId }

/** The one builtin is always on the face and always counts. */
export const builtin_tools = 1

export type FaceState = "always" | "session" | "other" | "composed" | "off"

/**
 * Where a selection can be written down, read from all three places at once,
 * each already flattened to the tool ids its member list selects. `merged` is
 * the kernel's own projection (`config show --json`); `user` is the file this
 * module writes, read separately because the projection deliberately does not
 * say which layer contributed what.
 */
export interface FaceSources {
  user: readonly string[]
  session: readonly string[]
  merged: readonly string[]
  /**
   * Tools that reach the face without any selection naming them:
   * `surface:"auto"` tools from packages composed into every session. Not a
   * place a selection is WRITTEN — a place the face gets one anyway — and this
   * panel has to know about it, because a row that reads `off` about a tool the
   * model can call is simply wrong.
   */
  composed?: readonly string[]
}

export function faceState(id: string, sources: FaceSources): FaceState {
  if (sources.user.includes(id)) return "always"
  if (sources.session.includes(id)) return "session"
  if (sources.merged.includes(id)) return "other"
  if (sources.composed?.includes(id)) return "composed"
  return "off"
}

export function stateLabel(state: FaceState): string {
  if (state === "always") return "always"
  if (state === "session") return "this TUI"
  if (state === "other") return "from another config layer"
  if (state === "composed") return "with the package"
  return ""
}

/**
 * What a keypress would leave behind. A field is null when that store is not
 * touched — the caller writes only what changed, so a toggle on the session
 * list never rewrites the config file.
 */
export interface FaceChange {
  user: string[] | null
  session: string[] | null
  notice: string
}

const unchanged = (notice: string): FaceChange => ({ user: null, session: null, notice })

function without(list: readonly string[], id: string): string[] {
  return list.filter((entry) => entry !== id)
}

function with_(list: readonly string[], id: string): string[] {
  return list.includes(id) ? [...list] : [...list, id]
}

/**
 * `Space` on a tool row.
 *
 * On goes to `session` first, always: a tool the user is trying out should not
 * edit a config file, and one they meant forever is one key further (`A`). Off
 * removes it from wherever this TUI put it — and says so plainly when the
 * selection is not ours to remove.
 */
export function toggle(id: string, sources: FaceSources): FaceChange {
  const state = faceState(id, sources)
  if (state === "other") {
    return unchanged(`${id} is selected by another config layer · edit that file to change it`)
  }
  if (state === "composed") {
    return unchanged(`${id} comes with composed package membership · remove that membership rather than a tool`)
  }
  if (state === "always") {
    return { user: without(sources.user, id), session: null, notice: `${id} off · next session` }
  }
  if (state === "session") {
    return { user: null, session: without(sources.session, id), notice: `${id} off · next session` }
  }
  return { user: null, session: with_(sources.session, id), notice: `${id} · this TUI · next session` }
}

/**
 * `A` on a tool row: make it the workspace's standing decision.
 *
 * The session copy goes away in the same move. Keeping both would be harmless
 * to the kernel (the union de-duplicates) but a lie on screen — two rows of
 * state for one tool, and an `always` that a later toggle appears to half-undo.
 */
export function promote(id: string, sources: FaceSources): FaceChange {
  const state = faceState(id, sources)
  if (state === "always") return unchanged(`${id} is already always`)
  if (state === "other") {
    return unchanged(`${id} is selected by another config layer · edit that file to change it`)
  }
  if (state === "composed") {
    return unchanged(`${id} is already on every session's face, with its package`)
  }
  return {
    user: with_(sources.user, id),
    session: sources.session.includes(id) ? without(sources.session, id) : null,
    notice: `${id} · always · written to the user config`,
  }
}

/**
 * Every tool of an extension onto this TUI's list, in one move — the tool half
 * of the `/ext` switch. Only ever adds: turning an extension ON must not
 * silently take a tool off something else.
 */
export function selectAll(ids: readonly string[], sources: FaceSources): FaceChange {
  const mine = ids.filter((id) => faceState(id, sources) === "off")
  if (mine.length === 0) return unchanged("")
  let session = sources.session
  for (const id of mine) session = with_(session, id)
  return { user: null, session: [...session], notice: "" }
}

/**
 * The other half: take an extension's tools off both lists this panel writes.
 *
 * A selection left behind by a deactivation is not harmless — a member with no
 * `current` makes the next `session new` refuse (`WithVersionNotFound`) and the
 * session simply does not start — so OFF has to clear `always` too, which is
 * the one case where this module writes the config file without being asked for
 * `A`. A selection some other layer wrote still cannot be touched (D3), so it is
 * named instead.
 */
export function deselectAll(ids: readonly string[], sources: FaceSources): FaceChange {
  let user = sources.user
  let session = sources.session
  const stuck: string[] = []
  for (const id of ids) {
    if (faceState(id, sources) === "other") {
      stuck.push(id)
      continue
    }
    user = without(user, id)
    session = without(session, id)
  }
  return {
    user: user === sources.user ? null : [...user],
    session: session === sources.session ? null : [...session],
    notice: stuck.length > 0 ? `${stuck.join(" ")} stays: another config layer selects it` : "",
  }
}

/**
 * Session selections naming a tool nothing on offer declares.
 *
 * `session new --with <id>:<tool>` is resolved against the composition, so one
 * whose extension was rolled back or deactivated does not degrade — it refuses,
 * and the session does not start at all. The list is this TUI's own program
 * state, so the honest repair is to drop the line rather than to keep offering a
 * session that cannot open.
 */
export function orphanTools(selected: readonly string[], available: readonly string[]): string[] {
  return selected.filter((id) => !available.includes(id))
}

/**
 * Every tool id a STANDING member list may name, from a store listing.
 *
 * One condition is the kernel's: the extension has a version in effect — a
 * member with no `current` does not open a session. The second is the tool's
 * manifest surface: only a `surface:"manual"` tool needs naming.
 * `surface:"auto"` tools arrive with membership, and `surface:"internal"` tools
 * are for `nulya ext run`; naming one of those refuses the whole session
 * (`WithToolNotDeclared`).
 */
export function resolvableSelections(
  entries: readonly {
    id: string
    manualTools: readonly string[]
    current: string | null
  }[],
): string[] {
  const ids: string[] = []
  for (const entry of entries) {
    if (!entry.current) continue
    for (const tool of entry.manualTools) ids.push(toolId(entry.id, tool))
  }
  return ids
}

/**
 * The quota line. `max_tools` counts the builtin, so it is shown
 * rather than hidden — a face of 8 that already spends 1 is the fact behind
 * every "why was my tool refused".
 *
 * Nothing is prevented here. Over-subscription is refused by `session new`, and
 * the panel repeats the kernel's own sentence rather than predicting it.
 */
export function quotaLine(maxTools: number, selected: number): string {
  const line = `tools ${builtin_tools}+${selected}/${maxTools}`
  if (builtin_tools + selected <= maxTools) return line
  const over = builtin_tools + selected - maxTools
  return `${line} · ${over} more than registry.max_tools allows · take ${
    over === 1 ? "one" : `${over}`
  } off in the tools pane, or no session will start`
}

/**
 * The face is full and a batch did not fit — in a sentence somebody can act on,
 * rather than in the gauge's arithmetic (`2+9/8 · nothing changed` was once the
 * whole explanation a person got for pressing Enter and seeing nothing happen).
 *
 * It is not a refusal. Membership and the tool face are two questions one member
 * line answers: an extension can be composed with none of its tools in front of
 * the model, and `nulya ext run` reaches them there — which is exactly how
 * `/compact` has always called `compact`.
 */
export function faceFullLine(maxTools: number, face: number, left: number): string {
  return `tool face is full at ${builtin_tools}+${face}/${maxTools} · ${left} tool${
    left === 1 ? "" : "s"
  } left off · Space in the tools pane frees a slot; ext run reaches them either way`
}

// --- the user config file ---------------------------------------------------

const extensions_table = "extensions"
const with_key = "with"

/** `[extensions] with` as the USER file writes it — not the merged chain. */
export function readUserMembers(path: string): string[] {
  if (!existsSync(path)) return []
  try {
    return membersOf(Bun.TOML.parse(readFileSync(path, "utf8")))
  } catch {
    // A config the TUI cannot parse is not an empty config, but it is also not
    // ours to repair; `writeUserMembers` re-reads and refuses rather than
    // flattening a file it did not understand.
    return []
  }
}

export function membersOf(parsed: unknown): string[] {
  if (typeof parsed !== "object" || parsed === null) return []
  const extensions = (parsed as Record<string, unknown>)[extensions_table]
  if (typeof extensions !== "object" || extensions === null) return []
  const members = (extensions as Record<string, unknown>)[with_key]
  return Array.isArray(members) ? members.filter((entry): entry is string => typeof entry === "string") : []
}

/** The tool ids the USER file's member list selects. */
export function readUserSelection(path: string): string[] {
  return selectedToolIds(readUserMembers(path))
}

function renderMembers(members: readonly string[]): string {
  return `${with_key} = [${members.map((member) => JSON.stringify(member)).join(", ")}]`
}

/** A `[table]` or `[[array]]` header line, and the name it opens. */
function tableOf(line: string): string | null {
  const match = /^\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*$/.exec(line)
  return match ? match[1]! : null
}

/** Brackets outside of quotes, so a member containing `]` cannot end the array. */
function bracketDelta(line: string): number {
  let delta = 0
  let quote: string | null = null
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]!
    if (quote) {
      if (ch === "\\" && quote === '"') i += 1
      else if (ch === quote) quote = null
      continue
    }
    if (ch === '"' || ch === "'") quote = ch
    else if (ch === "#") break
    else if (ch === "[") delta += 1
    else if (ch === "]") delta -= 1
  }
  return delta
}

/**
 * Replace (or add) exactly the `[extensions] with` line, leaving every other
 * byte of the file alone (D3).
 *
 * Re-serialising the parsed document would be one line of code and would throw
 * away the comments and the ordering somebody wrote by hand — a config file is
 * a person's own text, and a program that owns one key in it does not get to
 * reformat the rest. The array may span lines, so the span is found by counting
 * brackets outside strings rather than by assuming one line.
 */
export function setMembers(text: string, members: readonly string[]): string {
  const trailing = text.length > 0 && !text.endsWith("\n") ? "" : "\n"
  const lines = text.length === 0 ? [] : text.replace(/\n$/, "").split("\n")
  const rendered = renderMembers(members)

  let table: string | null = null
  let sectionStart = -1
  let sectionEnd = -1
  for (let i = 0; i < lines.length; i++) {
    const opened = tableOf(lines[i]!)
    if (opened !== null) {
      if (table === extensions_table && sectionEnd < 0) sectionEnd = i
      table = opened
      if (table === extensions_table && sectionStart < 0) sectionStart = i
      continue
    }
    if (table !== extensions_table) continue
    if (!new RegExp(`^\\s*${with_key}\\s*=`).test(lines[i]!)) continue
    // The key: consume until the array it opens is closed again.
    let depth = bracketDelta(lines[i]!)
    let last = i
    while (depth > 0 && last + 1 < lines.length) {
      last += 1
      depth += bracketDelta(lines[last]!)
    }
    return [...lines.slice(0, i), rendered, ...lines.slice(last + 1)].join("\n") + trailing
  }

  if (sectionStart >= 0) {
    // Inside the table, after its last written line: a key appended under the
    // comment that explains it reads as belonging to it.
    if (sectionEnd < 0) sectionEnd = lines.length
    let at = sectionEnd
    while (at > sectionStart + 1 && lines[at - 1]!.trim().length === 0) at -= 1
    return [...lines.slice(0, at), rendered, ...lines.slice(at)].join("\n") + trailing
  }

  const head = lines.length > 0 && lines[lines.length - 1]!.trim().length > 0 ? [...lines, ""] : lines
  return [...head, `[${extensions_table}]`, rendered].join("\n") + trailing
}

/**
 * Write the member list, then read it back and check.
 *
 * The check is the point: this edits a file by text surgery, and a surgery that
 * silently produced something the kernel reads differently would show a tool as
 * on the face that no session ever carries. On disagreement the original bytes
 * go back and the caller hears about it.
 */
export function writeUserMembers(path: string, members: readonly string[]): void {
  const before = existsSync(path) ? readFileSync(path, "utf8") : ""
  const after = setMembers(before, members)
  writeFileSync(path, after)
  let round: string[]
  try {
    round = membersOf(Bun.TOML.parse(readFileSync(path, "utf8")))
  } catch (error) {
    writeFileSync(path, before)
    throw new Error(`${path} would not parse after the edit; nothing changed (${String(error)})`)
  }
  if (round.length !== members.length || round.some((member, at) => member !== members[at])) {
    writeFileSync(path, before)
    throw new Error(`${path} did not read back as written; nothing changed`)
  }
}

/** Write the user file's member list so its selections are exactly `toolIds`. */
export function writeUserSelection(path: string, toolIds: readonly string[]): void {
  writeUserMembers(path, applySelection(readUserMembers(path), toolIds))
}
