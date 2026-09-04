/**
 * The two things the TUI writes into the kernel's user config: a profile's
 * `api_key` (pasted in `/model`), and a whole profile for an OpenAI- or
 * Anthropic-compatible endpoint the person adds there.
 *
 * The file is the person's — hand-written, commented — so it is never
 * rewritten. What we add lands as a small block at the end, marked so it can be
 * found and REPLACED next time (a rotated key does not pile up), and so the
 * person can see who wrote it and delete it freely:
 *
 *     # nulya: api_key for profile "deepseek" (written by the TUI; edit or delete freely)
 *     [[provider.profiles]]
 *     name = "deepseek"
 *     api_key = "…"
 *     # nulya: end
 *
 * That is legal because the kernel merges same-name profiles within a layer in
 * order (`config.zig` `upsertProfile`): the block overlays only the fields it
 * names on whatever the profile already is, and a name nobody used yet becomes
 * a new profile. Nothing else in the file is touched.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"

function keyMarker(profile: string): string {
  return `# nulya: api_key for profile "${profile}" (written by the TUI; edit or delete freely)`
}

function profileMarker(profile: string): string {
  return `# nulya: profile "${profile}" (added in /model; edit or delete freely)`
}

/** A TOML basic string: only `\` and `"` need escaping in a key. */
function tomlString(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`
}

/** Profile names are TOML-visible; keep the block unambiguous. */
export function validProfileName(name: string): boolean {
  return /^[A-Za-z0-9_.-]+$/.test(name)
}

/**
 * The same grammar a persona name has (`defs.isPlainName`), because a persona
 * that names no model rides a rung called after itself — so anything the
 * picker can offer has to be something this file can write. A dot is legal
 * there, which is why the key is always QUOTED below: bare, `a.b = {…}` would
 * be a table named `a` holding `b`, not a rung called `a.b`.
 */
export function validRungName(name: string): boolean {
  return name.length <= 64 && /^[A-Za-z0-9_-][A-Za-z0-9_.-]*$/.test(name)
}

function rungMarker(profile: string, rung: string): string {
  return `# nulya: rung "${rung}" on profile "${profile}" (written by the TUI; edit or delete freely)`
}

export function rungBlock(profile: string, rung: string, model: string, effort?: string): string {
  const dial = effort && effort.length > 0 ? `, effort = ${tomlString(effort)}` : ""
  return close([
    rungMarker(profile, rung),
    "[[provider.profiles]]",
    `name = ${tomlString(profile)}`,
    "[provider.profiles.roles]",
    `${tomlString(rung)} = { model = ${tomlString(model)}${dial} }`,
  ])
}

export function keyBlock(profile: string, key: string): string {
  return close([
    keyMarker(profile),
    "[[provider.profiles]]",
    `name = ${tomlString(profile)}`,
    `api_key = ${tomlString(key)}`,
  ])
}

/** What `/model`'s add-provider form collected. `key` empty = rely on `api_key_env`. */
export interface ProfileDraft {
  name: string
  kind: "openai" | "anthropic"
  base_url: string
  models: string[]
  key?: string
  api_key_env?: string
}

export function profileBlock(draft: ProfileDraft): string {
  const lines = [
    profileMarker(draft.name),
    "[[provider.profiles]]",
    `name = ${tomlString(draft.name)}`,
    `kind = ${tomlString(draft.kind)}`,
    `base_url = ${tomlString(draft.base_url)}`,
  ]
  if (draft.models.length > 0) {
    lines.push(`model = ${tomlString(draft.models[0]!)}`)
    lines.push(`models = [${draft.models.map(tomlString).join(", ")}]`)
  }
  if (draft.api_key_env && draft.api_key_env.length > 0) lines.push(`api_key_env = ${tomlString(draft.api_key_env)}`)
  if (draft.key && draft.key.length > 0) lines.push(`api_key = ${tomlString(draft.key)}`)
  return close(lines)
}

/** The line that closes a block written here: the block's own end, stated. */
const end_marker = "# nulya: end"

/** A block is its lines, its closing line, and a trailing newline. */
function close(lines: readonly string[]): string {
  return `${[...lines, end_marker].join("\n")}\n`
}

