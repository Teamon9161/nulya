/**
 * The two nulya-only views (tui.md §5.3 / §5.4) and the sub-session tab (§5.5),
 * driven programmatically through the test renderer.
 *
 * Both overlays read the real `.nulya/` layout, so every frame here is produced
 * from files a real `nulya` binary wrote.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { createSignal, type JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { SessionsView, ago, title } from "../src/ui/overlays/SessionsView.tsx"
import {
  ExtView,
  driftLine,
  frozenVersion,
  labelOf,
  shortVersion,
  standingCell,
  toolRows,
} from "../src/ui/overlays/ExtView.tsx"
import { displayWidth } from "../src/ui/columns.ts"
import { listExtensions, readHeader } from "../src/nulya/files.ts"
import { loadTuiState, sessionPins } from "../src/state/tui_state.ts"
import { App } from "../src/ui/App.tsx"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { createSessionState } from "../src/state/session.ts"
import { default_settings } from "../src/state/settings.ts"
import { sessionAppend, sessionNew, sessionStep, taskList, type TaskEntry } from "../src/nulya/cli.ts"
import { TasksView } from "../src/ui/overlays/TasksView.tsx"
import type { SessionHeader } from "../src/nulya/ledger.ts"
import { unsafe_settings, frameLines, scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

const style: Style = createStyle(unsafe_settings, {})

let ws: TempWorkspace
let first: string
let second: string
let blank: string
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
  await sessionAppend(ws, second, "rename the toolchain flag")
  const second_step = sessionStep(ws, second, { env: scripted_env })
  for await (const _ of second_step.lines) {
    // Drained for the same reason as the first.
  }
  await second_step.exited
  // A session nothing was ever said into: it exists on disk and is NOT a row
  // (`sessionKind`), which is what the assertions below pin.
  blank = await sessionNew(ws, { profile: "scripted" })

  const run = (args: string[]) => Bun.spawnSync({ cmd: [ws.bin, ...args], cwd: ws.dir, env: process.env })
  run(["ext", "init", "--script", "lint"])
  // The template writes no `surface`, which now means `auto` — a tool the model
  // gets with membership and that no pin may name (DESIGN §7.2.1, T52). These
  // tests are about PINNING, so the fixture says `manual` out loud.
  const lint_draft = join(ws.dir, ".nulya", "extensions", "lint", "extension.json")
  const lint_manifest = JSON.parse(readFileSync(lint_draft, "utf8")) as {
    contributes: { tools: Array<Record<string, unknown>> }
  }
  lint_manifest.contributes.tools[0]!["surface"] = "manual"
  writeFileSync(lint_draft, JSON.stringify(lint_manifest, null, 2))
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
    // Trailing blanks are not layout: a session id's hash is not a fixed length,
    // so the row's last cell moves and the padding after it moves with it. That
    // was a snapshot that failed on the shape of a random number (tui.md §11,
    // T12 "偶发一个尾空格差异").
    .replace(/[ ]+$/gm, "")
    .replace(/s-\d+-[0-9a-f]+/g, "s-<id>")
    .replace(/v-[0-9a-z]{8,}/g, "v-<hash>")
    // `registry.max_tools` is the kernel's default, not this view's layout: a
    // snapshot that bakes it in fails the day the kernel picks a new number.
    .replace(/tools (\d)\+(\d+)\/\d+/g, "tools $1+$2/<max>")
    .replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/g, "<built>")
    // How long ago is a moving target by construction: a slow `beforeAll` turns
    // `just now` into `1m ago`. The layout is what the snapshot is about.
    .replace(/just now|\d+[mhd] ago|(?<![\d-])\d{2}-\d{2}(?![\d-])/g, "<when>")
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
      workspaces={[ws]}
      currentId={first}
      onSwitch={setOpened} onOpenTab={() => {}}
      onNew={() => {}}
      onClose={() => {}}
    />
  ))
  try {
    const frame = await settle(setup, 6)
    // A row is the sentence that started the session (T47): what was asked
    // first, and how long ago. The id is unreadable and only sometimes needed,
    // so it is printed once, in the title line, for the row under the cursor —
    // which starts on the newest listed session.
    expect(frame).toContain("make the budgets configurable")
    expect(frame).toContain("rename the toolchain flag")
    expect(frame).toContain(second)
    expect(frame).not.toContain(first)
    // The session nothing was said into is not a row — and the line at the
    // bottom says so, because a list quietly shorter than the store is lying.
    expect(frame).not.toContain(blank)
    expect(frame).toContain("1 empty session not listed")
    expect(frame).not.toContain("events")
    // One line of keys, the rest behind `?` (tui.md §11, T18) — with what the
    // list is not drawing said between them.
    expect(frame).toContain("j/k move · Enter go there · t new tab · Esc close ·")
    expect(frame).toContain("? keys")
    expect(frame).not.toContain("n new")
    expect(stable(frame)).toMatchSnapshot()

    setup.mockInput.pressKey("?")
    expect(await settle(setup, 3)).toContain("n new")
    setup.mockInput.pressKey("?")
    expect(await settle(setup, 3)).not.toContain("n new")

    // Newest first, so the second (untouched) session leads; j then Enter goes
    // to the one below it.
    setup.mockInput.pressKey("j")
    // The title line follows the cursor, so this is where the id of the session
    // about to be opened becomes readable (and pasteable).
    expect(await settle(setup, 2)).toContain(first)
    setup.mockInput.pressEnter()
    await until(() => opened() !== null, 10_000)
    expect(opened()).toBe(first)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("how long ago is said the way a person says it", () => {
  // The row is a sentence and this is the only number left on it (T47), so the
  // boundaries are pinned: a timestamp nobody has to subtract today's date from,
  // and a date again once the distance stops being memorable.
  const now = Date.parse("2026-08-22T12:00:00Z")
  const back = (ms: number) => new Date(now - ms).toISOString()
  expect(ago(back(3_000), now)).toBe("just now")
  expect(ago(back(59_000), now)).toBe("just now")
  expect(ago(back(60_000), now)).toBe("1m ago")
  expect(ago(back(90 * 60_000), now)).toBe("1h ago")
  expect(ago(back(26 * 3600_000), now)).toBe("1d ago")
  expect(ago(back(6 * 86_400_000), now)).toBe("6d ago")
  // A week out, the distance is no longer the answer.
  expect(ago(back(8 * 86_400_000), now)).toMatch(/^\d{2}-\d{2}$/)
  // A clock that runs backwards (another machine's timestamp) is still now.
  expect(ago(new Date(now + 5_000).toISOString(), now)).toBe("just now")
  expect(ago("", now)).toBe("—")
  expect(ago("not a date", now)).toBe("—")
})

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
    <SessionsView workspaces={[ws]} currentId={first} onSwitch={() => {}} onOpenTab={() => {}} onNew={() => {}} onClose={() => {}} />
  ))
  try {
    // The marker comes from the lease probe — a byte-range read on Windows, a
    // /proc/locks lookup on Linux. Where neither exists (macOS) the honest
    // answer is "unknown" and no marker is drawn.
    if (process.platform === "win32" || process.platform === "linux") {
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
    environment: "",
    remote_workspace: "",
    created: "",
    composition: { active: [{ id: "lint", version }], native_tools: ["ext:lint/lint"], prompts: [] },
  }
  const setup = await overlayFrame(() => <ExtView ws={ws} header={header} onClose={() => {}} />)
  try {
    const frame = await settle(setup, 6)
    expect(frame).toContain("extensions · 1")
    // The switch, in words and as a marker: active, and how much of its tool
    // face is pinned (tui.md §11, T22).
    expect(frame).toContain("lint · script · active · tools 0/1 pinned")
    expect(frame).toContain("● lint")
    expect(frame).toContain(version)
    expect(frame).toContain("current")
    expect(frame).toContain("▎ this session")
    // The visible panes name themselves; the store actions are one `?` away.
    expect(frame).toContain("extensions  tools  usage")
    expect(frame).toContain("Enter active/inactive · j/k move · h/l pane · Esc close · ? keys")
    expect(frame).not.toContain("a activate one named version")
    expect(stable(frame)).toMatchSnapshot()

    setup.mockInput.pressKey("?")
    expect(await settle(setup, 3)).toContain("a activate one named version")
    setup.mockInput.pressKey("?")
    await settle(setup, 3)

    // The second block: the whole usage journal, counts only.
    setup.mockInput.pressKey("u")
    const usage = await settle(setup, 4)
    expect(usage).toContain("tool usage · .nulya/tool-usage.jsonl")
    expect(usage).toContain("builtin.shell")

    // The strip is a row of visible panes, so sideways keys walk it — and they
    // wrap both ways, which is the half `Tab` alone never had (T24).
    setup.mockInput.pressKey("h")
    expect(await settle(setup, 4)).toMatch(/tools 1\+0\/\d+/)
    setup.mockInput.pressKey("l")
    await settle(setup, 4)
    setup.mockInput.pressKey("l")
    const wrapped = await settle(setup, 4)
    expect(wrapped).toContain("● lint")
    expect(wrapped).not.toContain("tool usage · .nulya/tool-usage.jsonl")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("/ext at eighty columns: visible panes cut to their columns, the version id never", async () => {
  // An id nobody sized a fixed column for. It is also its own tool's name, so
  // one package gives the id list, the detail pane and the pin panel each a
  // cell that no reasonable column can hold.
  const long_id = "a-lint-with-a-very-long-extension-id"
  const run = (args: string[]) => Bun.spawnSync({ cmd: [ws.bin, ...args], cwd: ws.dir, env: process.env })
  run(["ext", "init", "--script", long_id])
  // `manual`, so the row this test measures is one the pin panel actually
  // draws: since T59 the collapsed list is the switches, and a scaffolded tool
  // is `auto` — it would fold away and take the cut cell with it.
  const long_draft = join(ws.dir, ".nulya", "extensions", long_id, "extension.json")
  const long_manifest = JSON.parse(readFileSync(long_draft, "utf8")) as {
    contributes: { tools: Array<Record<string, unknown>> }
  }
  long_manifest.contributes.tools[0]!["surface"] = "manual"
  writeFileSync(long_draft, JSON.stringify(long_manifest, null, 2))
  const built = run(["ext", "build", join(".nulya", "extensions", long_id)])
  const long_version = /v-[0-9a-zA-Z]+/.exec(built.stdout.toString())?.[0] ?? ""
  expect(long_version).not.toBe("")
  run(["ext", "activate", long_id, long_version])

  const setup = await overlayFrame(() => <ExtView ws={ws} header={null} onClose={() => {}} />, 76, 30)
  const fits = (frame: string) => {
    for (const line of frameLines(frame)) expect(displayWidth(line)).toBeLessThanOrEqual(76)
    return frame
  }
  try {
    await until(() => setup.captureCharFrame().includes("extensions ·"), 20_000)

    // Pane 1 — the id list. The long id is cut and the short one beside it still
    // reaches its next cell at the same offset: a gutter, not a coincidence.
    const ids = fits(await settle(setup, 6))
    expect(ids).toContain("…")
    expect(ids).not.toContain(long_id)
    const lines = frameLines(ids)
    const short = lines.find((line) => /[●○] lint {2,}\d\/\d tools/.test(line))
    expect(short).toBeDefined()
    // And no version hash on any of these rows (tui.md §11, T23): the list is
    // about whether to move something, not about which build it is.
    expect(lines.slice(0, 5).join("\n")).not.toContain(long_version)

    // The version line is part of the extension detail. The full id is under
    // the cursor and nowhere else: it is what somebody types into
    // `ext activate`, whole or useless.
    expect(ids).toContain(long_version)

    // Pane 2 — the pin panel. The checkbox keeps its place while the tool id
    // beside it is cut.
    setup.mockInput.pressKey("t")
    const tools = fits(await settle(setup, 4))
    expect(tools).toContain("[ ] ext:lint/lint")
    expect(tools).not.toContain(`ext:${long_id}/${long_id}`)
    expect(tools).toContain("…")

    // Pane 3 — the usage journal, counts in their own columns.
    setup.mockInput.pressKey("u")
    const usage = fits(await settle(setup, 4))
    expect(usage).toContain("tool usage · .nulya/tool-usage.jsonl")
  } finally {
    setup.renderer.destroy()
    // The other tests in this file count on `lint` being the only extension.
    rmSync(join(ws.dir, ".nulya", "extensions", long_id), { recursive: true, force: true })
  }
}, 120_000)

test("/ext's tools pane pins with a keypress, and the pin is what the next session carries", async () => {
  // The `this TUI` list lives in tui-state.json, so a scratch path here is the
  // whole isolation this needs: nothing else in the panel writes anything
  // without a confirmation key.
  const statePath = join(ws.dir, "pin-state.json")
  const setup = await overlayFrame(() => (
    <ExtView ws={ws} header={null} statePath={statePath} onClose={() => {}} />
  ))
  try {
    await settle(setup, 6)
    setup.mockInput.pressKey("t")
    const pane = await settle(setup, 4)
    // The quota's denominator is the kernel's `registry.max_tools` and this test
    // is about the numerator: the builtin, and what this panel adds to it.
    expect(pane).toMatch(/tools 1\+0\/\d+/)
    expect(pane).toContain("[ ] ext:lint/lint")

    setup.mockInput.pressKey(" ")
    const pinned = await settle(setup, 4)
    // On goes to `this TUI` first: a config file is one more key away (`A`).
    expect(pinned).toContain("[x] ext:lint/lint")
    expect(pinned).toContain("this TUI")
    expect(pinned).toMatch(/tools 1\+1\/\d+/)
    expect(sessionPins(statePath)).toEqual(["ext:lint/lint"])

    // And that list is the argv: the kernel freezes exactly it (physics #2).
    const pinnedSession = await sessionNew(ws, { profile: "scripted", pin: sessionPins(statePath) })
    expect((await readHeader(ws, pinnedSession))!.composition.native_tools).toContain("ext:lint/lint")

    setup.mockInput.pressKey(" ")
    await settle(setup, 4)
    expect(sessionPins(statePath)).toEqual([])
    const plain = await sessionNew(ws, { profile: "scripted", pin: sessionPins(statePath) })
    expect((await readHeader(ws, plain))!.composition.native_tools).not.toContain("ext:lint/lint")
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
    environment: "",
    remote_workspace: "",
    created: "",
    composition: { active: [{ id: "lint", version: "v-old" }], native_tools: [], prompts: [] },
  }
  expect(frozenVersion(header, "lint")).toBe("v-old")
  expect(frozenVersion(header, "other")).toBeNull()
  expect(driftLine("v-old", "v-new")).toBe("frozen v-old · store v-new → next session")
  expect(driftLine("v-same", "v-same")).toBeNull()
  expect(driftLine(null, "v-new")).toBeNull()

  const setup = await overlayFrame(() => <ExtView ws={ws} header={header} onClose={() => {}} />)
  try {
    const frame = await settle(setup, 6)
    // Short hashes in the sentence: it says two builds differ, and eight digits
    // say that as well as twenty-four (tui.md §11, T23).
    expect(frame).toContain(`frozen v-old · store ${shortVersion(version)}`)
    expect(shortVersion(version)).toHaveLength(10)
    // The whole id is still one line away, under the version the cursor is on.
    expect(frame).toContain(version)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("the tools pane folds the internal half away and says how much it folded", async () => {
  // A real internal-tool package in the store, and deliberately one this front
  // end has never heard of: what keeps its tool off the model's face is its own
  // manifest saying `"surface": "internal"` (DESIGN §7.2.1), not its id being on
  // a list in `extensions.ts` — which is exactly what a third party could not do
  // before T34. `ext init --script` names the tool after the id, so this row is
  // `ext:patrol/patrol`, sorted above the pinnable one by the letter p.
  const run = (args: string[]) => Bun.spawnSync({ cmd: [ws.bin, ...args], cwd: ws.dir, env: process.env })
  run(["ext", "init", "--script", "patrol"])
  const draft = join(ws.dir, ".nulya", "extensions", "patrol", "extension.json")
  const manifest = JSON.parse(readFileSync(draft, "utf8")) as {
    contributes: { tools: Array<Record<string, unknown>> }
  }
  manifest.contributes.tools[0]!["surface"] = "internal"
  writeFileSync(draft, JSON.stringify(manifest, null, 2))
  const built = run(["ext", "build", ".nulya/extensions/patrol"])
  const internal_version = /v-[0-9a-zA-Z]+/.exec(built.stdout.toString())?.[0] ?? ""
  run(["ext", "activate", "patrol", internal_version])

  const setup = await overlayFrame(() => <ExtView ws={ws} header={null} onClose={() => {}} />, 100, 24)
  try {
    await settle(setup, 6)
    setup.mockInput.pressKey("t")
    const folded = await settle(setup, 4)
    expect(folded).toContain("[ ] ext:lint/lint")
    expect(folded).not.toContain("ext:patrol/patrol")
    expect(folded).toContain("1 internal · ext run only · d shows")

    setup.mockInput.pressKey("d")
    const open = await settle(setup, 4)
    expect(open).toContain("ext:patrol/patrol")
    expect(open).toContain("internal · ext run")
    expect(open).toContain("d folds")

    setup.mockInput.pressKey("d")
    expect(await settle(setup, 4)).not.toContain("ext:patrol/patrol")
  } finally {
    setup.renderer.destroy()
    // The rest of this file counts on `lint` being the only extension.
    run(["ext", "deactivate", "patrol"])
    rmSync(join(ws.dir, ".nulya", "extensions", "patrol"), { recursive: true, force: true })
  }
}, 120_000)

test("an internal tool is listed with no checkbox: there is no pin for it to be wrong about", () => {
  // `compact` drives the session it is called ABOUT — it appends to it and
  // steps it — so a model calling it from inside that session meets the
  // kernel's writer lock every time (DESIGN §3.4). A checkbox beside it offered
  // a state that cannot work; the row now says who calls it instead (T24).
  //
  // WHICH tools those are is the package's own word since T34 (`surface`,
  // DESIGN §7.2.1) rather than a list of bundled ids here — so a package this
  // front end has never heard of gets the same treatment, and one that mixes
  // both kinds (the bundled `agent`) gets it per tool.
  const entry = (id: string, tools: string[], internalTools: string[] = []) => ({
    id,
    current: "v-1",
    versions: [],
    kind: "compiled" as const,
    tools,
    manualTools: tools.filter((tool) => !internalTools.includes(tool)),
    recommendedTools: tools.filter((tool) => !internalTools.includes(tool)),
    autoTools: [],
    internalTools,
    apply: "manual" as const,
    standing: false,
    skills: [],
    systemPrompts: [],
    commands: [],
    ui: null,
    root: "",
    shadowed: false,
  })
  const rows = toolRows(
    [
      entry("compact", ["compact"], ["compact"]),
      entry("agent", ["agent", "run"], ["run"]),
      entry("std", ["read"]),
    ],
    { user: [], session: [], merged: [] },
    [],
  )
  expect(rows.map((row) => [row.id, row.internal])).toEqual([
    // One package, both answers: the delegation entry point is the model's, the
    // command its background task runs is not.
    ["ext:agent/agent", false],
    ["ext:agent/run", true],
    ["ext:compact/compact", true],
    ["ext:std/read", false],
  ])
  expect(labelOf(rows[1]!)).toBe("internal · ext run")
  expect(labelOf(rows[0]!)).toBe("")
  // Pinned anyway — by hand, or by a driver's `--pin` — and the row goes back to
  // saying what the pin says: the state is real, and taking it off must work.
  expect(labelOf({ ...rows[1]!, state: "session" })).toBe("this TUI")
})

test("F3 opens the sessions view and Esc closes it", async () => {
  const state = createSessionState(first)
  const setup = await testRender(() => <App ws={ws} id={first} state={state} style={style} driver={{ env: scripted_env }} />, {
    width: 90,
    height: 24,
  })
  try {
    await settle(setup, 4)
    expect(setup.captureCharFrame()).not.toContain("j/k move · Enter go there")

    setup.mockInput.pressKey("F3")
    const open = await settle(setup, 4)
    expect(open).toContain("sessions ·")
    expect(open).toContain("j/k move · Enter go there")

    setup.mockInput.pressEscape()
    const closed = await settle(setup, 4)
    expect(closed).not.toContain("j/k move · Enter go there")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("t on a sub-session card opens it as a second tab, attached as an observer", async () => {
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
    // One session open: no tab bar at all, so the top row is not a strip.
    expect(setup.captureCharFrame().split("\n")[0]).not.toContain("scripted-demo")

    setup.mockInput.pressEscape()
    await settle(setup, 3)
    // `t`, not `Enter`: since T72 the primary gesture on this card watches the
    // session in a pane of THIS tab, and `t` is the one that gives it a tab —
    // the same pair of words the sessions list uses (T70).
    await setup.mockInput.typeText("t")
    const frame = await settle(setup, 6)
    // Two tabs, named by what they run on — the same model, so the `#n` that
    // tells them apart (tui.md §11, T22). Neither shows a session id, and the
    // one in front wears the left rule rather than a colour (T70).
    expect(frame).toContain("scripted-demo #1")
    expect(frame).toContain(`${style.glyphs.bar} scripted-demo #2`)
    expect(frame.split("\n")[0]).not.toContain(parent)
    // The tab that opened is the one in front: its transcript is the one drawn,
    // and the child has no cards of its own.
    expect(frame).not.toContain(`sub-session · ${child}`)
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
  const built = Bun.spawnSync({ cmd: [ws.bin, "ext", "build", ".nulya/extensions/lint"], cwd: ws.dir, env: process.env })
  const second_version = /v-[0-9a-zA-Z]+/.exec(built.stdout.toString())?.[0] ?? ""
  expect(second_version).not.toBe(version)
  Bun.spawnSync({ cmd: [ws.bin, "ext", "activate", "lint", second_version], cwd: ws.dir, env: process.env })
  expect((await listExtensions(ws)).find((entry) => entry.id === "lint")!.current).toBe(second_version)

  const setup = await overlayFrame(() => <ExtView ws={ws} header={null} onClose={() => {}} />)
  try {
    await settle(setup, 6)
    expect(setup.captureCharFrame()).toContain("versions · 2 · oldest → newest")
    // The version line is oldest first, so the cursor starts on the first build
    // — and pointing `current` back at it is the same verb as pointing it
    // forward, which is why there is only one key here (DESIGN §7.4).
    setup.mockInput.pressKey("a")
    const asked = await settle(setup, 3)
    expect(asked).toContain(`activate lint ${version}? y / Esc`)

    setup.mockInput.pressKey("y")
    await until(async () => (await listExtensions(ws)).find((entry) => entry.id === "lint")!.current === version, 20_000)
    expect(await settle(setup, 4)).toContain("current")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

/**
 * The half of the store `ext list` cannot see (tui.md §11, T22). An id with
 * source and no version is not in the kernel's listing — rightly, it holds
 * nothing — and before this it was invisible here too, which is how `std` sat
 * unbuilt in a user store for a week with no trace but a status line.
 */
