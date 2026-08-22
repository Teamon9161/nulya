/**
 * Sub-agents: a definition file, a prompt, a session (tui.md §5.10).
 *
 * The kernel has no `AgentDef` and is not getting one. PLAN §3.2 settled that in
 * one sentence — **an agent is a `session new` with a particular set of
 * arguments** — and a definition is a markdown file whose front matter is that
 * set of arguments and whose body is a system prompt.
 *
 * **Neither end of that is implemented here.** The bundled `agent` package owns
 * both: `list` reads every definition all three layers hold, `render` writes one
 * body where `session new --prompt` can read it. This module spawns those two
 * and does what only a front end can — the picker, the tab, the trust question,
 * the read-only ceiling on a tab this process drives.
 *
 * Why: two PARSERS would be two answers to "is this agent read-only" — the one
 * question the ceiling below turns into a refusal. One reader, one writer, both
 * in the package that ships the builtin personas anyway.
 *
 * **Why a file and not an extension.** It used to be an extension: the body was
 * frozen into an `agent-<name>` data package and composed in with `--with`. That
 * turned per-session text into an installed artifact — visible in `/ext`, and
 * prunable out from under the resume of a session frozen on it. `session new
 * --prompt <file>` freezes the BYTES into the session header (DESIGN §3, §5),
 * which is where text with one session's lifetime belongs; nothing is installed
 * and nothing is activated, so no persona can leak into the session next door.
 */
import { readdirSync } from "node:fs"
import { join } from "node:path"
import { extBuild, extRun } from "./nulya/cli.ts"
import { bundledDraftPath } from "./extensions.ts"
import { formatWithRef } from "./evolve.ts"
import { userConfigDir } from "./state/settings.ts"
import type { WithRef } from "./evolve.ts"
import type { ModelPick } from "./state/tui_state.ts"
import type { Workspace } from "./nulya/bin.ts"

/** Where a checkout's definitions live, relative to the workspace. */
export const agents_dir = ".nulya/agents"

/** Which layer a definition came from, in search order (DESIGN §7.8). */
export type AgentLayer = "workspace" | "user" | "builtin"

/** One row of `ext run agent@<v> list` — the package's own reading of a definition. */
export interface AgentEntry {
  name: string
  description: string
  readonly: boolean
  layer: AgentLayer
  /** An earlier layer defines this name, so this copy never runs. Still listed. */
  shadowed: boolean
  /** The file it came from, or `builtin:<name>`. */
  source: string
  profile: string
  model: string
  max_steps: number
  /** Follow-up turns one delegation may take; 0 = no limit. */
  max_exchanges: number
  /** Who this persona may delegate to. Empty = a leaf, which is every persona but a coordinator. */
  agents: string[]
  pins: string[]
  warnings: string[]
}

/** The definitions directory of one file layer, as a path on this disk. */
export function agentsDirOf(
  ws: Workspace,
  layer: "workspace" | "user",
  env: Record<string, string | undefined> = process.env,
): string {
  return layer === "workspace" ? join(ws.dir, agents_dir) : join(userConfigDir(env), "agents")
}

/**
 * Every definition, in search order, shadowing already decided — the package's
 * answer, not a second reading of the files.
 */
export async function listAgents(ws: Workspace, pkg: WithRef): Promise<AgentEntry[]> {
  const call = await extRun(ws, formatWithRef(pkg), "list", {})
  if (call.code !== 0) throw new Error(said(call.stdout, call.stderr))
  let value: unknown
  try {
    value = JSON.parse(call.stdout.trim())
  } catch {
    throw new Error(`list returned no result: ${said(call.stdout, call.stderr)}`)
  }
  if (!Array.isArray(value)) return []
  return (value as AgentEntry[]).map((row) => ({
    ...row,
    description: row.description ?? "",
    readonly: row.readonly === true,
    shadowed: row.shadowed === true,
    source: row.source ?? "",
    profile: row.profile ?? "",
    model: row.model ?? "",
    max_steps: typeof row.max_steps === "number" ? row.max_steps : 0,
    max_exchanges: typeof row.max_exchanges === "number" ? row.max_exchanges : 0,
    agents: Array.isArray(row.agents) ? row.agents : [],
    pins: Array.isArray(row.pins) ? row.pins : [],
    warnings: Array.isArray(row.warnings) ? row.warnings : [],
  }))
}

/** The ones a caller may actually name: the winner of each name. */
export function usableAgents(entries: readonly AgentEntry[]): AgentEntry[] {
  return entries.filter((entry) => !entry.shadowed)
}

