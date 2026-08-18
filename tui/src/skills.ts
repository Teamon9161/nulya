/**
 * Skills as slash commands (tui.md §11, T15).
 *
 * A skill is a prompt the kernel discloses progressively: `nulya skill list`
 * names them, `nulya skill load <ref>` prints the body, and until now the only
 * way that body reached a session was the model deciding to run those commands
 * through `shell`. `/name` changes exactly one thing — WHO decides — and saves
 * the round trip that decision costs. It does not change what a skill is, and
 * the front end never picks one, rewrites one, or triggers one on its own
 * (goals/tui-panel.md D8).
 *
 * The body is appended as an ordinary `user_text` turn, wrapped in a sentinel
 * copied from tcode's `wrap_skill_echo`. The wrapper earns its place twice
 * over:
 *
 *  - the transcript can fold it back to `/name args` from the LEDGER TEXT
 *    alone, so a live turn and the same turn replayed tomorrow read identically
 *    — one parser, one format, no second source of truth;
 *  - it says the body is a repository file wearing a user message's clothes.
 *    Nothing in nulya reads that distinction today, but the turn is permanent
 *    (physics #1) and a marker added later could not reach the turns already
 *    written.
 */
import { skillList, skillLoad, type SkillEntry } from "./nulya/cli.ts"
import type { Workspace } from "./nulya/bin.ts"
import type { TranscriptItem } from "./state/session.ts"

/** tcode `SKILL_ECHO_OPEN`. Core there recognises it too; here it is the fold. */
export const skill_echo_open = "<user-skill "
const skill_echo_close = "</user-skill>"

/** tcode `clip_description`: what fits beside a name in a completion menu. */
export const description_cap = 100

export function clipDescription(text: string, cap = description_cap): string {
  const chars = [...text]
  return chars.length > cap ? `${chars.slice(0, cap).join("")}…` : text
}

function escapeAttr(s: string): string {
  return s.replaceAll("&", "&amp;").replaceAll('"', "&quot;")
}

function unescapeAttr(s: string): string {
  return s.replaceAll("&quot;", '"').replaceAll("&amp;", "&")
}

export function wrapSkillEcho(name: string, args: string, body: string): string {
  return `${skill_echo_open}name="${escapeAttr(name)}" args="${escapeAttr(args)}">\n${body}\n${skill_echo_close}`
}

/** What a transcript needs to fold the block, without re-reading the body. */
export interface SkillEcho {
  name: string
  args: string
  lines: number
}

export function parseSkillEcho(text: string): SkillEcho | null {
  if (!text.startsWith(skill_echo_open)) return null
  const rest = text.slice(skill_echo_open.length)
  const close = rest.indexOf(">")
  if (close < 0) return null
  const tag = rest.slice(0, close)
  const name = attr(tag, "name")
  if (name === null) return null
  let body = rest.slice(close + 1)
  if (body.startsWith("\n")) body = body.slice(1)
  if (body.endsWith(`\n${skill_echo_close}`)) body = body.slice(0, -(skill_echo_close.length + 1))
  else if (body.endsWith(skill_echo_close)) body = body.slice(0, -skill_echo_close.length)
  return { name, args: attr(tag, "args") ?? "", lines: countLines(body) }
}

/**
 * Lines the way Rust's `str::lines()` counts them (tcode's `body_line_count`):
 * a trailing newline ends the last line rather than starting an empty one, so a
 * file that ends properly does not read as one line longer than it is.
 */
function countLines(text: string): number {
  if (text.length === 0) return 0
  return text.replace(/\n$/, "").split("\n").length
}

function attr(tag: string, key: string): string | null {
  const needle = `${key}="`
  const start = tag.indexOf(needle)
  if (start < 0) return null
  const from = start + needle.length
  const end = tag.indexOf('"', from)
  return end < 0 ? null : unescapeAttr(tag.slice(from, end))
}

/** The head line a folded skill echo shows: `/name args · N lines`. */
export function echoSummary(echo: SkillEcho): string {
  const call = echo.args.length > 0 ? `/${echo.name} ${echo.args}` : `/${echo.name}`
  return `${call} · ${echo.lines} lines`
}

/** Whether an item is a skill echo, for the card router (mirrors `compactionMarker`). */
export function skillEchoOf(item: TranscriptItem): SkillEcho | null {
  return item.kind === "user" ? parseSkillEcho(item.text) : null
}

// --- the table ---------------------------------------------------------------

/** `/name` split from its arguments; the arguments keep their spacing. */
export function splitSlash(raw: string): { name: string; args: string } {
  const trimmed = raw.trim()
  const at = trimmed.search(/\s/)
  if (at < 0) return { name: trimmed.replace(/^\//, ""), args: "" }
  return { name: trimmed.slice(1, at), args: trimmed.slice(at).trim() }
}

export function findSkill(skills: readonly SkillEntry[], name: string): SkillEntry | null {
  return skills.find((skill) => skill.name === name) ?? null
}

/**
 * The skills a `/` menu offers, after the built-in commands.
 *
 * Built-ins win a shared name by being listed first and by being what dispatch
 * tries first: a skill cannot shadow `/model`, so installing a package can
 * never take a command away from the person using it.
 */
export function skillCompletions(skills: readonly SkillEntry[], text: string): {
  name: string
  what: string
}[] {
  if (!text.startsWith("/")) return []
  const head = text.split(/\s/)[0] ?? text
  if (head.length < text.length) {
    const exact = skills.find((skill) => `/${skill.name}` === head)
    return exact ? [{ name: `/${exact.name}`, what: clipDescription(exact.description) }] : []
  }
  return skills
    .filter((skill) => `/${skill.name}`.startsWith(head))
    .map((skill) => ({ name: `/${skill.name}`, what: clipDescription(skill.description) }))
}

/**
 * The skill catalog, cached until something could have changed it.
 *
 * `skill list` is the catalog of ACTIVE extensions across every store root, so
 * activating or deactivating one is exactly when it goes stale — which is why
 * `/ext` calls `invalidate()` rather than this module polling. Everything else
 * (a new session, a step, a pin) leaves it alone.
 */
export interface SkillTable {
  entries(): readonly SkillEntry[]
  invalidate(): void
  ready(): Promise<readonly SkillEntry[]>
}

export function createSkillTable(ws: Workspace): SkillTable {
  let entries: SkillEntry[] = []
  let pending: Promise<readonly SkillEntry[]> | null = null

  const load = () => {
    pending ??= skillList(ws)
      .then((next) => {
        entries = next
        return next as readonly SkillEntry[]
      })
      .catch(() => {
        // No binary, no skills: an empty menu, never a crash.
        return entries as readonly SkillEntry[]
      })
    return pending
  }

  void load()
  return {
    entries: () => entries,
    invalidate: () => {
      pending = null
      void load()
    },
    ready: () => load(),
  }
}

/**
 * `/name args` → the text of the user turn it becomes, or null when no skill
 * has that name (the caller then leaves the line to the model, verbatim).
 */
export async function skillTurn(
  ws: Workspace,
  skills: readonly SkillEntry[],
  raw: string,
): Promise<string | null> {
  const { name, args } = splitSlash(raw)
  const skill = findSkill(skills, name)
  if (!skill) return null
  const body = await skillLoad(ws, skill.ref)
  return wrapSkillEcho(name, args, body)
}
