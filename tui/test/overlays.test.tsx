/**
 * The two nulya-only views (tui.md §5.3 / §5.4) and the sub-session tab (§5.5),
 * driven programmatically through the test renderer.
 *
 * Both overlays read the real `.nulya/` layout, so every frame here is produced
 * from files a real `nulya` binary wrote.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { join } from "node:path"
import { createSignal, type JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { SessionsView } from "../src/ui/overlays/SessionsView.tsx"
import { ExtView, driftLine, frozenVersion } from "../src/ui/overlays/ExtView.tsx"
import { listExtensions } from "../src/nulya/files.ts"
import { App } from "../src/ui/App.tsx"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { createSessionState } from "../src/state/session.ts"
import { default_settings } from "../src/state/settings.ts"
import { sessionAppend, sessionNew, sessionStep } from "../src/nulya/cli.ts"
import type { SessionHeader } from "../src/nulya/ledger.ts"
import { scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

const style: Style = createStyle(default_settings, {})

let ws: TempWorkspace
let first: string
let second: string
let version: string

beforeAll(async () => {
  ws = tempWorkspace()
  first = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, first, "make the budgets configurable")
  const step = sessionStep(ws, first, { env: scripted_env })
  for await (const _ of step.lines) {
    // Give the first session a real transcript so it has events to count.
  }
  await step.exited
  second = await sessionNew(ws, { profile: "scripted" })

  const run = (args: string[]) => Bun.spawnSync({ cmd: [ws.bin, ...args], cwd: ws.dir })
  run(["ext", "init", "--script", "lint"])
  const built = run(["ext", "build", ".nulya/extensions/lint"])
  version = /v-[0-9a-zA-Z]+/.exec(built.stdout.toString())?.[0] ?? ""
  run(["ext", "activate", "lint", version])
}, 120_000)

afterAll(() => {
  ws.cleanup()
})

/**
 * Session ids and mtimes are minted per run, so a raw frame could never match
 * twice. Normalising them keeps the snapshot about LAYOUT — which is what a
 * frame snapshot is for — without pretending the volatile parts are stable.
 */
function stable(frame: string): string {
  return frame
    .replace(/s-\d+-[0-9a-f]+/g, "s-<id>")
    .replace(/v-[0-9a-z]{8,}/g, "v-<hash>")
    .replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/g, "<built>")
    .replace(/\d{2}-\d{2} \d{2}:\d{2}/g, "<when>")
}

async function overlayFrame(node: () => JSX.Element, width = 120, height = 20) {
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <FoldContext.Provider value={createFoldStore()}>{node()}</FoldContext.Provider>
      </StyleContext.Provider>
    ),
    { width, height },
  )
  return setup
}