/**
 * Whether this CHECKOUT ships any definition files — a directory listing, and
 * deliberately not a reading.
 *
 * The trust question is asked before the screen exists and before anything is
 * built (see below), so it cannot wait on a compiled package; and it does not
 * need to, because what it asks about is "did a definition arrive with this
 * clone", which is a fact about file NAMES. Nothing here opens one: the format
 * still has exactly one reader.
 */
export function workspaceAgentFiles(ws: Workspace): string[] {
  try {
    return readdirSync(agentsDirOf(ws, "workspace"))
      .filter((name) => name.endsWith(".md") && name.length > ".md".length)
      .sort()
      .map((name) => name.slice(0, -".md".length))
  } catch {
    // No directory is no definitions — the ordinary case, not a fault.
    return []
  }
}

// ── the question a checkout's definitions have to pass ──────────────────────

export type AgentTrustPlan =
  | { kind: "none" }
  | { kind: "ready"; dir: string }
  | { kind: "ask"; dir: string; names: string[] }

/**
 * What to do about the definitions a CHECKOUT ships, from what is in the
 * directory and what this machine already answered. Pure, so the decision is
 * readable without a filesystem.
 *
 * Why there is a question at all — two reasons, and the second is the one with
 * teeth:
 *
 *  1. a definition is a SYSTEM PROMPT. Delegating to one puts a persona written
 *     by whoever wrote the checkout in front of a model with this workspace's
 *     tools (T31, the same hazard one directory over).
 *  2. delegating to one is what first BUILDS the bundled `agent` package into
 *     this workspace's extension store, and a local build into an empty store is
 *     how the kernel records trust for it (DESIGN §9). So the question must be
 *     asked before the first build, or the act of using a checkout's persona
 *     would have signed for the checkout's store on the person's behalf.
 *
 * Asked once, whatever the answer, exactly as the store question is (T11): "not
 * now" is a real answer and must not become a prompt every morning.
 */
export function planProjectAgents(
  dir: string,
  names: readonly string[],
  trusted: boolean,
  alreadyAsked: readonly string[],
  same: (a: string, b: string) => boolean,
): AgentTrustPlan {
  if (names.length === 0) return { kind: "none" }
  if (trusted) return { kind: "ready", dir }
  if (alreadyAsked.some((asked) => same(asked, dir))) return { kind: "none" }
  return { kind: "ask", dir, names: [...names] }
}

/** The two keys, and what each one does. */
export function agentAnswerFor(key: string): boolean | null {
  if (key === "t") return true
  if (key === "n" || key === "escape" || key === "return") return false
  return null
}

// ── rendering: the bundled `agent` package does it ──────────────────────────
//
// Turning a definition into the prompt file a session wears is NOT here. The
// single implementation is `extensions/agent`'s `render` tool — the same one the
// model reaches through the `agent` tool — so the front end and the model can
// never disagree about what a persona is. This side asks for it and composes the
// `session new`.

export const agent_id = "agent"

/** The draft in nulya's own tree; elsewhere the binary's embedded copy is used. */
export const agent_draft = "extensions/agent"

/** The stable tool id a session must pin for the model to reach it (DESIGN §5.1). */
export const agent_pin = "ext:agent/agent"

/**
 * Build the bundled `agent` package and name the version to compose in.
 *
 * Same shape as `/evolve`'s and the handoff package's build: a version id is the
 * hash of the draft, so an unchanged package rebuilds to the version already in
 * the store. Compiled, so the FIRST build on a machine costs a toolchain run —
 * which is why the caller starts it in the background rather than on the way
 * into a session.
 */
export async function buildAgentPackage(ws: Workspace): Promise<WithRef> {
  const draft = await bundledDraftPath(ws, agent_id, agent_draft)
  return { id: agent_id, version: await extBuild(ws, draft) }
}

/** What `render` answers: the prompt file, and the session arguments. */
export interface RenderedAgent {
  name: string
  /** The file `session new --prompt` reads the persona's body from. */
  prompt: string
  /** The label that body's system block carries (`agent-<name>`). */
  label: string
  description: string
  readonly: boolean
  layer: AgentLayer
  /** Empty means "inherit whatever asked for the delegation". */
  profile: string
  model: string
  /** 0 means the kernel's own budget. */
  max_steps: number
  max_exchanges: number
  /**
   * Who it may delegate to. Non-empty is what makes a delegated session carry
   * the `agent` package at all — one field, read in one place, deciding leaf or
   * not (DESIGN §7.8).
   */
  agents: string[]
  /**
   * The pins this persona asks for. No member list beside them: a pin brings its
   * own package into the session at `current` (DESIGN §5.1), so the `--with`
   * that used to be derived here was the same implication said twice.
   */
  pins: string[]
  /** Everything the parser found wrong that did not make the file unusable. */
  warnings: string[]
}

