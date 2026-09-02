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
import { sessionKind } from "../src/ui/overlays/SessionsView.tsx"
import { extNoteMeta, extNoteText } from "../src/extnote.ts"
import { rememberModel } from "../src/state/tui_state.ts"
import { bundledDraftPath, pinsOf } from "../src/extensions.ts"
import { readContributions } from "../src/nulya/files.ts"
import {
  extBuild,
  extSetCurrent,
  sessionAppend,
  sessionNote,
  sessionEvents,
  sessionList,
  sessionNew,
  sessionStep,
} from "../src/nulya/cli.ts"
import { noteMeta } from "../src/nulya/ledger.ts"
import type { LedgerEvent, ToolResultEntry } from "../src/nulya/ledger.ts"
import type { PluginKey, SessionView } from "nulya-tui/plugin-api"
import { scripted_env, settle, tempWorkspace, unsafe_settings, until, type TempWorkspace } from "./support.ts"

/**
 * Both packages are COMPILED (they parse and emit JSON, which is why every
 * bundled tool package is), so this whole file needs a toolchain —
 * `gate.test.tsx`'s handoff test is the precedent for saying so rather than
 * failing on a machine that has none.
 */
const has_zig = Boolean(process.env["NULYA_ZIG"] ?? Bun.which("zig"))

let ws: TempWorkspace
let plan_version = ""
let ask_version = ""
let compact_version = ""
let handoff_version = ""

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
  // The binary carries its own drafts, so this works in a
  // throwaway directory that has never seen nulya's source tree — which is
  // also what a person installing these packages does.
  plan_version = await extBuild(ws, join(import.meta.dir, "..", "..", "extensions", "plan"))
  await extSetCurrent(ws, "activate", "plan", plan_version)
  ask_version = await extBuild(ws, await bundledDraftPath(ws, "ask", join("extensions", "ask")))
  await extSetCurrent(ws, "activate", "ask", ask_version)
  compact_version = await extBuild(ws, join(import.meta.dir, "..", "..", "extensions", "compact"))
  await extSetCurrent(ws, "activate", "compact", compact_version)
  handoff_version = await extBuild(ws, join(import.meta.dir, "..", "..", "extensions", "handoff"))
  await extSetCurrent(ws, "activate", "handoff", handoff_version)
}, 300_000)

afterAll(() => {
  if (shared_home) process.env["NULYA_HOME"] = shared_home
  ws?.cleanup()
})

// ── Seams: everything a screen would lend the host, answered for real ───────

interface Bench {
  host: PluginHost
  notices: string[]
  opened: string | null
  openedWake: boolean
  session: SessionView
}

