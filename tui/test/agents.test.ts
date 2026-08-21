/**
 * Agent definitions (tui.md §5.10): the file, the prompt it becomes, and the
 * ceiling a read-only one runs under.
 *
 * The pure half is the parser and the two policies; the rest runs the real
 * binary, because "a definition becomes a session's own system prompt" is only
 * true if `nulya session new --prompt` says so.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import {
  agentAnswerFor,
  agentPick,
  agentsDirOf,
  buildAgentPackage,
  listAgents,
  renderAgent,
  planProjectAgents,
  readonlyCeiling,
  usableAgents,
} from "../src/agents.ts"
import { samePath } from "../src/extensions.ts"
import { loadTuiState, rememberAgentsAnswer } from "../src/state/tui_state.ts"
import { tempWorkspace, type TempWorkspace } from "./support.ts"


/**
 * A home of this file's own. These tests build the bundled `agent` package, and
 * a bundled package builds into the USER store — which `test/isolate.ts` points
 * at one scratch directory for the whole run. Without this, `/ext`'s assertions
 * in another file would find an `agent` row nobody put there (the same accident
 * T21 records, one package later).
 */
const shared_home = process.env["NULYA_HOME"]

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
  process.env["NULYA_HOME"] = join(ws.dir, "home")
})

afterAll(() => {
  if (shared_home) process.env["NULYA_HOME"] = shared_home
  ws.cleanup()
})

function writeDef(dir: string, name: string, text: string): void {
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, `${name}.md`), text)
}

const explore = `---
name: explore
description: Read-only reconnaissance that returns a report
readonly: true
model: scripted/scripted-demo
max_steps: 12
---
You are a read-only exploration specialist. Report what you found.
`

/**
 * The definition FORMAT has one reader and it is not this side (`agents.ts`):
 * the package parses, this asks it. So what is tested here is the asking — the
 * shape that comes back, the layering it reports, and the two policies that are
 * genuinely the front end's (the trust question, the read-only ceiling).
 */
test("list is the one reading: three layers in search order, with what an earlier layer shadows marked", async () => {
  writeDef(agentsDirOf(ws, "workspace"), "explore", explore)
  writeDef(agentsDirOf(ws, "user"), "review", "---\ndescription: a reviewer\n---\nreview things\n")
  writeDef(agentsDirOf(ws, "workspace"), "broken", "no front matter here\n")

  const pkg = await buildAgentPackage(ws)
  const all = await listAgents(ws, pkg)
  const usable = usableAgents(all)

  // The workspace's `explore` wins; the builtin of that name is still listed.
  const mine = usable.find((entry) => entry.name === "explore")!
  expect(mine.layer).toBe("workspace")
  expect(mine.readonly).toBe(true)
  expect(mine.max_steps).toBe(12)
  expect(mine.profile).toBe("scripted")
  expect(mine.model).toBe("scripted-demo")
  const shadowed = all.find((entry) => entry.name === "explore" && entry.layer === "builtin")!
  expect(shadowed.shadowed).toBe(true)
  expect(usable.some((entry) => entry.name === "explore" && entry.layer === "builtin")).toBe(false)

  // The user layer is there, and so are the personas nobody installed.
  expect(usable.find((entry) => entry.name === "review")!.layer).toBe("user")
  for (const name of ["general", "plan"]) {
    const builtin = usable.find((entry) => entry.name === name)!
    expect(builtin.layer).toBe("builtin")
    expect(builtin.description.length).toBeGreaterThan(0)
    expect(builtin.pins.every((pin) => pin.startsWith("ext:std/"))).toBe(true)
  }
  // A file that is not a definition is simply not one.
  expect(all.some((entry) => entry.name === "broken")).toBe(false)
}, 300_000)

/** Nothing written anywhere: the personas that ship with the package are enough. */
test("a workspace with no definition files still has the personas the package ships", async () => {
  const bare = tempWorkspace()
  const mine = process.env["NULYA_HOME"]
  process.env["NULYA_HOME"] = join(bare.dir, "home")
  try {
    const pkg = await buildAgentPackage(bare)
    const found = usableAgents(await listAgents(bare, pkg))
    expect(found.map((entry) => entry.name).sort()).toEqual(["explore", "general", "orchestrator", "plan"])
    // Exactly one of them may delegate; the rest are leaves, which is what makes
    // a delegated session carry the `agent` tool or not (DESIGN §7.8).
    const coordinators = found.filter((entry) => entry.agents.length > 0)
    expect(coordinators.map((entry) => entry.name)).toEqual(["orchestrator"])
    expect(coordinators[0]!.max_exchanges).toBeGreaterThan(0)
    expect(found.filter((entry) => entry.readonly).map((entry) => entry.name)).toEqual(["explore"])
  } finally {
    if (mine) process.env["NULYA_HOME"] = mine
    bare.cleanup()
  }
}, 300_000)

// ── rendering ───────────────────────────────────────────────────────────────

/**
 * Turning a definition into the prompt a session wears lives in ONE place — the
 * bundled `agent` package's `render` tool — so the front end and the model's own
 * `agent` tool can never disagree about what a persona is. This exercises the
 * real package against the real binary rather than a second copy of the
 * rendering.
 */