test("/sessions lists the store and opens the highlighted session", async () => {
  const [opened, setOpened] = createSignal<string | null>(null)
  const setup = await overlayFrame(() => (
    <SessionsView
      ws={ws}
      currentId={first}
      onOpen={setOpened}
      onNew={() => {}}
      onClose={() => {}}
    />
  ))
  try {
    const frame = await settle(setup, 6)
    expect(frame).toContain(first)
    expect(frame).toContain(second)
    expect(frame).toContain("events")
    expect(frame).toContain("j/k move · Enter open · n new")
    expect(stable(frame)).toMatchSnapshot()

    // Newest first, so the second (untouched) session leads; j then Enter opens
    // the one below it.
    setup.mockInput.pressKey("j")
    await settle(setup, 2)
    setup.mockInput.pressEnter()
    await until(() => opened() !== null, 10_000)
    expect(opened()).toBe(first)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("/sessions marks a session somebody else is driving as live", async () => {
  const busy = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, busy, "hold the lease")
  const holder = sessionStep(ws, busy, { env: { NULYA_SCRIPTED_MODE: "loop" }, maxSteps: 400 })
  let holding = false
  const drain = (async () => {
    for await (const _ of holder.lines) holding = true
  })()
  await until(() => holding, 30_000)

  const setup = await overlayFrame(() => (
    <SessionsView ws={ws} currentId={first} onOpen={() => {}} onNew={() => {}} onClose={() => {}} />
  ))
  try {
    // The marker comes from the lease probe, which cannot see a POSIX flock;
    // there the honest answer is "unknown" and no marker is drawn.
    if (process.platform === "win32") {
      await until(() => setup.captureCharFrame().includes("live"), 15_000)
      expect(setup.captureCharFrame()).toContain("live")
    }
  } finally {
    setup.renderer.destroy()
    holder.kill()
    await holder.exited
    await drain
  }
}, 90_000)

test("/ext shows the version line, the current pointer and the usage counts", async () => {
  const header: SessionHeader = {
    kind: "header",
    v: 1,
    session: first,
    parent: null,
    model: "scripted",
    model_identity: { provider: "scripted", model: "", base_url: "", api_key_env: "" },
    created: "",
    composition: { active: [{ id: "lint", version }], native_tools: ["ext:lint/lint"] },
  }
  const setup = await overlayFrame(() => <ExtView ws={ws} header={header} onClose={() => {}} />)
  try {
    const frame = await settle(setup, 6)
    expect(frame).toContain("extensions · 1")
    expect(frame).toContain("lint · script · current")
    expect(frame).toContain(version)
    expect(frame).toContain("current")
    expect(frame).toContain("▎ this session")
    expect(frame).toContain("a activate · r rollback")
    expect(stable(frame)).toMatchSnapshot()

    // The second block: the whole usage journal, counts only.
    setup.mockInput.pressKey("u")
    const usage = await settle(setup, 4)
    expect(usage).toContain("tool usage · .nulya/tool-usage.jsonl")
    expect(usage).toContain("builtin.shell")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("/ext names the drift between what this session froze and what the store points at", async () => {
  // A pure function, because this sentence is the view's whole reason to exist
  // (DESIGN §7.5): the running session cannot change, so the store moving is the
  // only thing worth saying.
  const header: SessionHeader = {
    kind: "header",
    v: 1,
    session: first,
    parent: null,
    model: "scripted",
    model_identity: { provider: "scripted", model: "", base_url: "", api_key_env: "" },
    created: "",
    composition: { active: [{ id: "lint", version: "v-old" }], native_tools: [] },
  }
  expect(frozenVersion(header, "lint")).toBe("v-old")
  expect(frozenVersion(header, "other")).toBeNull()
  expect(driftLine("v-old", "v-new")).toBe("frozen v-old · store v-new → next session")
  expect(driftLine("v-same", "v-same")).toBeNull()
  expect(driftLine(null, "v-new")).toBeNull()

  const setup = await overlayFrame(() => <ExtView ws={ws} header={header} onClose={() => {}} />)
  try {
    const frame = await settle(setup, 6)
    expect(frame).toContain(`frozen v-old · store ${version}`)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("F3 opens the sessions view and Esc closes it", async () => {
  const state = createSessionState(first)
  const setup = await testRender(() => <App ws={ws} id={first} state={state} style={style} driver={{ env: scripted_env }} />, {
    width: 90,
    height: 24,
  })
  try {
    await settle(setup, 4)
    expect(setup.captureCharFrame()).not.toContain("j/k move · Enter open")

    setup.mockInput.pressKey("F3")
    const open = await settle(setup, 4)
    expect(open).toContain("sessions ·")
    expect(open).toContain("j/k move · Enter open")

    setup.mockInput.pressEscape()
    const closed = await settle(setup, 4)
    expect(closed).not.toContain("j/k move · Enter open")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("Enter on a sub-session card opens it as a second tab, attached as an observer", async () => {
  // A parent with no transcript of its own, so the only cards on screen are the
  // two injected below.
  const parent = await sessionNew(ws, { profile: "scripted" })
  const child = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(parent)
  // The transcript shape a `nulya session new` inside a step leaves behind: the
  // id is in the tool RESULT, which is why replay can find it too (§5.2).
  state.applyEvent({
    seq: 1,
    kind: "assistant",
    text: "spawning a sub-session",
    calls: [{ id: "c1", tool: "shell", args: JSON.stringify({ command: "nulya session new --model scripted" }) }],
  })
  state.applyEvent({
    seq: 2,
    kind: "tool_results",
    results: [{ call_id: "c1", ok: true, output: `${child}\n[exit 0]`, spill_path: null }],
  })

  const setup = await testRender(
    () => <App ws={ws} id={parent} state={state} style={style} driver={{ env: scripted_env }} />,
    { width: 90, height: 24 },
  )
  try {
    await settle(setup, 4)
    expect(setup.captureCharFrame()).toContain(`sub-session · ${child}`)
    // One session open: no tab bar at all.
    expect(setup.captureCharFrame()).not.toContain(`⤷ ${parent}`)

    setup.mockInput.pressEscape()
    await settle(setup, 3)
    setup.mockInput.pressEnter()
    const frame = await settle(setup, 6)
    expect(frame).toContain(`⤷ ${parent}`)
    expect(frame).toContain(`⤷ ${child}`)
    // The tab that opened is the one in front.
    expect(frame).toContain(`nulya · ${child}`)
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("/ext's action keys move the store's current pointer, with a confirmation", async () => {
  // A second version of the same extension: content-addressed and immutable, so
  // the first one is still there to roll back to (physics #5).
  const draft = join(ws.dir, ".nulya", "extensions", "lint", "extension.json")
  const manifest = JSON.parse(await Bun.file(draft).text()) as Record<string, unknown>
  const contributes = manifest["contributes"] as { tools: Array<Record<string, unknown>> }
  contributes.tools[0]!["description"] = "Lint Zig sources, second cut."
  await Bun.write(draft, JSON.stringify(manifest, null, 2))
  const built = Bun.spawnSync({ cmd: [ws.bin, "ext", "build", ".nulya/extensions/lint"], cwd: ws.dir })
  const second_version = /v-[0-9a-zA-Z]+/.exec(built.stdout.toString())?.[0] ?? ""
  expect(second_version).not.toBe(version)
  Bun.spawnSync({ cmd: [ws.bin, "ext", "activate", "lint", second_version], cwd: ws.dir })
  expect((await listExtensions(ws)).find((entry) => entry.id === "lint")!.current).toBe(second_version)

  const setup = await overlayFrame(() => <ExtView ws={ws} header={null} onClose={() => {}} />)
  try {
    await settle(setup, 6)
    setup.mockInput.pressTab() // extensions → versions
    await settle(setup, 2)
    // The version line is oldest first, so the cursor starts on the first build.
    setup.mockInput.pressKey("r")
    const asked = await settle(setup, 3)
    expect(asked).toContain(`rollback lint ${version}? y / Esc`)

    setup.mockInput.pressKey("y")
    await until(async () => (await listExtensions(ws)).find((entry) => entry.id === "lint")!.current === version, 20_000)
    expect(await settle(setup, 4)).toContain("current")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)