function benchFor(sessionId: string): Bench {
  const bench: Bench = {
    host: null as unknown as PluginHost,
    notices: [],
    opened: null,
    openedWake: false,
    session: { id: sessionId, model: "scripted", members: [], role: "driver", status: "idle", activity: "idle", permissionMode: "ask" },
  }
  bench.host = createPluginHost({
    ws,
    enabled: true,
    statePath: join(ws.dir, `tui-state-${sessionId}.json`),
    session: () => bench.session,
    tasks: () => [],
    // The real verb, and the whole of it: `session note` deposits into the
    // inbox, and only a STEP drains it into the ledger — which is
    // what `attach.note` does for a tab that is driving, so a seam that only
    // deposited would be testing half the path.
    appendNote: async (pkg, kind, text) => {
      await sessionNote(ws, sessionId, "ext", extNoteText(text), extNoteMeta(pkg, kind))
      await stepOnce(sessionId)
    },
    openTab: (id, options) => {
      bench.opened = id
      bench.openedWake = options?.wakePending ?? false
    },
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

/** One keypress as the host hands it on (`pluginKeyOf`), including printable `text`. */
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
  const surface = open.spec.render(80)
  const rows = Array.isArray(surface) ? surface : []
  return rows.map((line) => line.map((span) => span.text).join("")).join("\n")
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
  host.observe({
    kind: "event",
    event: { seq: seq + 1, kind: "tool_results", results: [{ call_id: callId, ok: true, output: "recorded", spill_path: null }] } as LedgerEvent,
  }, session)
}

/** A note a package assembled: the event kind, plus the column naming it. */
function isExtNote(event: LedgerEvent): event is Extract<LedgerEvent, { kind: "note" }> {
  return event.kind === "note" && typeof noteMeta(event as { meta?: string })["pkg"] === "string"
}


test.skipIf(!has_zig)("handoff: its durable card shows every brief field on replay", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const bench = benchFor(id)
  await bench.host.load()
  const card = bench.host.cardFor("handoff")
  expect(card?.pkg).toBe("handoff")
  const rows = card!.renderer.render({
    tool: "handoff",
    args: JSON.stringify({
      done: "implemented the continuation",
      next_task: "run the complete verification suite",
      keep: "src/plugins/host.ts and test/consumers.test.tsx",
      drop: "discarded probe details",
    }),
    output: "recorded",
    presentation: null,
    ok: true,
    state: "done",
  }, 80)
  const text = Array.isArray(rows) ? rows.map((line) => line.map((span) => span.text).join("")).join("\n") : ""
  expect(text).toContain("next task · run the complete verification suite")
  expect(text).toContain("done · implemented the continuation")
  expect(text).toContain("keep · src/plugins/host.ts")
  expect(text).toContain("drop · discarded probe details")
}, 120_000)


test.skipIf(!has_zig)("compact: /compact runs the package tool and opens a child without replacing its parent", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, id, "summarise this work")
  await stepOnce(id)
  const bench = benchFor(id)
  await bench.host.load()
  expect(bench.host.loaded().some((one) => one.id === "compact")).toBe(true)
  const command = bench.host.commands().find((one) => one.pkg === "compact" && one.name === "compact")!
  await command.run({ args: "keep the verification result", session: { id, model: "scripted", members: [], role: "driver", status: "idle" } })
  expect(bench.opened).toStartWith("s-")
  expect(bench.opened).not.toBe(id)
  expect(bench.openedWake).toBe(true)
  const listed = await sessionList(ws)
  expect(listed.some((one) => one.id === id)).toBe(true)
  const child = listed.find((one) => one.id === bench.opened)!
  expect(child.parent?.session).toBe(id)
  // Before the TUI attachment gets its first poll the summary is still in the
  // inbox. The continuation must nevertheless remain reachable in /sessions.
  expect(child.events).toBe(0)
  expect(sessionKind(child)).toBe("own")
}, 300_000)

test.skipIf(!has_zig)("compact: only a live successful handoff opens its panel, and Esc never forks", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const bench = benchFor(id)
  await bench.host.load()
  toolCall(bench.host, id, "handoff-1", "handoff", {
    done: "mapped the code",
    next_task: "implement the change",
    keep: "src/plugins/host.ts",
  }, 8)
  expect(bench.host.panel()?.pkg).toBe("compact")
  expect(panelText(bench.host)).toContain("next: implement the change")
  bench.host.handleKey(key("escape"))
  expect(bench.host.panel()).toBeNull()
  expect(bench.opened).toBeNull()

  // Re-delivery in the same process is idempotent, as rerenders and task refreshes are.
  toolCall(bench.host, id, "handoff-1", "handoff", {
    done: "mapped the code",
    next_task: "implement the change",
    keep: "src/plugins/host.ts",
  }, 8)
  expect(bench.host.panel()).toBeNull()
}, 120_000)

test.skipIf(!has_zig)("compact: unsafe follows an accepted handoff without opening the approval panel", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const bench = benchFor(id)
  bench.session = { ...bench.session, permissionMode: "unsafe" }
  await bench.host.load()
  bench.host.observeSession(bench.session)

  toolCall(bench.host, id, "handoff-auto", "handoff", {
    done: "finished this phase",
    next_task: "continue without waiting for a click",
    keep: "the accepted brief",
  }, 8)
  expect(bench.host.panel()).toBeNull()
  await until(() => bench.notices.includes("following handoff…"))
  expect(bench.host.panel()).toBeNull()
}, 120_000)

test.skipIf(!has_zig)("compact: a background handoff resurfaces when its session returns to the front", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const bench = benchFor(id)
  await bench.host.load()

  // The proposal arrives for A while B is in front. Nothing is already open to
  // hide a missing resurface notification.
  bench.session = { ...bench.session, id: "s-other" }
  bench.host.observeSession(bench.session)
  toolCall(bench.host, id, "handoff-a", "handoff", {
    done: "finished A",
    next_task: "continue A",
    keep: "A.md",
  }, 8)
  expect(bench.host.panel()).toBeNull()

  bench.session = { ...bench.session, id }
  bench.host.observeSession(bench.session)
  expect(bench.host.panel()?.pkg).toBe("compact")
  expect(panelText(bench.host)).toContain("next: continue A")
}, 120_000)

