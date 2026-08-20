/**
 * The two real consumers of goals/tui-plugin.md — `extensions/plan` and
 * `extensions/ask` (U4), against the real binary and the real packages.
 *
 * These are the packages the declaration layer (U2) and the plugin host (U3)
 * were built for, so what is worth testing here is not the machinery again but
 * the ROUND TRIP each package promises:
 *
 *  - plan: a `propose` call opens the review panel by itself; comments written
 *    there come back as ONE user turn in the ledger, quoting the lines they are
 *    about; a second `propose` replaces the plan; `a` writes a brief and forks,
 *    and the session that continues does NOT wear the planning persona.
 *  - ask: an `ask` call opens a panel listing the options; the one chosen
 *    lands in the ledger as an ordinary user turn.
 *  - and the policy the plan package declares is a ceiling: `shell` is refused
 *    in a session wearing it even in `unsafe` mode, with a note naming it.
 *
 * The one thing simulated is the MODEL: no offline provider calls `propose` or
 * `ask` (`launch.ScriptedProvider` has a fixed repertoire, and U4 changes no
 * kernel code to widen it). So the assistant event and the two `tool` stream
 * lines are handed to the host directly — exactly the bytes `session step
 * --stream` prints — and everything downstream of them is real: a real store, a
 * real frozen version, the real module loaded from it by absolute path, a real
 * `session append`, a real `ext run`, a real fork.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { createStyle, type Style } from "../src/render/theme.ts"
import { createSessionState } from "../src/state/session.ts"
import { createPluginHost, type PluginHost } from "../src/plugins/host.ts"
import { parseExtNote, wrapExtNote } from "../src/extnote.ts"
import { runCompact } from "../src/compact.ts"
import { bundledDraftPath } from "../src/extensions.ts"
import {
  extBuild,
  extSetCurrent,
  sessionAppend,
  sessionEvents,
  sessionList,
  sessionNew,
  sessionStep,
} from "../src/nulya/cli.ts"
import type { LedgerEvent, ToolResultEntry } from "../src/nulya/ledger.ts"
import type { CompactedView, PluginKey } from "nulya-tui/plugin-api"
import { scripted_env, settle, tempWorkspace, unsafe_settings, until, type TempWorkspace } from "./support.ts"

/**
 * Both packages are COMPILED (they parse JSON-RPC and echo an id back, which is
 * why every bundled tool package is), so this whole file needs a toolchain —
 * `gate.test.tsx`'s handoff test is the precedent for saying so rather than
 * failing on a machine that has none.
 */
const has_zig = Boolean(process.env["NULYA_ZIG"] ?? Bun.which("zig"))

let ws: TempWorkspace
let plan_version = ""
let ask_version = ""

/**
 * A home of this file's own: `bundledDraftPath` seeds a draft into the USER
 * store, and `test/isolate.ts` points that at one scratch directory for the
 * whole run — without this, `/ext`'s assertions elsewhere would find rows
 * nobody put there (the same accident `delegate.test.tsx` records).
 */
const shared_home = process.env["NULYA_HOME"]

const style: Style = createStyle(unsafe_settings, {})

beforeAll(async () => {
  if (!has_zig) return
  ws = tempWorkspace()
  process.env["NULYA_HOME"] = join(ws.dir, "home")
  // The binary carries its own drafts (DESIGN §7.8), so this works in a
  // throwaway directory that has never seen nulya's source tree — which is
  // also what a person installing these packages does.
  plan_version = await extBuild(ws, await bundledDraftPath(ws, "plan", join("extensions", "plan")))
  await extSetCurrent(ws, "activate", "plan", plan_version)
  ask_version = await extBuild(ws, await bundledDraftPath(ws, "ask", join("extensions", "ask")))
  await extSetCurrent(ws, "activate", "ask", ask_version)
}, 300_000)

afterAll(() => {
  if (shared_home) process.env["NULYA_HOME"] = shared_home
  ws?.cleanup()
})

// ── Seams: everything a screen would lend the host, answered for real ───────

interface Bench {
  host: PluginHost
  notices: string[]
  forked: CompactedView | null
}