/**
 * Render one definition, through the package that owns that rendering.
 *
 * Called every time a delegation starts, and that is cheap and deliberate: the
 * contents are decided by the definition, so an unedited one rewrites the same
 * file and an edit is picked up without anybody running a command.
 */
export async function renderAgent(
  ws: Workspace,
  pkg: WithRef,
  name: string,
): Promise<RenderedAgent> {
  const call = await extRun(ws, formatWithRef(pkg), "render", { name })
  if (call.code !== 0) throw new Error(said(call.stdout, call.stderr))
  let value: unknown
  try {
    value = JSON.parse(call.stdout.trim())
  } catch {
    throw new Error(`render returned no result: ${said(call.stdout, call.stderr)}`)
  }
  const m = value as Partial<RenderedAgent>
  if (typeof m.prompt !== "string" || m.prompt.length === 0) {
    throw new Error(`render returned no prompt file: ${said(call.stdout, call.stderr)}`)
  }
  return {
    name: m.name ?? name,
    prompt: m.prompt,
    label: m.label ?? `agent-${m.name ?? name}`,
    description: m.description ?? "",
    readonly: m.readonly === true,
    layer: m.layer === "workspace" || m.layer === "user" ? m.layer : "builtin",
    profile: m.profile ?? "",
    model: m.model ?? "",
    max_steps: typeof m.max_steps === "number" ? m.max_steps : 0,
    max_exchanges: typeof m.max_exchanges === "number" ? m.max_exchanges : 0,
    agents: Array.isArray(m.agents) ? m.agents.filter((a): a is string => typeof a === "string") : [],
    pins: Array.isArray(m.pins) ? m.pins.filter((p): p is string => typeof p === "string") : [],
    warnings: Array.isArray(m.warnings) ? m.warnings.filter((w): w is string => typeof w === "string") : [],
  }
}

/** The first line of whatever the call said — `ext run` prints the extension's own error on stdout. */
function said(stdout: string, stderr: string): string {
  const text = stdout.trim() || stderr.trim() || "no output"
  return text.split("\n")[0]!
}

/**
 * The `session new` model arguments a rendered definition asks for, or undefined
 * when it asks for none — and then the caller's own pick stands: a persona that
 * does not care which model runs it should not silently move the work onto
 * whatever the kernel's default happens to be.
 */
export function agentPick(m: RenderedAgent): ModelPick | undefined {
  if (m.profile.length === 0) return undefined
  return { profile: m.profile, ...(m.model.length > 0 ? { model: m.model } : {}) }
}

// ── the read-only ceiling ───────────────────────────────────────────────────

/**
 * What a `readonly: true` agent — or, since tui-plugin D3, a
 * `contributes.policy.readonly: true` package that is a member of this
 * session's frozen composition — may call, decided before any approval table
 * (tui.md §5.10, agents-and-review §1 invariant 1, goals/tui-plugin.md D3).
 *
 * A ceiling, not a rule: it is asked first and nothing can lift it, because the
 * alternative — a `[approvals] allow` entry quietly re-admitting `shell` to a
 * read-only persona — is the one shape of this feature that would be a lie. The
 * two answers are the two halves of the same sentence:
 *
 *  - `shell` runs an arbitrary command. Without an OS sandbox nothing can tell
 *    `cat foo` from `rm foo` (agents-and-review §1 invariant 5), so a read-only
 *    agent does not get it, full stop.
 *  - an extension tool is admitted only where its own frozen manifest says
 *    `"readonly": true` (DESIGN §7.2.1). That is the package's claim about
 *    itself and the kernel enforces none of it — believing it is a choice this
 *    policy makes, and `[approvals] manifest_readonly = false` is where somebody
 *    who does not want to believe it says so for the ordinary path.
 *
 * `subject` names WHO is read-only in the note the model reads — an agent
 * persona or a package's own policy are two different origins for the exact
 * same claim, and the judgment above is written once for both of them (D3:
 * "两个天花板一处判断，绝不写第二份") while the wording still says which one
 * fired. Returns the note the model is told, or null when the call may go on
 * to the ordinary decision.
 */
export function readonlyCeiling(tool: string, readonly: boolean | undefined, subject = "read-only agent"): string | null {
  if (tool === "shell") {
    return `this is a ${subject}: it cannot run shell commands. Answer from what you can read.`
  }
  if (readonly === true) return null
  return `this is a ${subject}: '${tool}' does not declare itself read-only, so it cannot run here. Use the tools that only read.`
}