test.skipIf(!has_zig)("compact: a newer handoff supersedes the same session's older proposal", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const bench = benchFor(id)
  await bench.host.load()

  toolCall(bench.host, id, "handoff-a1", "handoff", {
    done: "finished A1",
    next_task: "continue A1",
    keep: "A1.md",
  }, 8)
  toolCall(bench.host, id, "handoff-a2", "handoff", {
    done: "finished A2",
    next_task: "continue A2",
    keep: "A2.md",
  }, 10)
  expect(panelText(bench.host)).toContain("next: continue A2")
  expect(panelText(bench.host)).not.toContain("continue A1")

  // A late duplicate delivery of the older event cannot roll the session back.
  toolCall(bench.host, id, "handoff-a1", "handoff", {
    done: "finished A1",
    next_task: "continue A1",
    keep: "A1.md",
  }, 8)
  expect(panelText(bench.host)).toContain("next: continue A2")

  // Dismissing the latest answer leaves no older actionable queue behind.
  bench.host.handleKey(key("escape"))
  expect(bench.host.panel()).toBeNull()
  bench.session = { ...bench.session, id: "s-other" }
  bench.host.observeSession(bench.session)
  bench.session = { ...bench.session, id }
  bench.host.observeSession(bench.session)
  expect(bench.host.panel()).toBeNull()
}, 120_000)

test.skipIf(!has_zig)("compact: a sending session can retry instead of losing its handoff", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const bench = benchFor(id)
  await bench.host.load()
  bench.session = { ...bench.session, activity: "sending" }

  toolCall(bench.host, id, "handoff-a", "handoff", {
    done: "finished A",
    next_task: "continue A",
    keep: "A.md",
  }, 8)
  bench.host.handleKey(key("return"))
  await Promise.resolve()
  expect(bench.opened).toBeNull()
  expect(bench.notices.at(-1)).toContain("message is still being sent")
  expect(panelText(bench.host)).toContain("resolve the notice above, then press Enter again")
  expect(panelText(bench.host)).toContain("next: continue A")
}, 120_000)

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

/**
 * The two packages are a mode and a capability, and the SHAPE of each says so.
 *
 * `plan` is a mode: it carries a system prompt, so wearing it says what THIS
 * session is — a persona and a read-only stance — and that is a decision
 * somebody makes before the work starts, one `/plan` (or `--with`) at a time.
 * `ask` is a capability: one tool, no prompt, because nobody can decide in
 * advance that a question will come up, and `/ask` is the command it declares
 * to bring itself into the session that needs it.
 *
 * What NEITHER of them says is `apply: "auto"` — the one field that
 * would put a package in every session on this machine — so `/ext`'s Enter on
 * either is a pointer move and nothing else. Asserted against the real frozen
 * manifests rather than described.
 */
test.skipIf(!has_zig)("plan is a mode and ask is a capability, and neither asks to be in every session", async () => {
  const plan = await readContributions(ws, "plan", plan_version)
  const ask = await readContributions(ws, "ask", ask_version)

  expect(plan.systemPrompts.length).toBeGreaterThan(0)
  expect(plan.apply).toBe("manual")
  // Its two model tools are `surface: "auto"`: they arrive with the membership
  // `/plan` creates, and a pin naming one would be refused outright — so the
  // switch writes none.
  expect(plan.autoTools).toEqual(["propose", "todo"])
  expect(pinsOf(plan)).toEqual([])

  expect(ask.systemPrompts).toEqual([])
  expect(ask.apply).toBe("manual")
  // Same shape, one tool: `/ask` composes the package and the tool comes with
  // it. Nothing to pin, and nothing standing — which is why `ask` is reached by
  // typing its name rather than by a checkbox.
  expect(ask.autoTools).toEqual(["ask"])
  expect(pinsOf(ask)).toEqual([])
  expect(ask.commands.map((c) => c.name)).toEqual(["ask"])
})

/**
 * Wearing a package brings its tools with it.
 *
 * The two axes are independent everywhere else and here they
 * cannot be: a WORN package is a member of exactly the session that names it,
 * so a pin for its tool has nowhere to live except the same argv. On a standing
 * list it would wear `plan` in EVERY session (a pin brings its package in),
 * which is the difference `/with` exists to make.
 *
 * So this drives the real keystrokes: `/with plan` on a draft, then a message,
 * and asks the kernel what it froze.
 */