/**
 * How much of `rest` — which begins at a marker line — was written here.
 *
 * A block carries its own `# nulya: end`, so the answer is exact: the file is
 * the person's to edit, and nothing they wrote underneath — with or without a
 * blank line between — can be taken for ours. A block with no end line was
 * written by an older build; it is bounded instead by the first line this file
 * would never emit (blank, a comment, or a table header that is not one of the
 * two below), and the rewrite gives it an end line.
 */
function ownedLength(rest: string): number {
  const lines = rest.split("\n")
  let used = Math.min(lines[0]!.length + 1, rest.length)
  for (const line of lines.slice(1)) {
    if (line.trim() === end_marker) return Math.min(used + line.length + 1, rest.length)
    if (!ourLine(line)) return used
    used = Math.min(used + line.length + 1, rest.length)
  }
  return rest.length
}

function ourLine(line: string): boolean {
  const t = line.trim()
  if (t.length === 0 || t.startsWith("#")) return false
  if (t.startsWith("[")) return t === "[[provider.profiles]]" || t === "[provider.profiles.roles]"
  return true
}

/**
 * Put `block` in `text` under `marker`: replacing what is already there, else
 * appended after a blank line.
 */
export function placeBlock(text: string, marker: string, block: string): string {
  const at = text.indexOf(marker)
  if (at < 0) {
    let head = text
    if (head.length > 0 && !head.endsWith("\n")) head += "\n"
    if (head.length > 0) head += "\n"
    return head + block
  }
  const rest = text.slice(at)
  return text.slice(0, at) + block + rest.slice(ownedLength(rest))
}

function write(path: string, text: string): string {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, text, { mode: 0o600 })
  return text
}

function read(path: string): string {
  return existsSync(path) ? readFileSync(path, "utf8") : ""
}

/**
 * Write (or replace) one rung of `profile`'s team.
 *
 * One block per rung, each with its own marker, so re-pointing `explore` cannot
 * disturb `review` — and so a person can delete exactly the one they no longer
 * want. The block names the profile and nothing else about it: same-name
 * profiles merge field by field within a layer, and a profile's `roles` merge
 * rung by rung, so everything the person wrote about that endpoint survives.
 *
 *     # nulya: rung "explore" on profile "openai" (written by the TUI; edit or delete freely)
 *     [[provider.profiles]]
 *     name = "openai"
 *     [provider.profiles.roles]
 *     "explore" = { model = "gpt-5.6-luna", effort = "low" }
 *     # nulya: end
 *
 * `effort` is written only when the dial was on a rung of its own, because an
 * absent effort and a chosen one are different instructions to the kernel.
 */
export function writeRung(path: string, profile: string, rung: string, model: string, effort?: string): string {
  if (!validProfileName(profile)) throw new Error(`profile name '${profile}' cannot be written to config`)
  if (!validRungName(rung)) throw new Error(`a rung is named like a sub-agent is (got '${rung}')`)
  if (model.trim().length === 0) throw new Error("a rung names a model")
  return write(path, placeBlock(read(path), rungMarker(profile, rung), rungBlock(profile, rung, model.trim(), effort)))
}

/**
 * Write (or replace) the key block for `profile` in the config file at `path`.
 * Creates the file and its directory when absent. Returns the text written.
 */
export function writeProfileKey(path: string, profile: string, key: string): string {
  if (!validProfileName(profile)) throw new Error(`profile name '${profile}' cannot be written to config`)
  const trimmed = key.trim()
  if (trimmed.length === 0) throw new Error("empty key")
  return write(path, placeBlock(read(path), keyMarker(profile), keyBlock(profile, trimmed)))
}

/**
 * Write (or replace) a whole profile — the compatible endpoint somebody added
 * in `/model`. Its key rides in the same block: a profile the person typed in
 * one sitting should not leave half of itself somewhere else.
 */
export function writeProfile(path: string, draft: ProfileDraft): string {
  if (!validProfileName(draft.name)) throw new Error(`profile name '${draft.name}' cannot be written to config`)
  if (draft.base_url.trim().length === 0) throw new Error("a compatible provider needs a base URL")
  if (draft.models.length === 0) throw new Error("a compatible provider needs at least one model id")
  return write(path, placeBlock(read(path), profileMarker(draft.name), profileBlock(draft)))
}
