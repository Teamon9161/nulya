/**
 * `/agent` on screen (tui.md §5.10), against the real binary.
 *
 * The pure halves — parsing a definition, the prompt it becomes, the ceiling —
 * are `agents.test.ts`. What is left, and what only a real run can show, is that
 * a definition ends up being **a session with a particular set of arguments**:
 * its own tab, its own ledger, wearing its own prompt, and — for a read-only one
 * — a tool face the gate holds to what the definition said.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { createStyle } from "../src/render/theme.ts"
import { sessionEvents, sessionList } from "../src/nulya/cli.ts"
import type { LedgerEvent, ToolResultEntry } from "../src/nulya/ledger.ts"
import { agentsDirOf } from "../src/agents.ts"
import {
  scripted_env,
  settle,
  statusLine,
  tempWorkspace,
  unsafe_settings,
  until,
  type TempWorkspace,
} from "./support.ts"

// `unsafe_settings` keeps both bundled packages out of every other test's
// workspace; this file is the one that is ABOUT the agent package, so it asks
// for it back.
const style = createStyle(
  { ...unsafe_settings, extensions: { ...unsafe_settings.extensions, session_with: ["agent"] } },
  {},
)


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
  const dir = agentsDirOf(ws, "workspace")
  mkdirSync(dir, { recursive: true })
  // Read-only, so the scripted provider's one `shell` call meets the ceiling.
  writeFileSync(
    join(dir, "probe.md"),
    "---\ndescription: a read-only prober\nreadonly: true\nmax_steps: 2\n---\nYou only read. Report what you found.\n",
  )
  writeFileSync(join(dir, "writer.md"), "---\ndescription: an ordinary one\n---\nYou may do anything the tab may.\n")
})

afterAll(() => {
  if (shared_home) process.env["NULYA_HOME"] = shared_home
  ws.cleanup()
})

function open(width = 100, height = 30) {
  return testRender(
    () => (
      <App
        ws={ws}
        pick={{ profile: "scripted" }}
        style={style}
        driver={{ env: scripted_env }}
        statePath={join(ws.dir, `tui-state-${Math.random().toString(36).slice(2)}.json`)}
        agentsTrusted
      />
    ),
    { width, height },
  )
}

/**
 * The session `/agent <name>` created: the one whose header froze that persona's
 * prompt. Nothing was installed for it, so the listing's `prompts` — labels and
 * sizes, never text — is where a delegation is recognizable.
 */
async function agentSession(id: string): Promise<string | null> {
  const listed = await sessionList(ws)
  const found = listed.find((entry) => entry.composition.prompts.some((p) => p.source === `agent-${id}`))
  return found?.id ?? null
}

test("/agent opens a second tab on a session wearing the definition's prompt, and a read-only one cannot run shell", async () => {
  const setup = await open()
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("/agent probe find the parser")
    setup.mockInput.pressEnter()

    // A session of its own, wearing the persona as BYTES its header froze —
    // rendered from the markdown, and installed nowhere at all.
    await until(async () => (await agentSession("probe")) !== null, 60_000)
    const child = (await agentSession("probe"))!
    await settle(setup, 4)
    // A visible tab, and the status line says which persona it is wearing —
    // once the notice announcing the new tab has come off that line (T35).
    await until(() => statusLine(setup).includes("agent-probe"), 15_000)

    // The scripted provider's `shell echo hello-from-nulya` is refused by the
    // ceiling, and the model is told why — a deny is that call's tool_result
    // (DESIGN §4), so it is in the ledger and not only on the screen.
    await until(async () => (await sessionEvents(ws, child)).some((event) => event.kind === "tool_results"), 60_000)
    const batches = (await sessionEvents(ws, child)).filter(
      (event): event is Extract<LedgerEvent, { kind: "tool_results" }> => event.kind === "tool_results",
    )
    const denied: ToolResultEntry[] = batches.flatMap((event) => event.results)
    expect(denied).not.toHaveLength(0)
    expect(denied.every((result) => result.ok === false)).toBe(true)
    expect(denied.some((result) => result.output.includes("read-only agent"))).toBe(true)
    expect(denied.some((result) => result.output.includes("cannot run shell"))).toBe(true)

    // The task reached it as an ordinary user turn: nothing about a delegation
    // is a new event kind.
    const user = (await sessionEvents(ws, child)).find((event) => event.kind === "user_text")
    expect(user?.kind === "user_text" && user.text).toContain("find the parser")

    // …and the parent is still there, untouched: this tab has no session at all,
    // because a draft that only delegated never had anything to say (T22).
    expect((await sessionList(ws)).filter((entry) => entry.id === child)).toHaveLength(1)
  } finally {
    setup.renderer.destroy()
  }
}, 180_000)