function benchFor(sessionId: string): Bench {
  const bench: Bench = { host: null as unknown as PluginHost, notices: [], forked: null }
  bench.host = createPluginHost({
    ws,
    enabled: true,
    statePath: join(ws.dir, `tui-state-${sessionId}.json`),
    session: () => ({ id: sessionId, model: "scripted", members: [] }),
    tasks: () => [],
    // The real verb, and the whole of it: `session append` deposits into the
    // inbox, and only a STEP drains it into the ledger (DESIGN §3.4) — which is
    // what `attach.send` does for a tab that is driving, so a seam that only
    // appended would be testing half the path.
    appendNote: async (pkg, kind, text) => {
      await sessionAppend(ws, sessionId, wrapExtNote(pkg, kind, text))
      await stepOnce(sessionId)
    },
    compact: async (options) => {
      const result = await runCompact(ws, sessionId, options)
      bench.forked = result
      return result
    },
    openTab: () => {},
    wearNext: () => {},
    notice: (text) => bench.notices.push(text),
    zoneBusy: () => false,
  })
  return bench
}

/**
 * One real step against the offline provider, so whatever is in the inbox
 * reaches the ledger. Lines are forwarded to the host when one is given, which
 * is exactly what `state/driver.ts`'s `onLine` does for a driving tab.
 */
async function stepOnce(sessionId: string, host?: PluginHost): Promise<void> {
  const step = sessionStep(ws, sessionId, { maxSteps: 1, env: scripted_env })
  for await (const line of step.lines) host?.observe(line, sessionId)
  await step.exited
}

/** One keypress as the host hands it on (`pluginKeyOf`), including 1.1's `text`. */
function key(name: string, text?: string): PluginKey {
  return { name, ctrl: false, shift: false, meta: false, ...(text === undefined ? {} : { text }) }
}

/** Type into whatever field the open panel has, one printable key at a time. */
function type(host: PluginHost, text: string): void {
  for (const ch of text) host.handleKey(ch === " " ? key("space", " ") : key(ch, ch))
}

/** The panel's rows as plain text — what a person would be reading. */
function panelText(host: PluginHost): string {
  const open = host.panel()
  if (!open) return ""
  return open.spec
    .render(80)
    .map((line) => line.map((span) => span.text).join(""))
    .join("\n")
}

/**
 * One tool call, delivered the way a driven step delivers it: the assistant
 * event first (the ledger's copy, which is where a plugin reads the arguments
 * from), then the `tool` begin/end pair from the stream.
 */
function toolCall(host: PluginHost, session: string, callId: string, tool: string, args: unknown, seq: number): void {
  host.observe(
    {
      kind: "event",
      event: { seq, kind: "assistant", text: "", calls: [{ id: callId, tool, args: JSON.stringify(args) }] } as LedgerEvent,
    },
    session,
  )
  host.observe({ kind: "stream", line: { stream: "tool", event: "begin", call_id: callId, tool } }, session)
  host.observe({ kind: "stream", line: { stream: "tool", event: "end", call_id: callId, ok: true } }, session)
}

function isExtNote(event: LedgerEvent): event is Extract<LedgerEvent, { kind: "user_text" }> {
  return event.kind === "user_text" && (event as Extract<LedgerEvent, { kind: "user_text" }>).text.includes("<ext-note ")
}

// ── plan ───────────────────────────────────────────────────────────────────

const first_plan = [
  "# Plan",
  "",
  "## Phase 1 — read",
  "",
  "Look at the files.",
  "",
  "## Phase 2 — write",
  "",
  "Change them.",
].join("\n")