test.skipIf(!has_zig)("plan: /with puts the package AND its tools into the session it starts", async () => {
  const known = new Set((await sessionList(ws)).map((row) => row.id))
  const before = await sessionNew(ws, { profile: "scripted" })
  known.add(before)
  const state = createSessionState(before)
  // The draft has to know what to run on: a `/model` pick is remembered here,
  // and without one the next session is the config's default profile — which on
  // a test machine has no credential and refuses before any of this is reached.
  const statePath = join(ws.dir, "tui-state-wear.json")
  rememberModel({ profile: "scripted" }, statePath)
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        id={before}
        state={state}
        style={style}
        statePath={statePath}
        driver={{ env: scripted_env }}
        created
      />
    ),
    { width: 90, height: 24 },
  )
  await settle(setup, 3)
  // Back to a draft, then wear the package: neither of these starts anything.
  await setup.mockInput.typeText("/clear")
  setup.mockInput.pressEnter()
  await settle(setup, 3)
  await setup.mockInput.typeText("/with plan")
  setup.mockInput.pressEnter()
  await settle(setup, 3)
  // The first message is what makes a draft a session.
  await setup.mockInput.typeText("probe")
  setup.mockInput.pressEnter()
  await until(async () => (await sessionList(ws)).some((row) => !known.has(row.id)))
  const started = (await sessionList(ws)).find((row) => !known.has(row.id))!
  setup.renderer.destroy()

  // Membership: the version is in the composition, frozen.
  expect(started.composition.active.some((one) => one.startsWith("plan@"))).toBe(true)
  // …and the face: both model tools, beside the one builtin. `approve` is the
  // package's own `surface: "internal"` and stays off it.
  expect(started.composition.native_tools).toContain("ext:plan/propose")
  expect(started.composition.native_tools).toContain("ext:plan/todo")
  expect(started.composition.native_tools).not.toContain("ext:plan/approve")
}, 180_000)

test.skipIf(!has_zig)(
  "plan: propose opens the review, comments come back as one turn, and approval continues in a session that does not wear the persona",
  async () => {
    const id = await sessionNew(ws, { profile: "scripted", with: [`plan@${plan_version}`] })
    const bench = benchFor(id)
    await bench.host.load()
    expect(bench.host.loaded().some((one) => one.id === "plan")).toBe(true)
    // The package registers a card for its own tool, and no widget: it DECLARES
    // `todo{ui: {panel: true}}`, and a code widget would supersede that row to
    // say the same thing twice (`registerWidget`'s contract).
    expect(bench.host.cardFor("propose")?.pkg).toBe("plan")
    expect(bench.host.widgets().some((one) => one.pkg === "plan")).toBe(false)

    // ① The plan is proposed. Nothing was clicked: the panel opens because the
    // call finished, which is the whole of "the review is not a blocking tool".
    expect(bench.host.panel()).toBeNull()
    toolCall(bench.host, id, "call-1", "propose", { plan_md: first_plan }, 2)
    expect(bench.host.panel()?.pkg).toBe("plan")
    expect(panelText(bench.host)).toContain("## Phase 1 — read")

    // ② A comment on a line, typed into the panel. `key.text` carries the
    // printable character; without it the letters here would be a keyboard-layout guess.
    bench.host.handleKey(key("j"))
    bench.host.handleKey(key("j"))
    bench.host.handleKey(key("c"))
    type(bench.host, "say which files")
    bench.host.handleKey(key("return"))
    expect(panelText(bench.host)).toContain("1 comment")

    // ③ `r` sends every comment as ONE note, quoting what it is about.
    bench.host.handleKey(key("r"))
    await until(async () => (await sessionEvents(ws, id)).some(isExtNote), 60_000)
    const note = (await sessionEvents(ws, id)).find(isExtNote)!
    expect(noteMeta(note)).toMatchObject({ pkg: "plan", kind: "plan-comments" })
    const said = note.text
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
    // brief, then the generic cross-package action runs compact's internal tool.
    bench.host.handleKey(key("a"))
    await until(() => bench.opened !== null || panelText(bench.host).includes("failed"), 180_000)
    expect(bench.opened).not.toBeNull()
    const child = bench.opened!
    expect(child).toStartWith("s-")
    expect(bench.openedWake).toBe(true)

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

test.skipIf(!has_zig)("ask: the question opens a panel, and the option chosen there comes back as one note", async () => {
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
  expect(noteMeta(note)).toMatchObject({ pkg: "ask", kind: "answer" })
  const said = note.text
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
  expect(note.text).toContain("call it propose")
}, 300_000)
