/**
 * Pins: which extension tools the NEXT session puts on the model's tool face
 * (tui.md §11, T12).
 *
 * A pin is a decision, and the kernel keeps two places to write it down
 * (DESIGN §5.1): `registry.pinned_native_tools` in the config chain, and
 * `session new --pin` in argv. `session new` unions them — config says "in this
 * workspace, always", argv says "for this session" — and a union only ever
 * ADDS. That asymmetry is the whole shape of this module, so it is said out
 * loud rather than worked around: there is no way to switch a config pin off
 * for one session, and the panel names the layer instead of pretending.
 *
 * Three states, therefore:
 *
 *  - `always`   — the USER config file has it. Costs a slot and prefix tokens in
 *                 every session this machine opens, so turning it on is a
 *                 deliberate second key (`A`), never the first toggle.
 *  - `session`  — `tui-state.json` has it, and every `session new` this TUI runs
 *                 carries `--pin`. Program state, not config: trying a tool out
 *                 costs nothing and leaves nothing behind.
 *  - `other`    — the merged projection has it but the user file does not, so a
 *                 project or system layer wrote it. Read-only here: this module
 *                 writes exactly one key in exactly one file (D3).
 *  - `composed` — no list has it, and it will be on the face anyway: its package
 *                 is one this front end brings into every session it starts
 *                 (`[extensions] session_with`), and `session new --pin`s its
 *                 model tools there (T42). Read-only here for the same reason
 *                 `other` is — the decision is in `tui.toml`, not in this panel.
 *
 * Everything below the write helpers is pure, because "what would the next
 * session's tool face be" is a question that should be answerable without a
 * filesystem.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs"

/** The one builtin is always on the face and always counts (DESIGN §5.1). */
export const builtin_tools = 1

export type PinState = "always" | "session" | "other" | "composed" | "off"

/** A stable tool id, the only form a pin has: `ext:<extension-id>/<tool>`. */
export function toolId(extension: string, tool: string): string {
  return `ext:${extension}/${tool}`
}

/**
 * Where a pin can be written down, read from all three places at once. `merged`
 * is the kernel's own projection (`config show --json`); `user` is the file this
 * module writes, read separately because the projection deliberately does not
 * say which layer contributed what.
 */
export interface PinSources {
  user: readonly string[]
  session: readonly string[]
  merged: readonly string[]
  /**
   * Tools that reach the face without any pin list naming them: the model tools
   * of the packages in `[extensions] session_with` (T42). Not a place a pin is
   * WRITTEN — a place the face gets one anyway — and this panel has to know
   * about it, because a checkbox that reads `off` about a tool the model can
   * call is simply wrong.
   */
  composed?: readonly string[]
}

export function pinState(id: string, sources: PinSources): PinState {
  if (sources.user.includes(id)) return "always"
  if (sources.session.includes(id)) return "session"
  if (sources.merged.includes(id)) return "other"
  if (sources.composed?.includes(id)) return "composed"
  return "off"
}