test.skipIf(!has_zig)(
  "plan: propose opens the review, comments come back as one turn, and approval continues in a session that does not wear the persona",
  async () => {
    const id = await sessionNew(ws, { profile: "scripted", with: [`plan@${plan_version}`] })
    const bench = benchFor(id)
    await bench.host.load()
    expect(bench.host.loaded().some((one) => one.id === "plan")).toBe(true)
    // The package registers a card for its own tool, and no widget: it DECLARES
    // `todo{panel: true}`, and a code widget would supersede that row to say
    // the same thing twice (`registerWidget`'s contract).
    expect(bench.host.cardFor("propose")?.pkg).toBe("plan")
    expect(bench.host.widgets().some((one) => one.pkg === "plan")).toBe(false)

    // ① The plan is proposed. Nothing was clicked: the panel opens because the
    // call finished, which is the whole of "the review is not a blocking tool".
    expect(bench.host.panel()).toBeNull()
    toolCall(bench.host, id, "call-1", "propose", { plan_md: first_plan }, 2)
    expect(bench.host.panel()?.pkg).toBe("plan")
    expect(panelText(bench.host)).toContain("## Phase 1 — read")

    // ② A comment on a line, typed into the panel. `key.text` is contract 1.1;
    // without it the letters here would be a keyboard-layout guess.
    bench.host.handleKey(key("j"))
    bench.host.handleKey(key("j"))
    bench.host.handleKey(key("c"))
    type(bench.host, "say which files")
    bench.host.handleKey(key("return"))
    expect(panelText(bench.host)).toContain("1 comment")

    // ③ `r` sends every comment as ONE user turn, quoting what it is about.
    bench.host.handleKey(key("r"))
    await until(async () => (await sessionEvents(ws, id)).some(isExtNote), 60_000)
    const note = (await sessionEvents(ws, id)).find(isExtNote)!
    expect(note.text).toContain('pkg="plan"')
    expect(note.text).toContain('kind="plan-comments"')
    const said = parseExtNote(note.text)!.text
    expect(said).toContain("> ## Phase 1 — read")
    expect(said).toContain("say which files")
    expect(said).toContain("line 3")
    // One turn, not one per comment: a review that cost six turns would cost
    // six revisions' worth of prefix for no more information.
    expect((await sessionEvents(ws, id)).filter(isExtNote)).toHaveLength(1)
    expect(bench.host.panel()).toBeNull()

    // ④ The revised plan replaces the old one, and reopens the review.
    const revised = `${first_plan}\n\n(revised: src/main.zig and src/cli.zig)`
    toolCall(bench.host, id, "call-2", "propose", { plan_md: revised }, 4)
    expect(bench.host.panel()?.pkg).toBe("plan")
    expect(panelText(bench.host)).toContain("of 11")

    // ⑤ Approve. Two real steps: this package's own `approve` tool writes the
    // brief, then `/compact`'s `brief_file` branch forks on it.
    bench.host.handleKey(key("a"))
    await until(() => bench.forked !== null, 180_000)
    const child = bench.forked!.session
    expect(child).toStartWith("s-")
    expect(bench.forked!.parent.session).toBe(id)

    // The brief is on disk, in the shape `extensions/handoff` writes.
    const brief = join(ws.dir, ".nulya", "handoffs", `${id}-1.md`)
    expect(existsSync(brief)).toBe(true)
    const written = readFileSync(brief, "utf8")
    expect(written).toContain("# Approved plan")
    expect(written).toContain("src/main.zig and src/cli.zig")

    // …and the session that carries it out is an ORDINARY one. `session new
    // --parent` takes no `--with`, so the plan travelled and the read-only
    // persona that wrote it did not — which is the point of forking at all.
    const listed = await sessionList(ws)
    const parent = listed.find((row) => row.id === id)!
    const continued = listed.find((row) => row.id === child)!
    expect(parent.composition.active.join(" ")).toContain("plan@")
    expect(continued.composition.active.join(" ")).not.toContain("plan@")
    expect(continued.parent?.session).toBe(id)
    // The brief really was carried over: `compact` deposits it, so it is the
    // child's first turn as soon as anything steps it.
    await stepOnce(child)
    const carried = await sessionEvents(ws, child)
    expect(carried.some((event) => event.kind === "user_text" && String(event["text"]).includes("# Approved plan"))).toBe(
      true,
    )
  },
  300_000,
)

