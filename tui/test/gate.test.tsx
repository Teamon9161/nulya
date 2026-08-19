/**
 * The permission mode on screen (tui.md §5.7), against the real binary.
 *
 * Every step this TUI drives is gated: `nulya session step --gate --stream` asks
 * before each tool call and this front end answers. So these tests are about the
 * one thing only a person can supply — the answer — and about what the model is
 * told when the answer is no.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { createStyle } from "../src/render/theme.ts"
import { createSessionState } from "../src/state/session.ts"
import { default_settings } from "../src/state/settings.ts"
import { sessionEvents, sessionList, sessionNew } from "../src/nulya/cli.ts"
import { parseApprovalNote } from "../src/approvalnote.ts"
import { handoffsFor, headline, nextHandoff } from "../src/handoff.ts"
import { verdictLine } from "../src/nulya/cli.ts"
import {
  auto_settings,
  scripted_batch_env,
  scripted_env,
  settle,
  tempWorkspace,
  until,
  type TempWorkspace,
} from "./support.ts"

/** The default: a person answers. `auto_settings` is the other half of the pair. */
const ask_style = createStyle(default_settings, {})

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

/** The scripted provider's one call is `shell echo hello-from-nulya`. */
async function stepUntilAsked(width = 100, height = 24, env: Record<string, string> = scripted_env) {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    // A state file of this call's own. `/mode` REMEMBERS the choice (tui.md
    // §7), so one test that switches to auto would otherwise decide the mode
    // every later test in this file starts in.
    () => (
      <App
        ws={ws}
        id={id}
        state={state}
        style={ask_style}
        driver={{ env }}
        statePath={join(ws.dir, `tui-state-${id}.json`)}
        created
      />
    ),
    { width, height },
  )
  await settle(setup, 3)
  await setup.mockInput.typeText("probe")
  setup.mockInput.pressEnter()
  await until(() => setup.captureCharFrame().includes("approve this call"), 30_000)
  return { id, state, setup }
}

