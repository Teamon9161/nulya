/**
 * `/model` (tui.md §11, T5 → T21): the picker over `nulya config show --json`,
 * the launch plan, and the one file the TUI writes (`tui-state.json`).
 *
 * Since T21 this screen is models and nothing else — keys, endpoints and the
 * add-provider form are `/provider` and are tested in `provider.test.tsx`,
 * including the handoff between the two.
 *
 * The picker is rendered against a hand-built ConfigView so its frames are
 * about layout and keys, and against the real binary once so the shape the
 * kernel actually prints is the shape the picker reads.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { createSignal, type JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { configShow, type ConfigView } from "../src/nulya/cli.ts"
import {
  AUTO,
  ModelView,
  initialSlot,
  labelOf,
  modelRows,
  pickableRows,
  pickerRows,
} from "../src/ui/overlays/ModelView.tsx"
import { blockedReason } from "../src/ui/overlays/providers.ts"
import { displayWidth } from "../src/ui/columns.ts"
import { planLaunch } from "../src/launch.ts"
import { loadTuiState, rememberModel, saveTuiState } from "../src/state/tui_state.ts"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { createSessionState } from "../src/state/session.ts"
import { sessionExists } from "../src/nulya/files.ts"
import { sessionList, sessionNew } from "../src/nulya/cli.ts"
import { App } from "../src/ui/App.tsx"
import type { ModelPick } from "../src/state/tui_state.ts"
import { fake_config, scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

const style: Style = createStyle(default_settings, {})

const fake = fake_config

let ws: TempWorkspace
beforeAll(() => {
  ws = tempWorkspace()
})
afterAll(() => ws.cleanup())

test("pickerRows: one row per (profile, model) in config order, dial = auto + the catalog levels", () => {
  const rows = pickerRows(fake)
  expect(rows.map((row) => `${row.profile.name}/${row.model}`)).toEqual([
    "openai/gpt-5.6-sol",
    "openai/gpt-5.6-luna",
    "deepseek/deepseek-v4-flash",
    "deepseek/deepseek-v4-pro",
    "codex/gpt-5.5",
    "scripted/scripted-demo",
  ])
  // A described id carries its dial; an undescribed one is bare, dial = auto only.
  expect(rows[0]!.slots).toEqual([AUTO, "low", "medium", "high"])
  expect(rows[1]!.params).toBeNull()
  expect(rows[1]!.slots).toEqual([AUTO])
  expect(rows[5]!.slots).toEqual([AUTO])

  // Where the dial starts: catalog default for a row that is not the current
  // pick, the profile's effort over the catalog's, the live effort for the
  // current pick, and auto when nothing says otherwise.
  expect(rows[0]!.slots[initialSlot(rows[0]!, null)]).toBe("medium")
  expect(rows[4]!.slots[initialSlot(rows[4]!, null)]).toBe("low")
  expect(rows[2]!.slots[initialSlot(rows[2]!, null)]).toBe(AUTO)
  const current: ModelPick = { profile: "deepseek", model: "deepseek-v4-flash", effort: "max" }
  expect(rows[2]!.slots[initialSlot(rows[2]!, current)]).toBe("max")
  expect(rows[3]!.slots[initialSlot(rows[3]!, current)]).toBe(AUTO)

  // The bare fact, without the remedy: which key fixes it depends on which
  // screen is showing it, so `blockedReason` does not pretend to know.
  expect(blockedReason(fake.profiles[0]!)).toBe("no key")
  expect(blockedReason(fake.profiles[2]!)).toBe("run `codex login`")
  expect(blockedReason(fake.profiles[1]!)).toBe("")
})

test("a profile's own catalog beats the global one: the same id is a different model behind a subscription", () => {
  // codex serves `gpt-5.6-sol` off a ChatGPT subscription: 258k of context and
  // an `xhigh` rung the public API does not have. The global `[[models]]` entry
  // for that very id says 1.05M and stops at `high`. Both are true — of
  // different endpoints — so the row takes its own endpoint's word.
  const config: ConfigView = {
    ...fake,
    profiles: [
      {
        ...fake.profiles[2]!,
        models: ["gpt-5.6-sol"],
        effort: null,
        catalog: [
          {
            id: "gpt-5.6-sol",
            label: "GPT-5.6 Sol",
            efforts: ["low", "medium", "high", "xhigh"],
            default_effort: "high",
            context_window: 258_400,
          },
        ],
      },
      fake.profiles[0]!,
    ],
  }
  const [codex] = modelRows(config, config.profiles[0]!)
  expect(codex!.params?.context_window).toBe(258_400)
  expect(codex!.slots).toEqual([AUTO, "low", "medium", "high", "xhigh"])
  expect(codex!.slots[initialSlot(codex!, null)]).toBe("high")

  // Another profile serving the same id has no catalog of its own, so it still
  // reads the global entry: one id, two honest answers.
  const [api] = modelRows(config, config.profiles[1]!)
  expect(api!.params?.context_window).toBe(1_050_000)
  expect(api!.slots).toEqual([AUTO, "low", "medium", "high"])
  expect(api!.slots[initialSlot(api!, null)]).toBe("medium")
  // The label is the same in both, which is exactly why the parameters have to
  // be right: nothing else on the row would give the difference away.
  expect(labelOf(codex!)).toBe(labelOf(api!))
})

test("pickableRows: only the providers that can run — plus the one in force, whatever its state", () => {
  // openai and codex have no credential: not a model row between them.
  expect(pickableRows(fake, null).map((row) => `${row.profile.name}/${row.model}`)).toEqual([
    "deepseek/deepseek-v4-flash",
    "deepseek/deepseek-v4-pro",
    "scripted/scripted-demo",
  ])
  // The pick in force stays on screen even after its key went away, so the
  // `current` mark has a row to sit on (Enter there says why it cannot run).
  expect(
    pickableRows(fake, { profile: "openai", model: "gpt-5.6-sol" }).map((row) => `${row.profile.name}/${row.model}`),
  ).toEqual(["openai/gpt-5.6-sol", "openai/gpt-5.6-luna", "deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-pro", "scripted/scripted-demo"])
})

async function pickerFrame(node: () => JSX.Element, width = 120, height = 30) {
  return testRender(() => <StyleContext.Provider value={style}>{node()}</StyleContext.Provider>, { width, height })
}

test("modelRows: a profile's ids become its rows, and a bare profile still offers its default", () => {
  expect(modelRows(fake, fake.profiles[1]!).map((row) => row.model)).toEqual([
    "deepseek-v4-flash",
    "deepseek-v4-pro",
  ])
  // A profile that lists no `models[]` still offers the one it defaults to.
  const bare = { ...fake.profiles[1]!, models: [] }
  expect(modelRows(fake, bare).map((row) => row.model)).toEqual(["deepseek-v4-flash"])
})

test("/model is models and only models: one row per runnable (provider, model), nothing about keys", async () => {
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={{ profile: "deepseek", model: "deepseek-v4-flash", effort: undefined }}
      onPick={() => {}}
      onNotice={() => {}}
      onOpenProviders={() => {}}
      onClose={() => {}}
      load={async () => fake}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("DeepSeek V4 Pro"), 10_000)
    const frame = await settle(setup, 4)
    expect(frame).toContain("model · what the next session runs on")
    // The models of the providers that can run, provider first on the row —
    // and NOT the models of the ones that cannot: no key, no row.
    expect(frame).toContain("deepseek  DeepSeek V4 Flash")
    expect(frame).toContain("deepseek-v4-pro")
    expect(frame).toContain("1M ctx")
    expect(frame).toContain("✓ current")
    expect(frame).not.toContain("GPT-5.6 Sol")
    expect(frame).not.toContain("gpt-5.5")
    // The offline stand-in is a row (it can run), and says so.
    expect(frame).toContain("scripted")
    expect(frame).toContain("offline")
    // T21: no providers row, and none of the provider keys are advertised here.
    // Credentials are a command of their own now, not the tail of this list.
    expect(frame).not.toContain("providers ·")
    expect(frame).not.toContain("s paste a key")
    expect(frame).not.toContain("no key")
    expect(frame).toContain("Enter starts a session")
    // The cursor opened on the pick in force, and its endpoint is the detail line.
    expect(frame).toContain("deepseek · openai wire · https://api.deepseek.com · DEEPSEEK_API_KEY set")
    expect(frame).toMatchSnapshot()
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("with no provider able to run, the list is one line pointing at /provider, and Enter goes there", async () => {
  const stranded: ConfigView = {
    ...fake,
    profiles: fake.profiles.filter((p) => p.kind !== "scripted").map((p) => ({ ...p, credential: false })),
  }
  const [asked, setAsked] = createSignal(0)
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={null}
      onPick={() => {}}
      onNotice={() => {}}
      onOpenProviders={() => setAsked(asked() + 1)}
      onClose={() => {}}
      load={async () => stranded}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("no provider can run yet"), 10_000)
    const frame = await settle(setup, 3)
    expect(frame).toContain("no provider can run yet · /provider to paste a key or add an endpoint")
    expect(frame).toContain("Enter · p opens /provider")
    // Both keys lead to the one screen that can change this.
    setup.mockInput.pressEnter()
    await until(() => asked() === 1, 10_000)
    setup.mockInput.pressKey("p")
    await until(() => asked() === 2, 10_000)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("the model table is cut to its columns at 76: one row each, a gutter that survives, nothing wraps", async () => {
  const notice = "openai has no API key · this session is the offline stand-in · pick a model that can run"
  const setup = await pickerFrame(
    () => (
      <ModelView
        ws={ws}
        current={null}
        notice={notice}
        onPick={() => {}}
        onNotice={() => {}}
        onOpenProviders={() => {}}
        onClose={() => {}}
        load={async () => fake}
      />
    ),
    76,
    30,
  )
  try {
    await until(() => setup.captureCharFrame().includes("DeepSeek V4 Pro"), 10_000)
    const frame = await settle(setup, 4)
    const lines = frame.split("\n").map((line) => line.replace(/\s+$/, ""))
    for (const line of lines) expect(displayWidth(line)).toBeLessThanOrEqual(76)

    // A model row is complete when its dial is on it; the two deepseek rows and
    // the stand-in each have theirs, and nothing wrapped a cell to a second line.
    expect(lines.filter((line) => /‹ \w+ ›|no dial/.test(line)).length).toBe(3)
    // The notice is broken at its joints, by us, one `<text>` per line.
    expect(frame).toContain("openai has no API key · this session is the offline stand-in")
    expect(frame).toContain("pick a model that can run")
    expect(frame).toMatchSnapshot()
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("the models level: ←→ turns the dial, Enter picks the row it is on", async () => {
  const [picked, setPicked] = createSignal<ModelPick | null>(null)
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={{ profile: "deepseek", model: "deepseek-v4-flash", effort: undefined }}
      onPick={setPicked}
      onNotice={() => {}}
      onOpenProviders={() => {}}
      onClose={() => {}}
      load={async () => fake}
    />
  ))
  try {
    // The cursor opens on the model in force.
    await until(() => setup.captureCharFrame().includes("DeepSeek V4 Pro"), 10_000)
    await settle(setup, 3)
    expect(setup.captureCharFrame()).toMatch(/▾ deepseek\s+DeepSeek V4 Flash/)

    // → twice turns flash's dial auto → off → low; ↓ then Enter picks pro on
    // ITS dial (auto).
    setup.mockInput.pressArrow("right")
    setup.mockInput.pressArrow("right")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).toContain("‹ low ›")
    setup.mockInput.pressArrow("down")
    await settle(setup, 2)
    setup.mockInput.pressEnter()
    await until(() => picked() !== null, 10_000)
    expect(picked()).toEqual({ profile: "deepseek", model: "deepseek-v4-pro", effort: undefined })

    // Back up onto flash (dial still on low) — the pick carries the effort.
    setup.mockInput.pressArrow("up")
    await settle(setup, 2)
    setup.mockInput.pressEnter()
    await until(() => picked()?.effort === "low", 10_000)
    expect(picked()).toEqual({ profile: "deepseek", model: "deepseek-v4-flash", effort: "low" })

    // Down past the last row stops there: this list has no tail row any more.
    for (let i = 0; i < 10; i++) setup.mockInput.pressKey("j")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).toMatch(/▾ scripted/)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("focusProfile: /provider hands a provider over and the cursor lands on its first model", async () => {
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={{ profile: "scripted", model: "scripted-demo", effort: undefined }}
      focusProfile="deepseek"
      onPick={() => {}}
      onNotice={() => {}}
      onOpenProviders={() => {}}
      onClose={() => {}}
      load={async () => fake}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("DeepSeek V4 Pro"), 10_000)
    const frame = await settle(setup, 3)
    // Not on the pick in force (scripted) — on the handed-over provider's first
    // model, which is what "choose a provider, then its model" has to mean.
    expect(frame).toMatch(/▾ deepseek\s+DeepSeek V4 Flash/)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("Enter on a row whose provider lost its key says why, and points at the screen that fixes it", async () => {
  const [notice, setNotice] = createSignal<string | null>(null)
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      // The pick in force is openai, which has no key: its rows are on screen
      // so the `current` mark has somewhere to sit, but Enter must not start.
      current={{ profile: "openai", model: "gpt-5.6-sol", effort: undefined }}
      onPick={() => setNotice("STARTED")}
      onNotice={setNotice}
      onOpenProviders={() => {}}
      onClose={() => {}}
      load={async () => fake}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("GPT-5.6 Sol"), 10_000)
    await settle(setup, 3)
    setup.mockInput.pressEnter()
    await until(() => notice() !== null, 10_000)
    expect(notice()).toBe("openai cannot run · no key · /provider to paste a key")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("configShow reads the real binary: scripted is always runnable, the catalog rides along", async () => {
  const config = await configShow(ws)
  expect(config.active_profile.length).toBeGreaterThan(0)
  const scripted = config.profiles.find((p) => p.name === "scripted")
  expect(scripted?.credential).toBe(true)
  const deepseek = config.profiles.find((p) => p.name === "deepseek")
  expect(deepseek?.api_key_env).toBe("DEEPSEEK_API_KEY")
  expect(deepseek?.models).toEqual(["deepseek-v4-flash", "deepseek-v4-pro"])
  const flash = config.models.find((m) => m.id === "deepseek-v4-flash")
  expect(flash?.efforts).toEqual(["off", "low", "high", "max"])
  // A profile that does not describe its own endpoint says so with null — and
  // a binary that has never heard of the field reads back the same way.
  expect(deepseek?.catalog ?? null).toBeNull()
  for (const p of config.profiles) {
    if (p.catalog === null) continue
    expect(Array.isArray(p.catalog)).toBe(true)
    for (const entry of p.catalog) expect(typeof entry.id).toBe("string")
  }
  // Every id a profile lists is described — by its own catalog, or by the
  // global one; the picker never shows a bare id for a built-in profile.
  for (const p of config.profiles) {
    if (p.kind === "scripted") continue
    const own = new Set((p.catalog ?? []).map((m) => m.id))
    for (const id of p.models) expect(own.has(id) || config.models.some((m) => m.id === id)).toBe(true)
  }
  // Never a secret: only env var NAMES.
  const text = JSON.stringify(config)
  expect(text).not.toContain("api_key\"")
})

test("planLaunch: flags > last pick > active profile, and nothing runnable means offline + the way to fix it", () => {
  // Explicit and runnable.
  expect(planLaunch({ profile: "deepseek", model: "deepseek-v4-pro" }, undefined, fake)).toEqual({
    pick: { profile: "deepseek", model: "deepseek-v4-pro", effort: undefined },
  })
  // Explicit but not runnable: refused with the reason, never substituted.
  expect(planLaunch({ profile: "openai" }, undefined, fake).refuse).toContain("openai has no API key")
  expect(planLaunch({ profile: "openai" }, undefined, fake).refuse).toContain("/provider")
  expect(planLaunch({ profile: "nope" }, undefined, fake).refuse).toContain("no profile named 'nope'")
  // The last pick, whole; a flag overrides one field of it.
  const last: ModelPick = { profile: "deepseek", model: "deepseek-v4-flash", effort: "high" }
  expect(planLaunch({}, last, fake)).toEqual({ pick: last })
  expect(planLaunch({ effort: "off" }, last, fake).pick?.effort).toBe("off")
  // The last pick lost its key → not the active profile either (no key) →
  // offline + a guide. Something else CAN run (deepseek), so the screen offered
  // is the one that lists it.
  const gone = planLaunch({}, { profile: "openai" }, fake)
  expect(gone.pick).toEqual({ profile: "scripted" })
  expect(gone.guide).toContain("openai has no API key")
  expect(gone.guide).toContain("offline stand-in")
  expect(gone.guideOn).toBe("model")
  // No memory, active profile has no key: same, blaming the active profile.
  expect(planLaunch({}, undefined, fake).guide).toContain("openai has no API key")
  // But with no real provider working at all, a list of models has nothing to
  // offer: the first screen is the one that takes a key (T21).
  const stranded: ConfigView = {
    ...fake,
    profiles: fake.profiles.map((p) => (p.kind === "scripted" ? p : { ...p, credential: false })),
  }
  const nothing = planLaunch({}, undefined, stranded)
  expect(nothing.guideOn).toBe("provider")
  expect(nothing.guide).toContain("paste a key, or add a compatible endpoint")
  // Active profile runnable: used.
  const ready = { ...fake, active_profile: "deepseek" }
  expect(planLaunch({}, undefined, ready)).toEqual({ pick: { profile: "deepseek", model: undefined, effort: undefined } })
})

test("tui-state remembers the last pick, tolerates absence and garbage, and is only ever whole", () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-tui-state-"))
  const path = join(dir, "nested", "tui-state.json")
  try {
    expect(loadTuiState(path)).toEqual({})
    rememberModel({ profile: "deepseek", model: "deepseek-v4-flash", effort: "high" }, path)
    expect(loadTuiState(path)).toEqual({ model: { profile: "deepseek", model: "deepseek-v4-flash", effort: "high" } })
    // Dropping the effort drops the key, not the pick.
    rememberModel({ profile: "deepseek", model: "deepseek-v4-flash" }, path)
    expect(loadTuiState(path)).toEqual({ model: { profile: "deepseek", model: "deepseek-v4-flash" } })
    // A broken file is "nothing remembered", and a save afterwards heals it.
    require("node:fs").writeFileSync(path, "{not json")
    expect(loadTuiState(path)).toEqual({})
    saveTuiState({ model: { profile: "codex" } }, path)
    expect(loadTuiState(path)).toEqual({ model: { profile: "codex" } })
    // A pick without a profile is no pick.
    require("node:fs").writeFileSync(path, JSON.stringify({ model: { model: "x" } }))
    expect(loadTuiState(path)).toEqual({})
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("picking in /model on a fresh untouched session replaces it in place; on a used one it opens a second tab", async () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-tui-state-"))
  const statePath = join(dir, "tui-state.json")
  const first = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(first)
  const setup = await testRender(
    () => (
      <App ws={ws} id={first} state={state} style={style} driver={{ env: scripted_env }} created statePath={statePath} />
    ),
    { width: 120, height: 24 },
  )
  try {
    await settle(setup, 3)
    // Open the picker and go to the bottom: scripted is the last profile in
    // default.toml and the only runnable one here without keys, so the last row
    // is its model whether or not this machine has a key in its environment.
    await setup.mockInput.typeText("/model")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("model · what the next session"), 15_000)
    for (let i = 0; i < 40; i++) setup.mockInput.pressKey("j")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).toMatch(/▾ scripted/)
    setup.mockInput.pressEnter()
    await until(() => !sessionExists(ws, first), 15_000)
    // The empty first session is gone — replaced, not stacked — and the pick is remembered.
    const frame = await settle(setup, 3)
    expect(frame).not.toContain(first)
    expect(loadTuiState(statePath).model).toEqual({ profile: "scripted", model: "scripted-demo", effort: undefined })
    const sessions = await sessionList(ws)
    const mine = sessions.filter((s) => s.id !== first)
    expect(mine.length).toBeGreaterThan(0)

    // Use the (new) session, then pick again: this time a second tab appears.
    await setup.mockInput.typeText("probe")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("done"), 60_000)
    await setup.mockInput.typeText("/model")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("model · what the next session"), 15_000)
    for (let i = 0; i < 40; i++) setup.mockInput.pressKey("j")
    await settle(setup, 2)
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("2/2") || /\[2\]|tab/.test(setup.captureCharFrame()), 15_000).catch(
      () => {},
    )
    const after = await sessionList(ws)
    expect(after.length).toBeGreaterThan(sessions.length)
  } finally {
    setup.renderer.destroy()
    rmSync(dir, { recursive: true, force: true })
  }
}, 120_000)

test("/effort sets this tab's effort: the header shows it and the next step is spawned with --effort", async () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-tui-state-"))
  const statePath = join(dir, "tui-state.json")
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} created statePath={statePath} />,
    { width: 120, height: 24 },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("/effort high")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("effort high"), 10_000)
    expect(setup.captureCharFrame()).toContain("· effort high ·")
    expect(loadTuiState(statePath).model?.effort).toBe("high")
    // The scripted provider ignores effort, but the flag must not break the
    // step: the run still completes.
    await setup.mockInput.typeText("probe")
    setup.mockInput.pressEnter()
    await until(() => state.snapshot.lastStopped !== null, 60_000)
    expect(state.snapshot.error).toBeNull()
    await setup.mockInput.typeText("/effort auto")
    setup.mockInput.pressEnter()
    await until(() => !setup.captureCharFrame().includes("· effort high ·"), 10_000)
  } finally {
    setup.renderer.destroy()
    rmSync(dir, { recursive: true, force: true })
  }
}, 120_000)

test("a guide opens the picker first, with the reason on screen and the composer out of the way", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        id={id}
        state={state}
        style={style}
        driver={{ env: scripted_env }}
        created
        guide="openai has no API key · this session is the offline stand-in"
      />
    ),
    { width: 120, height: 24 },
  )
  try {
    await until(() => setup.captureCharFrame().includes("model · what the next session"), 15_000)
    const frame = await settle(setup, 3)
    expect(frame).toContain("model · what the next session runs on")
    expect(frame).toContain("openai has no API key")
    // j moves the picker; nothing is typed into the composer.
    setup.mockInput.pressKey("j")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).not.toMatch(/›\s*j\s*$/m)
    // Esc leaves the picker; the session underneath is the offline one.
    setup.mockInput.pressEscape()
    await settle(setup, 3)
    expect(setup.captureCharFrame()).toContain("scripted")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a guide can open on /provider instead, when there is no model anywhere to list", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        id={id}
        state={state}
        style={style}
        driver={{ env: scripted_env }}
        created
        guide="openai has no API key · this session is the offline stand-in · paste a key, or add a compatible endpoint"
        guideOn="provider"
      />
    ),
    { width: 120, height: 24 },
  )
  try {
    await until(() => setup.captureCharFrame().includes("providers · keys and endpoints"), 15_000)
    const frame = await settle(setup, 3)
    expect(frame).toContain("openai has no API key")
    expect(frame).toContain("s paste a key")
    setup.mockInput.pressEscape()
    await settle(setup, 3)
    expect(setup.captureCharFrame()).not.toContain("providers · keys and endpoints")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)