test("/ext lists an id that is only source, says what is missing, and refuses to turn it on", async () => {
  const only_source = "source-only"
  const run = (args: string[]) => Bun.spawnSync({ cmd: [ws.bin, ...args], cwd: ws.dir, env: process.env })
  run(["ext", "init", "--script", only_source])
  // The kernel's own listing does not have it: no version, nothing held.
  expect((await listExtensions(ws)).some((entry) => entry.id === only_source)).toBe(false)

  const setup = await overlayFrame(() => <ExtView ws={ws} header={null} onClose={() => {}} />, 120, 26)
  try {
    await until(() => setup.captureCharFrame().includes(only_source), 20_000)
    const frame = await settle(setup, 4)
    // No versions, and the draft column says why there are none.
    expect(frame).toContain(`${only_source}`)
    expect(frame).toContain("not built")

    // The cursor starts on the first row; `lint` sorts before `source-only`.
    setup.mockInput.pressKey("j")
    await until(() => setup.captureCharFrame().includes("never been built"), 10_000)
    // What kind of package it is, and that it has nothing to point at, are in
    // the detail pane — the row itself only answers "should I turn this on".
    expect(setup.captureCharFrame()).toContain(`${only_source} · script · inactive`)
    // Enter cannot turn on what has no version, and says which key does.
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("has no built version"), 10_000)
    expect((await listExtensions(ws)).some((entry) => entry.id === only_source)).toBe(false)

    // `b` builds that one id, in the root its source lives in.
    setup.mockInput.pressKey("b")
    await until(async () => (await listExtensions(ws)).some((entry) => entry.id === only_source), 60_000)
    expect(await settle(setup, 4)).toContain("built · Enter turns it on")
  } finally {
    setup.renderer.destroy()
    rmSync(join(ws.dir, ".nulya", "extensions", only_source), { recursive: true, force: true })
  }
}, 120_000)