test("an unknown name lists the ones there are, and creates nothing", async () => {
  const setup = await open()
  try {
    await settle(setup, 3)
    const before = (await sessionList(ws)).length
    await setup.mockInput.typeText("/agent nope do something")
    setup.mockInput.pressEnter()
    // Reading the definitions is a subprocess (and, once, a build), so the
    // sentence arrives on its own beat rather than on the next frame.
    await until(() => setup.captureCharFrame().includes("no agent 'nope'"), 300_000)
    const frame = await settle(setup, 2)
    expect(frame).toContain("probe")
    expect(frame).toContain("writer")
    expect((await sessionList(ws)).length).toBe(before)
  } finally {
    setup.renderer.destroy()
  }
}, 300_000)

test("a name with no task says what a task is for, and creates nothing", async () => {
  const setup = await open()
  try {
    await settle(setup, 3)
    const before = (await sessionList(ws)).length
    await setup.mockInput.typeText("/agent probe")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("/agent probe <task>"), 300_000)
    const frame = await settle(setup, 2)
    // The sentence names the reason rather than only the syntax: it starts a
    // session of its own, which is why the whole task has to be said. (The
    // status line has one row, so the tail of it is `fit` away — what has to be
    // there is the shape of the command and the reason it needs an argument.)
    expect(frame).toContain("/agent probe <task>")
    expect(frame).toContain("session of its own")
    expect((await sessionList(ws)).length).toBe(before)
  } finally {
    setup.renderer.destroy()
  }
}, 300_000)

/**
 * Bare `/agent` is the list. Taking a row deliberately does NOT start anything:
 * a delegation needs a task and nobody can guess it.
 */
test("bare /agent lists the definitions and Enter writes the command instead of starting one", async () => {
  const setup = await open()
  try {
    await settle(setup, 3)
    const before = (await sessionList(ws)).length
    await setup.mockInput.typeText("/agent")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("a read-only prober"), 300_000)
    let frame = await settle(setup, 2)
    expect(frame).toContain("agents")
    expect(frame).toContain("a read-only prober")
    expect(frame).toContain("read-only")
    expect(frame).toContain("an ordinary one")
    // …and the personas nobody installed are on the same list.
    expect(frame).toContain("explore")

    setup.mockInput.pressEnter()
    frame = await settle(setup, 4)
    expect(frame).toContain("/agent probe")
    expect((await sessionList(ws)).length).toBe(before)
  } finally {
    setup.renderer.destroy()
  }
}, 300_000)

/**
 * The `agent` package is brought into a session only where it could do
 * something, and never into a delegated one (tui.md §5.10).
 */
test("a session carries the agent tool when this workspace defines agents, and a delegated session never does", async () => {
  const setup = await open()
  try {
    await settle(setup, 3)
    // A top-level session: definitions exist here, so the model gets the tool.
    await setup.mockInput.typeText("hello")
    setup.mockInput.pressEnter()
    await until(async () => (await sessionList(ws)).some((e) => e.composition.active.some((r) => r.startsWith("agent@"))), 120_000)
    const parent = (await sessionList(ws)).find((e) => e.composition.active.some((r) => r.startsWith("agent@")))!
    expect(parent.composition.native_tools).toContain("ext:agent/agent")
    // …and ONLY that one. The package's other three declare `surface:
    // "driver"` in their manifest (DESIGN §7.2.1), and that is what keeps them
    // off the face — nothing here knows their names (tui.md §11, T34).
    for (const driver of ["ext:agent/run", "ext:agent/render", "ext:agent/list"]) {
      expect(parent.composition.native_tools).not.toContain(driver)
    }

    // A delegated session does not: a sub-agent cannot delegate again (leaf).
    await setup.mockInput.typeText("/agent writer do the thing")
    setup.mockInput.pressEnter()
    await until(async () => (await agentSession("writer")) !== null, 120_000)
    const writer = (await agentSession("writer"))!
    const child = (await sessionList(ws)).find((e) => e.id === writer)!
    expect(child.composition.prompts.some((p) => p.source === "agent-writer")).toBe(true)
    // …and the persona is not a package: nothing was installed to carry it.
    expect(child.composition.active.some((r) => r.startsWith("agent-"))).toBe(false)
    expect(child.composition.active.some((r) => r.startsWith("agent@"))).toBe(false)
    expect(child.composition.native_tools).not.toContain("ext:agent/agent")
  } finally {
    setup.renderer.destroy()
  }
}, 300_000)