export function stateLabel(state: PinState): string {
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
export interface PinChange {
  user: string[] | null
  session: string[] | null
  notice: string
}

const unchanged = (notice: string): PinChange => ({ user: null, session: null, notice })

function without(list: readonly string[], id: string): string[] {
  return list.filter((entry) => entry !== id)
}

function with_(list: readonly string[], id: string): string[] {
  return list.includes(id) ? [...list] : [...list, id]
}

/**
 * `Space` on a tool row.
 *
 * On goes to `session` first, always: a pin the user is trying out should not
 * edit a config file, and one they meant forever is one key further (`A`). Off
 * removes it from wherever this TUI put it — and says so plainly when the pin
 * is not ours to remove.
 */
export function toggle(id: string, sources: PinSources): PinChange {
  const state = pinState(id, sources)
  if (state === "other") {
    return unchanged(`${id} is pinned by another config layer · edit that file to change it`)
  }
  if (state === "composed") {
    return unchanged(`${id} comes with its package in every session · \`[extensions] session_with\` in tui.toml decides that`)
  }
  if (state === "always") {
    return { user: without(sources.user, id), session: null, notice: `${id} unpinned · next session` }
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
 * state for one pin, and an `always` that a later toggle appears to half-undo.
 */
export function promote(id: string, sources: PinSources): PinChange {
  const state = pinState(id, sources)
  if (state === "always") return unchanged(`${id} is already always`)
  if (state === "other") {
    return unchanged(`${id} is pinned by another config layer · edit that file to change it`)
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
 * Every tool of an extension onto this TUI's list, in one move — the pin half
 * of the `/ext` switch (tui.md §11, T22). Only ever adds: turning an extension
 * ON must not silently take a pin off something else.
 */
export function pinAll(ids: readonly string[], sources: PinSources): PinChange {
  const mine = ids.filter((id) => pinState(id, sources) === "off")
  if (mine.length === 0) return unchanged("")
  let session = sources.session
  for (const id of mine) session = with_(session, id)
  return { user: null, session: [...session], notice: "" }
}

/**
 * The other half: take an extension's tools off both lists this panel writes.
 *
 * A pin left behind by a deactivation is not harmless — a pin brings its
 * package in at `current` (DESIGN §5.1), and with no `current` the next
 * `session new` refuses (`WithVersionNotFound`) and the session simply does not
 * start — so OFF has to clear `always` too, which is the one case where this
 * module writes the config file without being asked for `A`. A pin some other
 * layer wrote still cannot be touched (D3), so it is named instead.
 */
export function unpinAll(ids: readonly string[], sources: PinSources): PinChange {
  let user = sources.user
  let session = sources.session
  const stuck: string[] = []
  for (const id of ids) {
    if (pinState(id, sources) === "other") {
      stuck.push(id)
      continue
    }
    user = without(user, id)
    session = without(session, id)
  }
  return {
    user: user === sources.user ? null : [...user],
    session: session === sources.session ? null : [...session],
    notice: stuck.length > 0 ? `${stuck.join(" ")} stays: another config layer pins it` : "",
  }
}

/**
 * Session pins that name a tool nothing on offer declares.
 *
 * `session new --pin` is resolved against the composition, so a pin whose
 * extension was rolled back or deactivated does not degrade — it refuses, and
 * the session does not start at all. The list is this TUI's own program state,
 * so the honest repair is to drop the line rather than to keep offering a
 * session that cannot open.
 */
export function orphanPins(pins: readonly string[], available: readonly string[]): string[] {
  return pins.filter((pin) => !available.includes(pin))
}

/**
 * Every tool id a STANDING pin list may name, from a store listing.
 *
 * Two conditions. The first is the kernel's: the extension has an active,
 * un-shadowed version — a pin brings its package in at `current` (DESIGN
 * §5.1), and with no `current` the session does not open. The second is this
 * front end's: the package composes into every session (`activation:
 * "always"`), because a standing pin on an `on_request` package would wear that
 * mode in every session — the exact thing the word declines (`standingPinsOf`).
 *
 * Driver tools are in: `audience` is a package's advice about whose face a tool
 * belongs on, not a rule about what may be pinned, and this pane lets a person
 * pin one on purpose. What is NOT here is what cannot resolve.
 */
export function resolvableStandingPins(
  entries: readonly {
    id: string
    tools: readonly string[]
    current: string | null
    shadowed: boolean
    activation: "always" | "on_request"
  }[],
): string[] {
  const ids: string[] = []
  for (const entry of entries) {
    if (!entry.current || entry.shadowed || entry.activation === "on_request") continue
    for (const tool of entry.tools) ids.push(toolId(entry.id, tool))
  }
  return ids
}

/**
 * The quota line. `max_tools` counts the builtin (DESIGN §5.1), so it is shown
 * rather than hidden — a face of 8 that already spends 1 is the fact behind
 * every "why was my pin refused".
 *
 * Nothing is prevented here. Over-subscription is refused by `session new`, and
 * the panel repeats the kernel's own sentence rather than predicting it.
 */
export function quotaLine(maxTools: number, pinned: number): string {
  const line = `tools ${builtin_tools}+${pinned}/${maxTools}`
  if (builtin_tools + pinned <= maxTools) return line
  const over = builtin_tools + pinned - maxTools
  return `${line} · ${over} more than registry.max_tools allows · unpin ${
    over === 1 ? "one" : `${over}`
  } in the tools pane, or no session will start`
}

/**
 * The face is full and a batch of pins did not fit — in a sentence somebody can
 * act on, rather than in the gauge's arithmetic (`2+9/8 · nothing changed` was
 * the whole explanation a person got for pressing Enter and seeing nothing
 * happen, tui.md §11, T23).
 *
 * It is not a refusal. Membership and pins are two axes: an extension can be
 * active with none of its tools on the native face, and `nulya ext run` reaches
 * them there — which is exactly how `/compact` has always called `compact`.
 */
export function faceFullLine(maxTools: number, face: number, left: number): string {
  return `tool face is full at ${builtin_tools}+${face}/${maxTools} · ${left} tool${
    left === 1 ? "" : "s"
  } not pinned · Space in the tools pane frees a slot; ext run reaches them either way`
}

// --- the user config file ---------------------------------------------------

const registry_table = "registry"
const pinned_key = "pinned_native_tools"

/** `pinned_native_tools` as the USER file writes it — not the merged chain. */
export function readUserPins(path: string): string[] {
  if (!existsSync(path)) return []
  try {
    return pinsOf(Bun.TOML.parse(readFileSync(path, "utf8")))
  } catch {
    // A config the TUI cannot parse is not an empty config, but it is also not
    // ours to repair; `writeUserPins` re-reads and refuses rather than
    // flattening a file it did not understand.
    return []
  }
}

export function pinsOf(parsed: unknown): string[] {
  if (typeof parsed !== "object" || parsed === null) return []
  const registry = (parsed as Record<string, unknown>)[registry_table]
  if (typeof registry !== "object" || registry === null) return []
  const pins = (registry as Record<string, unknown>)[pinned_key]
  return Array.isArray(pins) ? pins.filter((entry): entry is string => typeof entry === "string") : []
}

function renderPins(pins: readonly string[]): string {
  return `${pinned_key} = [${pins.map((pin) => JSON.stringify(pin)).join(", ")}]`
}

/** A `[table]` or `[[array]]` header line, and the name it opens. */
function tableOf(line: string): string | null {
  const match = /^\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*$/.exec(line)
  return match ? match[1]! : null
}

/** Brackets outside of quotes, so a pin containing `]` cannot end the array. */
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
 * Replace (or add) exactly the `pinned_native_tools` line, leaving every other
 * byte of the file alone (D3).
 *
 * Re-serialising the parsed document would be one line of code and would throw
 * away the comments and the ordering somebody wrote by hand — a config file is
 * a person's own text, and a program that owns one key in it does not get to
 * reformat the rest. The array may span lines, so the span is found by counting
 * brackets outside strings rather than by assuming one line.
 */
export function setPinnedTools(text: string, pins: readonly string[]): string {
  const trailing = text.length > 0 && !text.endsWith("\n") ? "" : "\n"
  const lines = text.length === 0 ? [] : text.replace(/\n$/, "").split("\n")
  const rendered = renderPins(pins)

  let table: string | null = null
  let sectionStart = -1
  let sectionEnd = -1
  for (let i = 0; i < lines.length; i++) {
    const opened = tableOf(lines[i]!)
    if (opened !== null) {
      if (table === registry_table && sectionEnd < 0) sectionEnd = i
      table = opened
      if (table === registry_table && sectionStart < 0) sectionStart = i
      continue
    }
    if (table !== registry_table) continue
    if (!new RegExp(`^\\s*${pinned_key}\\s*=`).test(lines[i]!)) continue
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
  return [...head, `[${registry_table}]`, rendered].join("\n") + trailing
}

/**
 * Write the pins, then read them back and check.
 *
 * The check is the point: this edits a file by text surgery, and a surgery that
 * silently produced something the kernel reads differently would show a tool as
 * pinned that no session ever carries. On disagreement the original bytes go
 * back and the caller hears about it.
 */
export function writeUserPins(path: string, pins: readonly string[]): void {
  const before = existsSync(path) ? readFileSync(path, "utf8") : ""
  const after = setPinnedTools(before, pins)
  writeFileSync(path, after)
  let round: string[]
  try {
    round = pinsOf(Bun.TOML.parse(readFileSync(path, "utf8")))
  } catch (error) {
    writeFileSync(path, before)
    throw new Error(`${path} would not parse after the edit; nothing changed (${String(error)})`)
  }
  if (round.length !== pins.length || round.some((pin, at) => pin !== pins[at])) {
    writeFileSync(path, before)
    throw new Error(`${path} did not read back as written; nothing changed`)
  }
}