/**
 * What the panel draws about a version, and what it leaves out (tui.md §11,
 * T23). Pure, because "how much of this content address is worth reading" is a
 * decision, and one function makes it for every line on the screen.
 */
test("a version id is short everywhere but the one line it is typed from", () => {
  expect(shortVersion("v-0258f08e338c94179b855776")).toBe("v-0258f08e")
  // Shorter than the cut, and anything that is not a version id, pass through:
  // a truncation that invents a shape is worse than no truncation.
  expect(shortVersion("v-old")).toBe("v-old")
  expect(shortVersion("(none)")).toBe("(none)")
  expect(shortVersion(null)).toBe("")
  expect(shortVersion("v-0258f08e338c94179b855776", 6)).toBe("v-0258f0")
})

/**
 * The switch (tui.md §11, T22). One key, both axes: `current` moves and the
 * package's tools go on this TUI's pin list, and off again together — so the
 * pin list can never name an extension no session could resolve.
 */
test("/ext: Enter turns an extension on and off, and both axes move together", async () => {
  const statePath = join(ws.dir, "switch-state.json")
  const before = (await listExtensions(ws)).find((entry) => entry.id === "lint")!.current
  const setup = await overlayFrame(() => (
    <ExtView ws={ws} header={null} statePath={statePath} onClose={() => {}} />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("lint"), 20_000)
    await settle(setup, 4)
    // Active but nothing pinned: half on, and the row says which half.
    expect(setup.captureCharFrame()).toContain("0/1 tools")

    setup.mockInput.pressEnter()
    await until(() => sessionPins(statePath).includes("ext:lint/lint"), 20_000)
    const on = await settle(setup, 4)
    expect(on).toContain("lint · script · active · tools 1/1 pinned")
    expect(on).not.toContain("0/1 tools")
    expect((await listExtensions(ws)).find((entry) => entry.id === "lint")!.current).not.toBeNull()

    // And back: the pin goes first, then the pointer — so no moment of this
    // leaves a pin that `session new` would refuse.
    setup.mockInput.pressEnter()
    await until(async () => (await listExtensions(ws)).find((entry) => entry.id === "lint")!.current === null, 20_000)
    expect(sessionPins(statePath)).not.toContain("ext:lint/lint")
    expect(await settle(setup, 4)).toContain("lint · script · inactive")
  } finally {
    setup.renderer.destroy()
    if (before) {
      Bun.spawnSync({ cmd: [ws.bin, "ext", "activate", "lint", before], cwd: ws.dir, env: process.env })
    }
    rmSync(statePath, { force: true })
  }
}, 120_000)