/**
 * `contributes.policy.readonly: true` on a composition MEMBER is judged before
 * every approval table (D3) — `unsafe` mode would wave a `shell` call straight
 * through, so a denial here is the ceiling firing and nothing else. The `guard`
 * fixture in `plugin.test.tsx` proves the mechanism; this proves the package
 * that actually ships it uses it.
 */
test.skipIf(!has_zig)("plan: a session wearing it cannot run shell, and the note says whose policy that is", async () => {
  const id = await sessionNew(ws, { profile: "scripted", with: [`plan@${plan_version}`] })
  const state = createSessionState(id)
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        id={id}
        state={state}
        style={style}
        driver={{ env: scripted_env }}
        statePath={join(ws.dir, `tui-state-gate-${id}.json`)}
        created
      />
    ),
    { width: 100, height: 24 },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("look around")
    setup.mockInput.pressEnter()
    await until(async () => (await sessionEvents(ws, id)).some((event) => event.kind === "tool_results"), 60_000)
    const results: ToolResultEntry[] = (await sessionEvents(ws, id))
      .filter((event): event is Extract<LedgerEvent, { kind: "tool_results" }> => event.kind === "tool_results")
      .flatMap((event) => event.results)
    expect(results).not.toHaveLength(0)
    expect(results.every((one) => one.ok === false)).toBe(true)
    expect(results.some((one) => one.output.includes("read-only policy of plan"))).toBe(true)
    expect(results.some((one) => one.output.includes("cannot run shell"))).toBe(true)
  } finally {
    setup.renderer.destroy()
  }
}, 180_000)

// ── ask ────────────────────────────────────────────────────────────────────

test.skipIf(!has_zig)("ask: the question opens a panel, and the option chosen there becomes a user turn", async () => {
  const id = await sessionNew(ws, { profile: "scripted", with: [`ask@${ask_version}`] })
  const bench = benchFor(id)
  await bench.host.load()
  expect(bench.host.loaded().some((one) => one.id === "ask")).toBe(true)

  toolCall(
    bench.host,
    id,
    "ask-1",
    "ask",
    { question: "Where should the journal live?", options: ["a jsonl file", "the ledger"], free_text: true },
    2,
  )
  expect(bench.host.panel()?.pkg).toBe("ask")
  const shown = panelText(bench.host)
  expect(shown).toContain("Where should the journal live?")
  expect(shown).toContain("1. a jsonl file")
  expect(shown).toContain("2. the ledger")
  // `free_text` adds the invitation to write one instead — it is not an option,
  // it is the way into the field.
  expect(shown).toContain("something else")

  bench.host.handleKey(key("2", "2"))
  bench.host.handleKey(key("return"))
  await until(async () => (await sessionEvents(ws, id)).some(isExtNote), 60_000)
  const note = (await sessionEvents(ws, id)).find(isExtNote)!
  expect(note.text).toContain('pkg="ask"')
  expect(note.text).toContain('kind="answer"')
  const said = parseExtNote(note.text)!.text
  expect(said).toContain("the ledger")
  // The question travels with the answer: a bare "the ledger" arriving several
  // turns later is not an answer to anything the model can find again.
  expect(said).toContain("Where should the journal live?")
  // Answered, so the panel is gone — there is nothing left to ask.
  expect(bench.host.panel()).toBeNull()
}, 300_000)

test.skipIf(!has_zig)("ask: an answer in your own words is typed into the same panel", async () => {
  const id = await sessionNew(ws, { profile: "scripted", with: [`ask@${ask_version}`] })
  const bench = benchFor(id)
  await bench.host.load()

  toolCall(bench.host, id, "ask-2", "ask", { question: "Which name?", options: ["plan", "review"] }, 2)
  expect(bench.host.panel()?.pkg).toBe("ask")
  bench.host.handleKey(key("t"))
  type(bench.host, "call it propose")
  expect(panelText(bench.host)).toContain("call it propose")
  bench.host.handleKey(key("return"))

  await until(async () => (await sessionEvents(ws, id)).some(isExtNote), 60_000)
  const note = (await sessionEvents(ws, id)).find(isExtNote)!
  expect(parseExtNote(note.text)!.text).toContain("call it propose")
}, 300_000)
