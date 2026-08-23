/**
 * Who answers the kernel's gate, and how (tui.md §5.7).
 *
 * `nulya session step --gate --stream` asks before every tool call and runs only
 * what it is allowed to (DESIGN §4/§14). The kernel has exactly one semantic
 * there — allow, or deny with a note — and nothing else: WHICH calls are worth
 * asking a person about is policy, and policy lives here, in the driver, where
 * it can be replaced without touching the kernel (physics #8).
 *
 * The decision is a pure function of four things, asked in this order:
 *
 *   1. the `deny` table — a standing "never". It outranks everything, including
 *      the session's own always-list: a call that is denied by rule is never
 *      shown to anybody, so it can never have got onto that list in the first
 *      place, and reading the two the other way round would make "never" mean
 *      "unless you once said yes to something like it".
 *   2. this session's always-list — the `a` key on an approval card. In memory,
 *      per run: trying something out must not write a file somebody else reads.
 *   3. the `ask` table — a deliberate checkpoint. It prompts even in `unsafe`,
 *      which is the whole reason it exists as its own table rather than as the
 *      absence of an `allow` entry.
 *   4. the `allow` table, then the manifest's `readonly` claim, then the mode.
 *
 * The `readonly` claim is a HINT, not a boundary (DESIGN §9): the package says
 * its tool only reads, the kernel records that and enforces nothing, and a
 * driver that believes it is choosing to. `[approvals] manifest_readonly = false`
 * stops believing it — the key stays, because what it configures is belief, not
 * where the claim comes from.
 *
 * Where it comes from is the gate request itself (DESIGN §4): the kernel freezes
 * the claim into the tool definition at composition time and puts it, with the
 * stable id, on the line it asks with. Nothing here opens a manifest.
 */
import type { Contributions } from "./nulya/files.ts"

/**
 * What the kernel asks about: one call exactly as the model wrote it, plus the
 * two facts this session froze about the tool it names (DESIGN §4).
 *
 * Both frozen columns arrive on the wire. They used to be re-derived here from
 * the composition's manifests — which package is this name from, does that
 * package claim it only reads — and a derivation the kernel could simply hand
 * over is one more place to be wrong about a permission.
 */
export interface GateRequest {
  call_id: string
  /** The model-facing tool NAME (`shell`, `read`) — the tool face's own word. */
  tool: string
  /** The stable id (`ext:<id>/<tool>`), or null for a name this session has no tool for. */
  tool_id: string | null
  /** The manifest's `readonly` claim. `null` is "said nothing", never `false`. */
  readonly: boolean | null
  /** Raw JSON arguments, verbatim. */
  args: string
}

/** The two answers the wire has, and the third only this side knows about. */
export type Decision = "allow" | "deny" | "ask"

/**
 * The permission mode: what happens to a call no rule has an opinion about.
 *
 * `unsafe`, not `auto`, and the name is the honest one. tcode has four modes and
 * its `Auto` is a CLASSIFIER — a second model reviews each routine action and
 * only the boring ones go through. nulya has no classifier and is not getting
 * one; this mode runs whatever the model wrote, unreviewed, with only the
 * standing `deny` / `ask` tables in the way. That is tcode's `Unsafe`, and
 * calling it `auto` promised a judgement nothing here makes.
 */
export type PermissionMode = "ask" | "unsafe"

export const modes: PermissionMode[] = ["ask", "unsafe"]

export function isMode(word: string): word is PermissionMode {
  return (modes as string[]).includes(word)
}

/**
 * A mode word from OUTSIDE this process — `tui-state.json`, `tui.toml`, a
 * `/mode` argument — or null when it names no mode at all.
 *
 * `auto` was this mode's name until it was renamed, so it is read as `unsafe`
 * here and written back under the new name: a person who chose it yesterday
 * keeps what they chose, and a `tui.toml` written for an older build keeps
 * working. One place does the translation, so no reader learns the old word.
 */
export function normalizeMode(word: string): PermissionMode | null {
  const trimmed = word.trim()
  if (trimmed === "auto") return "unsafe"
  return isMode(trimmed) ? trimmed : null
}

/**
 * The three tables and the one switch, as `tui.toml` spells them. Entries are
 * either a tool (`ext:std/read`, `shell`, `edit`) or a shell command prefix
 * (`shell:git status`).
 */
export interface ApprovalRules {
  allow: string[]
  ask: string[]
  deny: string[]
  /** Trust a tool's own `"readonly": true` (DESIGN §7.2.1). */
  manifest_readonly: boolean
}

export const default_rules: ApprovalRules = { allow: [], ask: [], deny: [], manifest_readonly: true }