/**
 * `/ext`'s Enter means exactly one thing: this package is now USABLE (tui.md
 * §11, T1, ext-review-2 §3b) — and since T52 it writes exactly two things, a
 * `current` and the package's `manual` pins.
 *
 * The bug T31 fixed: `evolution`'s prompt was in front of every model on the
 * machine, and nothing on the screen said so. The bug T1 fixed is what T31's
 * own fix grew into (K8): Enter on a mode wrote it onto a standing membership
 * list this front end kept, so turning `plan` on meant every session from then
 * on paid for its prompt. T52 removed that list outright — a package that
 * belongs in every session says `apply: "auto"` and the kernel composes it, for
 * every driver — so there is no third thing left for Enter to write.
 */
test("/ext Enter on a prompt package moves current and writes no membership of its own", async () => {
  const shop = tempWorkspace()
  try {
    const run = (args: string[]) => Bun.spawnSync({ cmd: [shop.bin, ...args], cwd: shop.dir, env: process.env })
    // A data package: a prompt and nothing else, which is exactly what a mode is.
    const home = join(shop.dir, ".nulya", "extensions", "house.style")
    Bun.spawnSync({ cmd: [shop.bin, "ext", "init", "house.style"], cwd: shop.dir, env: process.env })
    writeFileSync(
      join(home, "extension.json"),
      JSON.stringify({
        schema: "nulya.extension/v2",
        id: "house.style",
        contributes: { system_prompts: ["prompts/identity.md"] },
      }),
    )
    mkdirSync(join(home, "prompts"), { recursive: true })
    writeFileSync(join(home, "prompts", "identity.md"), "write in the house style\n")
    run(["ext", "build", join(".nulya", "extensions", "house.style")])

    const statePath = join(shop.dir, "mode-state.json")
    const setup = await overlayFrame(() => (
      <ExtView ws={shop} header={null} statePath={statePath} onClose={() => {}} />
    ))
    try {
      await until(() => setup.captureCharFrame().includes("house.style"), 20_000)
      const frame = await settle(setup, 4)
      // No `standing` cell: nothing recorded this package as a standing member,
      // so the one word in the id list that is about reach stays empty. The
      // cell reports the kernel's record, never a manifest's `apply` (T52/T56).
      expect(standingCell({ standing: false })).toBe("")
      // No declared command: the way in it names is `/with` (nothing derived).
      expect(frame).toContain("`/with house.style` wears its prompt")
      expect(frame).toContain("nothing here composes it standing")

      setup.mockInput.pressEnter()
      await until(
        async () => (await listExtensions(shop)).find((entry) => entry.id === "house.style")?.current != null,
        20_000,
      )
      const on = await settle(setup, 4)
      // The package declares no command, so nothing invents `/house.style`:
      // the notice points at `/with` (T54 — commands exist only by declaration).
      expect(on).toContain("/with house.style opens a new tab wearing it for one session")
      expect(on).toContain("Enter again takes that away")
      // The pointer moved — `current` says which version `house.style` is now
      // — and NOTHING was written into this front end's state: no pins (the
      // package declares no tool), and since T52 no membership list at all.
      expect(loadTuiState(statePath).session_pins ?? []).toEqual([])
      expect(JSON.stringify(loadTuiState(statePath))).not.toContain("house.style")

      setup.mockInput.pressEnter()
      await until(
        async () => (await listExtensions(shop)).find((entry) => entry.id === "house.style")?.current == null,
        20_000,
      )
      const off = await settle(setup, 4)
      expect(off).toContain("house.style inactive · it can no longer be worn")
      expect(off).toContain("versions all stay")
      // Still nothing in this front end's state to take back.
      expect(JSON.stringify(loadTuiState(statePath))).not.toContain("house.style")
    } finally {
      setup.renderer.destroy()
    }
  } finally {
    shop.cleanup()
  }
}, 120_000)

