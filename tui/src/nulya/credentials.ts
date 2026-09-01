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

export function keyBlock(profile: string, key: string): string {
  return `${keyMarker(profile)}\n[[provider.profiles]]\nname = ${tomlString(profile)}\napi_key = ${tomlString(key)}\n`
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
  return `${lines.join("\n")}\n`
}

/**
 * Put `block` in `text` under `marker`: replacing what is already there, else
 * appended after a blank line.
 *
 * "What is already there" is the marker line through to the blank line that
 * ends it (or the end of the file) — not a fixed line count, because a profile
 * block grows and shrinks with the model list it carries.
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
  // The first blank line after the marker; everything from it on is somebody
  // else's and stays exactly as it was.
  const end = rest.search(/\n[ \t]*\n/)
  const tail = end < 0 ? "" : rest.slice(end + 1)
  return text.slice(0, at) + block + tail
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