export interface ApprovalContext {
  mode: PermissionMode
  rules: ApprovalRules
  /** Keys the `a` key has collected this session (`alwaysKey`). */
  always: ReadonlySet<string>
}

/**
 * A composition's `contributes.policy` narrowing, folded into one answer
 * (DESIGN §7.2.1, tui-plugin D2/D3).
 *
 * One question, because the manifest now asks one: which member(s) claimed
 * `readonly: true`. Naming them is what makes the gate's eventual deny note
 * legible — "the read-only policy of `plan`" rather than an unexplained
 * refusal — and it is the whole reason this is a list of ids rather than a
 * bool.
 *
 * There were `deny`/`ask` lists here too, pooled across members and merged
 * into `ApprovalRules` before `decide` read them. They went with the manifest
 * fields: `readonly` already answers the case that existed, and a package
 * naming individual tools in a person's approval tables was a second, weaker
 * spelling of the ceiling this one sets.
 */
export interface CompositionPolicy {
  readonlyBy: string[]
}

export const no_policy: CompositionPolicy = { readonlyBy: [] }

export function poolPolicy(contributions: readonly Pick<Contributions, "id" | "policy">[]): CompositionPolicy {
  const readonlyBy: string[] = []
  for (const c of contributions) {
    if (c.policy?.readonly === true) readonlyBy.push(c.id)
  }
  return { readonlyBy }
}

/** The `command` a `shell` call carries, or null for anything else. */
export function shellCommand(request: GateRequest): string | null {
  if (request.tool !== "shell") return null
  try {
    const args = JSON.parse(request.args) as { command?: unknown }
    return typeof args.command === "string" ? args.command : null
  } catch {
    // Half a JSON object is not a command anybody can judge. Saying "no
    // command" sends it to the human, which is the right end of the fallback.
    return null
  }
}

/**
 * The key the `a` key remembers. A tool is remembered whole; `shell` is
 * remembered by its FIRST WORD, because "always allow shell" would be "always
 * allow everything" — `git` and `rm` are not the same permission just because
 * one program runs them both.
 */
export function alwaysKey(request: GateRequest): string {
  const command = shellCommand(request)
  if (command !== null) {
    const argv0 = command.trim().split(/\s+/)[0] ?? ""
    return `shell:${argv0}`
  }
  return request.tool_id ?? request.tool
}

/** How an always-key reads on screen: `shell git`, `ext:std/write`. */
export function describeKey(key: string): string {
  return key.startsWith("shell:") ? `shell ${key.slice("shell:".length)}` : key
}

function matches(rule: string, request: GateRequest): boolean {
  const trimmed = rule.trim()
  if (trimmed.length === 0) return false
  if (trimmed.startsWith("shell:")) {
    const command = shellCommand(request)
    if (command === null) return false
    const prefix = trimmed.slice("shell:".length).trim()
    // A prefix, not a glob: `shell:git` covers `git status`, and the person who
    // wrote it does not have to learn a pattern language to say so.
    return prefix.length > 0 && command.trim().startsWith(prefix)
  }
  // Either spelling: a rule may name the tool as the model sees it, or by the
  // stable id — which is the same string whatever a session calls the tool, and
  // therefore what a person writes in a config file.
  return trimmed === request.tool_id || trimmed === request.tool
}

function anyMatch(rules: readonly string[], request: GateRequest): boolean {
  return rules.some((rule) => matches(rule, request))
}

export function decide(request: GateRequest, ctx: ApprovalContext): Decision {
  if (anyMatch(ctx.rules.deny, request)) return "deny"
  if (ctx.always.has(alwaysKey(request))) return "allow"
  if (anyMatch(ctx.rules.ask, request)) return "ask"
  if (anyMatch(ctx.rules.allow, request)) return "allow"
  // The claim, believed only because `[approvals] manifest_readonly` says to.
  // `null` (the builtin, or a package that said nothing) is not `true`.
  if (ctx.rules.manifest_readonly && request.readonly === true) return "allow"
  return ctx.mode === "unsafe" ? "allow" : "ask"
}

/** One line of preview for a card: what this call would actually do. */
export function summarize(request: GateRequest): string {
  const command = shellCommand(request)
  if (command !== null) return command.split("\n")[0] ?? ""
  // Not shell: the arguments as written, minus the object braces, are the most
  // honest short form — the TUI does not know what any given tool's fields mean.
  const args = request.args.trim()
  if (args === "{}" || args.length === 0) return ""
  return args.length > 160 ? `${args.slice(0, 157)}…` : args
}