/**
 * A full tool face stops the PINS, never the activation (tui.md §11, T23).
 *
 * The bug this is for: six pins already down against `max_tools = 8`, and every
 * Enter on `compact` — which declares one tool — was refused whole, with
 * `2+9/8 · nothing changed` as the entire explanation. Membership and pins are
 * two axes and only one of them has a quota; `nulya ext run` reaches an active
 * package's tools with nothing on the native face at all, which is exactly how
 * `/compact` calls `compact`.
 */
test("/ext: a full tool face leaves the extension half on rather than refusing it", async () => {
  const full = tempWorkspace()
  try {
    const run = (args: string[]) => Bun.spawnSync({ cmd: [full.bin, ...args], cwd: full.dir, env: process.env })
    run(["ext", "init", "--script", "lint"])
    // A pinnable tool, said out loud: the template's silence means `auto` now,
    // and a quota is only about the pins (T52).
    const draft = join(full.dir, ".nulya", "extensions", "lint", "extension.json")
    const manifest = JSON.parse(readFileSync(draft, "utf8")) as {
      contributes: { tools: Array<Record<string, unknown>> }
    }
    manifest.contributes.tools[0]!["surface"] = "manual"
    writeFileSync(draft, JSON.stringify(manifest, null, 2))
    const built = run(["ext", "build", join(".nulya", "extensions", "lint")])
    expect(/v-[0-9a-zA-Z]+/.exec(built.stdout.toString())?.[0]).toBeDefined()
    // A face with no room in it at all: the builtin fills it.
    writeFileSync(join(full.dir, ".nulya", "config.toml"), "[registry]\nmax_tools = 1\n")

    const statePath = join(full.dir, "full-face.json")
    const setup = await overlayFrame(() => (
      <ExtView ws={full} header={null} statePath={statePath} onClose={() => {}} />
    ))
    try {
      await until(() => setup.captureCharFrame().includes("lint"), 20_000)
      await settle(setup, 4)
      setup.mockInput.pressEnter()
      // Activated: the half with no quota on it went through.
      await until(
        async () => (await listExtensions(full)).find((entry) => entry.id === "lint")?.current != null,
        20_000,
      )
      const frame = await settle(setup, 4)
      expect(frame).toContain("tool face is full")
      expect(frame).toContain("1 tool not pinned")
      // And the row says which half it is on, in the column that exists for it.
      expect(frame).toContain("0/1 tools")
      expect(sessionPins(statePath)).toEqual([])
    } finally {
      setup.renderer.destroy()
    }
  } finally {
    full.cleanup()
  }
}, 120_000)

