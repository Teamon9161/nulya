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
import { sessionList, sessionNew } from "../src/nulya/cli.ts"
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
    // panel above the composer says what the answers are and where to give one.
    const frame = setup.captureCharFrame()
    expect(frame).toContain("echo hello-from-nulya")
    expect(frame).toContain("waiting for you")
    expect(frame).toContain("allow this call")
    expect(frame).toContain("deny")
    // Nothing ran while it waited.
    expect(state.snapshot.items.some((item) => item.kind === "tool" && item.resolved)).toBe(false)

    setup.mockInput.pressKey("y")
    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved), 30_000)
    const call = state.snapshot.items.find((item) => item.kind === "tool" && item.resolved)!
    expect(call.kind === "tool" && call.output).toContain("hello-from-nulya")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("`N` denies with a typed reason, and the model is told exactly that", async () => {
  const { state, setup } = await stepUntilAsked()
  try {
    setup.mockInput.pressKey("N", { shift: true })
    await until(() => setup.captureCharFrame().includes("type the reason"), 10_000)
    await setup.mockInput.typeText("not on this machine")
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

test("switching to auto while a card is up decides that card too", async () => {
  const { state, setup } = await stepUntilAsked()
  try {
    // The prompt holds the kernel, and the composer still takes a command —
    // which is why the four answer keys only act on an EMPTY box: `/mode auto`
    // has an `a` in it, and losing it to "always allow" would make the one
    // command somebody reaches for here impossible to type.
    await setup.mockInput.typeText("/mode auto")
    expect(await settle(setup, 2)).toContain("/mode auto")
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
 * A turn with three calls in it (tui.md §5.7). The kernel offers them one at a
 * time — call N only once N-1 has run — so `A` is a decision about the calls a
 * person can SEE, all three already on screen as cards, rather than a promise
 * about anything the model has not written yet.
 */
test("`A` answers the rest of the batch, and the batch says how many are left", async () => {
  const { state, setup } = await stepUntilAsked(100, 30, scripted_batch_env)
  try {
    const frame = setup.captureCharFrame()
    expect(frame).toContain("1 of 3 in this batch")
    expect(frame).toContain("2 calls left in this batch")

    setup.mockInput.pressKey("A", { shift: true })
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
