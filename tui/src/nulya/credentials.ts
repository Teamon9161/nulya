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
 * Where the block that starts at `at` ends — just past its own `# nulya: end`
 * line — or null when it has none.
 *
 * A block written here carries no comment but that closing line, so the search
 * stops at the first `#` after the marker: an end line found past somebody
 * else's comment, or past a later block's marker, would not be this block's.
 *
 * Null is the honest answer for a block an older build wrote, and the caller
 * leaves such a block exactly where it is. Which lines under an unmarked block
 * were ours is not knowable — the file is the person's, they may have added a
 * field to the table we opened — and a config file does not need it known:
 * same-name profiles merge field by field within a layer and roles merge by
 * name, so a block appended at the end overrides the old one where they
 * disagree, and the next write finds the marked one and replaces it exactly.
 */
function blockEnd(text: string, at: number): number | null {
  let nl = text.indexOf("\n", at)
  while (nl >= 0) {
    const start = nl + 1
    nl = text.indexOf("\n", start)
    const line = (nl < 0 ? text.slice(start) : text.slice(start, nl)).trim()
    if (line.startsWith("#")) return line === end_marker ? (nl < 0 ? text.length : nl + 1) : null
  }
  return null
}

/**
 * Put `block` in `text` under `marker`: replacing the marked block already
 * there, else appended after a blank line. The LAST such marker, so the block
 * this file wrote most recently is the one it keeps rewriting.
 */
export function placeBlock(text: string, marker: string, block: string): string {
  const at = text.lastIndexOf(marker)
  const end = at < 0 ? null : blockEnd(text, at)
  if (end !== null) return text.slice(0, at) + block + text.slice(end)
  let head = text
  if (head.length > 0 && !head.endsWith("\n")) head += "\n"
  if (head.length > 0) head += "\n"
  return head + block
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