/**
 * `/ext`'s push action (goals/remote-env.md §3.9, tui.md §11 T102). The
 * "remote" is a real channel — `remote:exec:` pointed at the same binary,
 * same trick the kernel's own e2e-remote uses — so this exercises the real
 * `nulya ext push` round trip, not a stand-in for it.
 */
test("/ext's r pushes the selected package's active version to this tab's remote target, and only when there is one", async () => {
  const remote = tempWorkspace()
  try {
    const run = (args: string[]) => Bun.spawnSync({ cmd: [remote.bin, ...args], cwd: remote.dir, env: process.env })
    run(["ext", "init", "--script", "pushable"])
    const built = run(["ext", "build", join(".nulya", "extensions", "pushable")])
    const pushed_version = /v-[0-9a-zA-Z]+/.exec(built.stdout.toString())?.[0] ?? ""
    expect(pushed_version).not.toBe("")
    run(["ext", "activate", "pushable", pushed_version])

    const spec = `remote:exec:${remote.bin} remote serve`
    const statePath = join(remote.dir, "push-state.json")

    // Not remote (no header, no pending `/env` choice in `statePath`): `r` is
    // not even in the footer, and pressing it does nothing the frame would show.
    const local = await overlayFrame(() => <ExtView ws={remote} header={null} statePath={statePath} onClose={() => {}} />)
    try {
      await settle(local, 5)
      local.mockInput.pressKey("?")
      const before = await settle(local, 2)
      expect(before).not.toContain("push the selected package")
      local.mockInput.pressKey("?")
      local.mockInput.pressKey("r")
      const after = await settle(local, 2)
      expect(after).not.toContain("pushed")
      expect(after).not.toContain("already there")
    } finally {
      local.renderer.destroy()
    }

    // A started session's header FREEZES its target — same rule `runsIn`
    // lives by — so this is what a real remote session's `ExtView` sees.
    const header: SessionHeader = {
      kind: "header",
      v: 1,
      session: "s-fake",
      parent: null,
      model: "scripted",
      model_identity: { provider: "scripted", model: "", base_url: "", api_key_env: "" },
      environment: spec,
      remote_workspace: remote.dir,
      created: "",
      composition: { active: [], native_tools: [], prompts: [] },
    }
    const setup = await overlayFrame(() => (
      <ExtView ws={remote} header={header} statePath={statePath} onClose={() => {}} />
    ))
    try {
      await settle(setup, 5)
      // `more` lines (the `r` hint among them) are one `?` away (T18); `r`
      // itself is not consumed by that toggle, so this both confirms the hint
      // is there AND leaves the panel ready for the keypress below.
      setup.mockInput.pressKey("?")
      const frame = await settle(setup, 2)
      expect(frame).toContain(`push the selected package's active version to ${spec}`)
      setup.mockInput.pressKey("r")
      // The kernel's own sentence — content-addressed, so it is "pushed" or
      // "already there" and never a made-up wording from this front end.
      await until(() => {
        const now = setup.captureCharFrame()
        return now.includes("pushed") || now.includes("already there")
      }, 20_000)
      const after = setup.captureCharFrame()
      expect(after).toContain("pushable")
      expect(after).toContain(pushed_version)
      // Remembered, and shown as "last time" on the next render — never as a
      // present-tense claim this front end cannot back up (T102's own choice).
      expect(await settle(setup, 3)).toContain("last time:")
    } finally {
      setup.renderer.destroy()
    }
  } finally {
    remote.cleanup()
  }
}, 120_000)