test("in ask mode a tool call waits, marked on its card and asked above the box", async () => {
  const { state, setup } = await stepUntilAsked()
  try {
    // Two halves of one question (tui.md §5.7): the card says WHICH call, the
    // dialog above the composer offers the answers and takes the note.
    const frame = setup.captureCharFrame()
    expect(frame).toContain("echo hello-from-nulya")
    expect(frame).toContain("waiting for you")
    expect(frame).toContain("allow this call")
    expect(frame).toContain("deny")
    expect(frame).toContain("note")
    // Nothing ran while it waited.
    expect(state.snapshot.items.some((item) => item.kind === "tool" && item.resolved)).toBe(false)

    // The cursor starts on "allow this call", so Enter is the answer with no
    // aiming at all — the one gesture that has to be free.
    setup.mockInput.pressEnter()
    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved), 30_000)
    const call = state.snapshot.items.find((item) => item.kind === "tool" && item.resolved)!
    expect(call.kind === "tool" && call.output).toContain("hello-from-nulya")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

/**
 * The note on a DENY has a kernel channel: `deny <note>` becomes that call's
 * marker result (DESIGN §4). Reaching it takes no dedicated key — type, and the
 * words are already in the note.
 */
test("a note on a denial reaches the model as that call's result", async () => {
  const { state, setup } = await stepUntilAsked()
  try {
    // Typing while the list has the cursor IS writing the note (tcode's rule).
    await setup.mockInput.typeText("not on this machine")
    await until(() => setup.captureCharFrame().includes("not on this machine"), 10_000)
    // Tab back to the list, then down to the last answer: deny.
    setup.mockInput.pressTab()
    // Four answers on a lone call: allow · always · mode auto · deny.
    for (let i = 0; i < 3; i++) setup.mockInput.pressKey("ARROW_DOWN")
    expect(await settle(setup, 2)).toContain("deny")
    setup.mockInput.pressEnter()

    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved), 30_000)
    const call = state.snapshot.items.find((item) => item.kind === "tool" && item.resolved)!
    expect(call.kind === "tool" && call.ok).toBe(false)
    // The kernel's own marker, plus the words the person typed (DESIGN §4).
    expect(call.kind === "tool" && call.output).toContain("denied by the user")
    expect(call.kind === "tool" && call.output).toContain("not on this machine")
    // A denial is not an execution: nothing the command would have printed.
    expect(call.kind === "tool" && call.output).not.toContain("[exit 0]")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

/**
 * tcode's `set_mode` option, in nulya's vocabulary. It is on the LIST rather
 * than in the composer because the dialog owns the keyboard: `/mode auto` is
 * not typeable while a call waits, and "stop asking me" is exactly what
 * somebody reaches for at the fourth prompt in a row.
 */
test("`allow everything from here on` answers this call and switches the mode", async () => {
  const { state, setup } = await stepUntilAsked()
  try {
    // The digit picks the row it numbers; on a lone call 3 is the mode answer.
    setup.mockInput.pressKey("3")
    expect(await settle(setup, 2)).toContain("allow everything from here on")
    setup.mockInput.pressEnter()
    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved), 30_000)
    const call = state.snapshot.items.find((item) => item.kind === "tool" && item.resolved)!
    expect(call.kind === "tool" && call.output).toContain("hello-from-nulya")
    expect(setup.captureCharFrame()).toContain("auto")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("in auto mode the same call just runs, and the mode is on the status line", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        id={id}
        state={state}
        style={createStyle(auto_settings, {})}
        driver={{ env: scripted_env }}
        statePath={join(ws.dir, `tui-state-${id}.json`)}
        created
      />
    ),
    { width: 100, height: 24 },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("probe")
    setup.mockInput.pressEnter()
    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved), 60_000)
    const call = state.snapshot.items.find((item) => item.kind === "tool" && item.resolved)!
    expect(call.kind === "tool" && call.output).toContain("hello-from-nulya")
    expect(setup.captureCharFrame()).toContain("auto")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

/**
 * The note on a YES, which the kernel's gate has no channel for and should not
 * (`approvalnote.ts`): the call runs, and the guidance is appended as an
 * ordinary turn that the next step boundary drains — right behind the
 * tool_results of the batch it was about.
 */
test("a note on an approval runs the call and reaches the model as its own turn", async () => {
  const { id, state, setup } = await stepUntilAsked()
  try {
    await setup.mockInput.typeText("use ls next time")
    await until(() => setup.captureCharFrame().includes("use ls next time"), 10_000)
    // The cursor never left "allow this call": the note rides on whichever
    // answer is chosen, which is the whole point of it living on the dialog.
    setup.mockInput.pressEnter()

    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved), 30_000)
    const call = state.snapshot.items.find((item) => item.kind === "tool" && item.resolved)!
    expect(call.kind === "tool" && call.ok).toBe(true)
    expect(call.kind === "tool" && call.output).toContain("hello-from-nulya")

    // In the ledger as a user turn carrying the sentinel, and on screen as the
    // person's own words with a badge naming the call.
    await until(async () => (await sessionEvents(ws, id)).some((event) => event.kind === "user_text" &&
      parseApprovalNote((event as { text: string }).text) !== null), 30_000)
    const note = (await sessionEvents(ws, id))
      .map((event) => (event.kind === "user_text" ? parseApprovalNote((event as { text: string }).text) : null))
      .find((parsed) => parsed !== null)!
    expect(note.tool).toBe("shell")
    expect(note.text).toBe("use ls next time")
    expect(setup.captureCharFrame()).toContain("note on shell")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

/**
 * A turn with three calls in it (tui.md §5.7). The kernel offers them one at a
 * time — call N only once N-1 has run — so the batch answer is a decision about
 * the calls a person can SEE, all three already on screen as cards, rather than
 * a promise about anything the model has not written yet.
 */
test("the batch answer covers the rest of the turn, and says how many are left", async () => {
  const { state, setup } = await stepUntilAsked(100, 30, scripted_batch_env)
  try {
    const frame = setup.captureCharFrame()
    expect(frame).toContain("1 of 3 in this batch")
    expect(frame).toContain("2 calls left in this batch")

    setup.mockInput.pressKey("2")
    setup.mockInput.pressEnter()
    // One keypress, three calls: nothing else is ever asked about, and all
    // three ran.
    await until(() => state.snapshot.items.filter((item) => item.kind === "tool" && item.resolved).length === 3, 60_000)
    expect(setup.captureCharFrame()).not.toContain("approve this call")
    const outputs = state.snapshot.items
      .filter((item) => item.kind === "tool" && item.resolved)
      .map((item) => (item.kind === "tool" ? item.output : ""))
      .join("\n")
    expect(outputs).toContain("batch-one")
    expect(outputs).toContain("batch-two")
    expect(outputs).toContain("batch-three")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

/** With one call in the turn there is no rest of the batch to offer. */
test("a lone call is not a batch", async () => {
  const { setup } = await stepUntilAsked()
  try {
    const frame = setup.captureCharFrame()
    expect(frame).not.toContain("in this batch")
    expect(frame).toContain("allow this call")
    expect(frame).toContain("1-4 choose")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

/**
 * The dialog answers to the mouse alone (tui.md §5.7): hovering a row moves the
 * cursor onto it, clicking it answers, and a note typed first rides along —
 * dropping it because the last gesture happened to be a click would be a small
 * betrayal of what was written.
 */
test("the pointer alone answers the dialog, note and all", async () => {
  const { id, state, setup } = await stepUntilAsked(100, 30)
  try {
    await setup.mockInput.typeText("prefer ls")
    await until(() => setup.captureCharFrame().includes("prefer ls"), 10_000)

    const rows = setup.captureCharFrame().split("\n")
    const at = rows.findIndex((row) => row.includes("always allow"))
    expect(at).toBeGreaterThanOrEqual(0)
    // A move first: the pointer is the cursor while it is over the list.
    await setup.mockMouse.moveTo(10, at)
    expect(await settle(setup, 2)).toContain("always allow")
    await setup.mockMouse.click(10, at)

    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved), 30_000)
    const call = state.snapshot.items.find((item) => item.kind === "tool" && item.resolved)!
    expect(call.kind === "tool" && call.ok).toBe(true)
    await until(async () => (await sessionEvents(ws, id)).some((event) => event.kind === "user_text" &&
      parseApprovalNote((event as { text: string }).text)?.text === "prefer ls"), 30_000)
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("a verdict is one line, and a note keeps its words but not its newlines", () => {
  expect(verdictLine({ allow: true })).toBe("allow\n")
  expect(verdictLine({ allow: false })).toBe("deny\n")
  expect(verdictLine({ allow: false, note: "" })).toBe("deny\n")
  expect(verdictLine({ allow: false, note: "not\nhere" })).toBe("deny not here\n")
})

test("a handoff file is the proposal, found by name and read once", () => {
  const id = "s-1787000000000-abcdef"
  mkdirSync(join(ws.dir, ".nulya", "handoffs"), { recursive: true })
  writeFileSync(join(ws.dir, ".nulya", "handoffs", `${id}-1.md`), "# Phase 1 done\n\nnext: write the note\n")
  writeFileSync(join(ws.dir, ".nulya", "handoffs", `${id}-2.md`), "# Phase 2 done\n")
  // Another session's proposals are not this session's.
  writeFileSync(join(ws.dir, ".nulya", "handoffs", "s-9999999999999-ffffff-1.md"), "# Somebody else\n")

  const found = handoffsFor(ws, id)
  expect(found.map((file) => file.index)).toEqual([1, 2])
  expect(headline(found[0]!.brief)).toBe("Phase 1 done")

  // The newest un-answered one is what gets offered, and answering it (which is
  // what `seen` records) leaves nothing to offer.
  expect(nextHandoff(ws, id, new Set())?.index).toBe(2)
  expect(nextHandoff(ws, id, new Set([`.nulya/handoffs/${id}-2.md`]))?.index).toBe(1)
  expect(nextHandoff(ws, id, new Set(found.map((file) => file.path)))).toBeNull()
})

/**
 * The handoff package's own way in (tui.md §5.8). It is a COMPILED package, so
 * a machine with no toolchain cannot build it — and then the session simply
 * starts without it, which is what this test would otherwise be asserting the
 * opposite of.
 */
test.skipIf(!Bun.which("zig"))("a session this TUI starts carries handoff, as a member and a pin", async () => {
  const shop = tempWorkspace()
  // A home of this test's own: installing `handoff` writes into the USER store
  // (that is the whole point — it works outside a nulya checkout), and the run's
  // shared home is read back by every test that lists extensions.
  const home = process.env["NULYA_HOME"]
  process.env["NULYA_HOME"] = mkdtempSync(join(tmpdir(), "nulya-tui-handoff-"))
  const setup = await testRender(
    () => (
      <App
        ws={shop}
        pick={{ profile: "scripted", model: "scripted-demo" }}
        style={ask_style}
        driver={{ env: scripted_env }}
        statePath={join(shop.dir, "tui-state.json")}
      />
    ),
    { width: 100, height: 24 },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("probe")
    setup.mockInput.pressEnter()
    // The first message is what creates the session (T22), and the build that
    // has to finish first is a real `zig build-exe` the first time.
    await until(async () => (await sessionList(shop)).length > 0, 180_000)
    const [session] = await sessionList(shop)
    // Two axes, both of them (DESIGN §7.5): membership, and a native slot.
    expect(session!.composition.active.some((ref) => ref.startsWith("handoff@"))).toBe(true)
    expect(session!.composition.native_tools).toContain("ext:handoff/handoff")
  } finally {
    setup.renderer.destroy()
    shop.cleanup()
    if (home === undefined) delete process.env["NULYA_HOME"]
    else process.env["NULYA_HOME"] = home
  }
}, 240_000)
