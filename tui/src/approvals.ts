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
 *   3. the `ask` table — a deliberate checkpoint. It prompts even in `auto`,
 *      which is the whole reason it exists as its own table rather than as the
 *      absence of an `allow` entry.
 *   4. the `allow` table, then the manifest's `readonly` claim, then the mode.
 *
 * The `readonly` claim is a HINT, not a boundary (DESIGN §9): the package says
 * its tool only reads, the kernel records that and enforces nothing, and a
 * driver that believes it is choosing to. `[approvals] manifest_readonly = false`
 * stops believing it.
 */

/** What the kernel asks about: one call, exactly as the model wrote it. */
export interface GateRequest {
  call_id: string
  /** The model-facing tool NAME (`shell`, `read`) — the tool face's own word. */
  tool: string
  /** Raw JSON arguments, verbatim. */
  args: string
}

/** The two answers the wire has, and the third only this side knows about. */
export type Decision = "allow" | "deny" | "ask"

/** The permission mode: what happens to a call no rule has an opinion about. */
export type PermissionMode = "ask" | "auto"

export const modes: PermissionMode[] = ["ask", "auto"]

export function isMode(word: string): word is PermissionMode {
  return (modes as string[]).includes(word)
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
  /**
   * The stable id of a tool name on this session's face (`ext:<id>/<tool>`), or
   * undefined for the builtin and for a name this process cannot resolve. Rules
   * may name either; the id is what a person writes in a config file, because it
   * is the same string whatever a session happens to call the tool.
   */
  idOf?: (tool: string) => string | undefined
  /** Whether the frozen manifest claims this tool only reads. */
  readonlyOf?: (tool: string) => boolean | undefined
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
export function alwaysKey(request: GateRequest, idOf?: (tool: string) => string | undefined): string {
  const command = shellCommand(request)
  if (command !== null) {
    const argv0 = command.trim().split(/\s+/)[0] ?? ""
    return `shell:${argv0}`
  }
  return idOf?.(request.tool) ?? request.tool
}

/** How an always-key reads on screen: `shell git`, `ext:std/write`. */
export function describeKey(key: string): string {
  return key.startsWith("shell:") ? `shell ${key.slice("shell:".length)}` : key
}

function matches(rule: string, request: GateRequest, id: string | undefined): boolean {
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
  return trimmed === id || trimmed === request.tool
}

function anyMatch(rules: readonly string[], request: GateRequest, id: string | undefined): boolean {
  return rules.some((rule) => matches(rule, request, id))
}

export function decide(request: GateRequest, ctx: ApprovalContext): Decision {
  const id = ctx.idOf?.(request.tool)
  if (anyMatch(ctx.rules.deny, request, id)) return "deny"
  if (ctx.always.has(alwaysKey(request, ctx.idOf))) return "allow"
  if (anyMatch(ctx.rules.ask, request, id)) return "ask"
  if (anyMatch(ctx.rules.allow, request, id)) return "allow"
  if (ctx.rules.manifest_readonly && ctx.readonlyOf?.(request.tool) === true) return "allow"
  return ctx.mode === "auto" ? "allow" : "ask"
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