/**
 * `/tasks` (tui.md §5.9). Every column on a row is `nulya task list --json`,
 * so this drives the real binary: a background command is started, finishes,
 * and the panel says what became of it.
 */
test("/tasks lists this session's background commands and shows one's log", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  await sessionAppend(ws, id, "go")
  const step = sessionStep(ws, id, { env: { NULYA_SCRIPTED_MODE: "background" } })
  for await (const _ of step.lines) {
    // Drained so the child can exit.
  }
  await step.exited
  await until(async () => (await taskList(ws, id)).some((task) => task.state === "done"), 60_000)

  const [tasks, setTasks] = createSignal<TaskEntry[]>([])
  const refresh = async () => setTasks(await taskList(ws, id))
  await refresh()
  const setup = await overlayFrame(() => (
    <TasksView
      ws={ws}
      sessionId={id}
      tasks={tasks()}
      send={() => Promise.resolve()}
      onRefresh={() => void refresh()}
      onClose={() => {}}
    />
  ))
  try {
    const frame = await settle(setup, 4)
    expect(frame).toContain(`${id}/t1`)
    expect(frame).toContain("done")
    expect(frame).toContain("echo scripted-background-marker")
    expect(frame).toContain("↑↓ move · Enter log · k kill · Esc close")
    // Enter opens the log — the file the receipt named, not a second guess at
    // where output goes.
    setup.mockInput.pressEnter()
    const opened = await settle(setup, 8)
    expect(opened).toContain("output.log")
    expect(opened).toContain("scripted-background-marker")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("/tasks on a tab with no session says so instead of drawing an empty list", async () => {
  const setup = await overlayFrame(() => (
    <TasksView ws={ws} sessionId="" tasks={[]} send={() => Promise.resolve()} onRefresh={() => {}} onClose={() => {}} />
  ))
  try {
    const frame = await settle(setup, 3)
    expect(frame).toContain("this tab has no session yet")
    expect(frame).toContain("shell {background: true}")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)


test("/sessions names compact continuations without leaking the internal marker", () => {
  const entry = {
    first_user_text: "<nulya:context-summary> ## Next task ship the fix",
    parent: { session: "s-parent", seq: 4 },
  } as Parameters<typeof title>[0]
  expect(title(entry)).toBe("continued · Next task ship the fix")
  expect(title({ ...entry, parent: null })).toStartWith("<nulya:context-summary>")
})