test("render writes a definition's body to a file a session can wear, installs nothing, and reports what it asks of a session", async () => {
  const dir = agentsDirOf(ws, "workspace")
  mkdirSync(dir, { recursive: true })
  writeFileSync(
    join(dir, "probe.md"),
    "---\nname: probe\ndescription: a prober\nreadonly: true\nmax_steps: 4\npins: [nonsense]\n---\nfirst prompt\n",
  )
  const pkg = await buildAgentPackage(ws)
  expect(pkg.id).toBe("agent")

  const first = await renderAgent(ws, pkg, "probe")
  expect(first.label).toBe("agent-probe")
  expect(first.readonly).toBe(true)
  expect(first.max_steps).toBe(4)
  // A pin the kernel could not resolve refuses the whole `session new`, so a
  // malformed one is dropped before it can, and said out loud.
  expect(first.pins).toEqual([])
  expect(first.members).toEqual([])
  expect(first.warnings.some((line: string) => line.includes("nonsense"))).toBe(true)
  expect(agentPick(first)).toBeUndefined()

  // The body is on disk, under the label, for `session new --prompt` to read —
  // and NOTHING was installed: no package, so nothing in `/ext` and nothing an
  // `ext prune` could take away from a resume.
  expect(readFileSync(join(ws.dir, first.prompt), "utf8").trim()).toBe("first prompt")
  expect(existsSync(join(ws.dir, ".nulya/extensions/agent-probe"))).toBe(false)

  // Content-determined: rendering an unedited definition is the same file, so a
  // delegation can render every time.
  expect((await renderAgent(ws, pkg, "probe")).prompt).toBe(first.prompt)

  // An edit rewrites it, with no command to remember.
  writeFileSync(join(dir, "probe.md"), "---\nname: probe\nmodel: scripted/scripted-demo\n---\nsecond prompt\n")
  const edited = await renderAgent(ws, pkg, "probe")
  expect(readFileSync(join(ws.dir, edited.prompt), "utf8").trim()).toBe("second prompt")
  expect(edited.readonly).toBe(false)
  expect(agentPick(edited)).toEqual({ profile: "scripted", model: "scripted-demo" })

  // A persona whose pins name a package this workspace cannot bring in is
  // refused BEFORE a session exists, and the message is the way out — the pins
  // would otherwise be handed to a `session new` that can only say no.
  writeFileSync(join(dir, "needy.md"), "---\nname: needy\npins: [ext:std/read]\n---\nI need std\n")
  await expect(renderAgent(ws, pkg, "needy")).rejects.toThrow(/not built here: std/)

  // An unknown name is refused by the same tool, with the names there are.
  await expect(renderAgent(ws, pkg, "not-a-thing")).rejects.toThrow(/no agent 'not-a-thing'/)
}, 300_000)

// ── the read-only ceiling ───────────────────────────────────────────────────

test("a read-only agent gets no shell and only tools that declare themselves read-only", () => {
  // `shell` is refused whatever any table says: without a sandbox nothing can
  // tell `cat foo` from `rm foo`.
  expect(readonlyCeiling("shell", undefined)).toContain("cannot run shell")
  // A tool that made no claim has not claimed to be read-only (DESIGN §7.2.1).
  expect(readonlyCeiling("write", undefined)).toContain("does not declare itself read-only")
  expect(readonlyCeiling("write", false)).toContain("does not declare itself read-only")
  expect(readonlyCeiling("read", true)).toBeNull()
})

// ── the question a checkout's definitions have to pass ──────────────────────

test("the checkout's definitions are asked about once, and never the machine's", () => {
  const dir = "/w/.nulya/agents"
  // File NAMES, not readings: the question is asked before anything is built,
  // and what it asks about is "did a definition arrive with this clone".
  const defs = ["explore", "review"]
  expect(planProjectAgents(dir, [], false, [], samePath).kind).toBe("none")
  expect(planProjectAgents(dir, defs, true, [], samePath).kind).toBe("ready")

  const asked = planProjectAgents(dir, defs, false, [], samePath)
  expect(asked.kind).toBe("ask")
  expect(asked.kind === "ask" && asked.names).toEqual(["explore", "review"])
  // Answered once — either way. "not now" must not become a question every
  // morning; `t` is the only thing that also grants.
  expect(planProjectAgents(dir, defs, false, [dir], samePath).kind).toBe("none")
  expect(planProjectAgents(dir, defs, false, ["/w/.nulya/agents/"], samePath).kind).toBe("none")

  expect(agentAnswerFor("t")).toBe(true)
  expect(agentAnswerFor("n")).toBe(false)
  expect(agentAnswerFor("escape")).toBe(false)
  // Anything else is not an answer: a terminal reply or a stray byte used to be
  // read as "no", silently, once, never to be asked again.
  expect(agentAnswerFor("q")).toBeNull()
})

test("the answer is remembered, and only a yes records trust", () => {
  const path = join(ws.dir, "state-agents.json")
  rmSync(path, { force: true })
  rememberAgentsAnswer("/w/one", false, path)
  expect(loadTuiState(path).asked_agents).toEqual(["/w/one"])
  expect(loadTuiState(path).trusted_agents ?? []).toEqual([])
  rememberAgentsAnswer("/w/two", true, path)
  expect(loadTuiState(path).asked_agents).toEqual(["/w/one", "/w/two"])
  expect(loadTuiState(path).trusted_agents).toEqual(["/w/two"])
  // Twice is once: the lists are sets, not a log.
  rememberAgentsAnswer("/w/two", true, path)
  expect(loadTuiState(path).asked_agents).toEqual(["/w/one", "/w/two"])
  expect(loadTuiState(path).trusted_agents).toEqual(["/w/two"])
})
