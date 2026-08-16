/**
 * The one thing the TUI writes into the kernel's user config: a profile's
 * `api_key`, pasted in `/model` (tui.md §1.2 D10).
 *
 * The file is the person's — hand-written, commented — so it is never
 * rewritten. A key lands as a small block at the end, marked so it can be
 * found and REPLACED next time (a rotated key does not pile up), and so the
 * person can see who wrote it and delete it freely:
 *
 *     # nulya: api_key for profile "deepseek" (written by the TUI; edit or delete freely)
 *     [[provider.profiles]]
 *     name = "deepseek"
 *     api_key = "…"
 *
 * That is legal because the kernel merges same-name profiles within a layer in
 * order (`config.zig` `upsertProfile`): the block overlays only `api_key` on
 * whatever the profile already is. Nothing else in the file is touched.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"

function marker(profile: string): string {
  return `# nulya: api_key for profile "${profile}" (written by the TUI; edit or delete freely)`
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
  return `${marker(profile)}\n[[provider.profiles]]\nname = ${tomlString(profile)}\napi_key = ${tomlString(key)}\n`
}

/**
 * Write (or replace) the key block for `profile` in the config file at `path`.
 * Creates the file and its directory when absent. Returns the text written.
 */
export function writeProfileKey(path: string, profile: string, key: string): string {
  if (!validProfileName(profile)) throw new Error(`profile name '${profile}' cannot be written to config`)
  const trimmed = key.trim()
  if (trimmed.length === 0) throw new Error("empty key")
  const block = keyBlock(profile, trimmed)
  let text = existsSync(path) ? readFileSync(path, "utf8") : ""
  const at = text.indexOf(marker(profile))
  if (at >= 0) {
    // Our own block: the marker line and the three lines after it, exactly as
    // `keyBlock` writes them. Anything after stays.
    const lines = text.slice(at).split("\n")
    const rest = lines.slice(4).join("\n")
    text = text.slice(0, at) + block + rest
  } else {
    if (text.length > 0 && !text.endsWith("\n")) text += "\n"
    if (text.length > 0) text += "\n"
    text += block
  }
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, text, { mode: 0o600 })
  return text
}
