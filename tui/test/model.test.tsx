/**
 * `/model` (tui.md §11, T5): the picker over `nulya config show --json`, the
 * launch plan, and the one file the TUI writes (`tui-state.json`).
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
import { AUTO, ModelView, blockedReason, endpointOf, initialSlot, modelRows, pickerRows } from "../src/ui/overlays/ModelView.tsx"
import { planLaunch } from "../src/launch.ts"
import { loadTuiState, rememberModel, saveTuiState } from "../src/state/tui_state.ts"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { createSessionState } from "../src/state/session.ts"
import { listSessions, sessionExists } from "../src/nulya/files.ts"
import { sessionNew } from "../src/nulya/cli.ts"
import { App } from "../src/ui/App.tsx"
import type { ModelPick } from "../src/state/tui_state.ts"
import type { ProfileDraft } from "../src/nulya/credentials.ts"
import { scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

const style: Style = createStyle(default_settings, {})

/** A config the way `nulya config show --json` prints it, with one key present. */
const fake: ConfigView = {
  paths: { system: "/etc/nulya/config.toml", user: "/home/me/.nulya/config.toml", project: ".nulya/config.toml" },
  active_profile: "openai",
  profiles: [
    {
      name: "openai",
      kind: "openai",
      base_url: "https://api.openai.com/v1",
      api_key_env: "OPENAI_API_KEY",
      credential: false,
      credential_source: "none",
      model: "gpt-5.6-sol",
      models: ["gpt-5.6-sol", "gpt-5.6-luna"],
      effort: null,
    },
    {
      name: "deepseek",
      kind: "openai",
      base_url: "https://api.deepseek.com",
      api_key_env: "DEEPSEEK_API_KEY",
      credential: true,
      credential_source: "env",
      model: "deepseek-v4-flash",
      models: ["deepseek-v4-flash", "deepseek-v4-pro"],
      effort: null,
    },
    { name: "codex", kind: "codex", base_url: "", api_key_env: "", credential: false, credential_source: "none", model: "gpt-5.5", models: ["gpt-5.5"], effort: "low" },
    { name: "scripted", kind: "scripted", base_url: "", api_key_env: "", credential: true, credential_source: "builtin", model: "scripted-demo", models: ["scripted-demo"], effort: null },
  ],
  models: [
    { id: "gpt-5.6-sol", label: "GPT-5.6 Sol", efforts: ["low", "medium", "high"], default_effort: "medium", context_window: 1_050_000 },
    { id: "deepseek-v4-flash", label: "DeepSeek V4 Flash", efforts: ["off", "low", "high", "max"], default_effort: null, context_window: 1_000_000 },
    { id: "deepseek-v4-pro", label: "DeepSeek V4 Pro", efforts: ["off", "low", "high", "max"], default_effort: null, context_window: 1_000_000 },
    { id: "gpt-5.5", label: "GPT-5.5 (Codex)", efforts: ["off", "low", "medium", "high"], default_effort: null, context_window: null },
  ],
}

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

  expect(blockedReason(fake.profiles[0]!)).toBe("no key · s to paste one")
  expect(blockedReason(fake.profiles[2]!)).toBe("run `codex login`")
  expect(blockedReason(fake.profiles[1]!)).toBe("")
})

async function pickerFrame(node: () => JSX.Element, width = 120, height = 30) {
  return testRender(() => <StyleContext.Provider value={style}>{node()}</StyleContext.Provider>, { width, height })
}

/** A rejected field keeps its text so it can be fixed; this is "fix it all". */
function erase(setup: { mockInput: { pressBackspace: () => void } }, count: number) {
  for (let i = 0; i < count; i++) setup.mockInput.pressBackspace()
}

test("modelRows / endpointOf: a provider is one row, and it says what it is", () => {
  expect(modelRows(fake, fake.profiles[1]!).map((row) => row.model)).toEqual([
    "deepseek-v4-flash",
    "deepseek-v4-pro",
  ])
  // A profile that lists no `models[]` still offers the one it defaults to.
  const bare = { ...fake.profiles[1]!, models: [] }
  expect(modelRows(fake, bare).map((row) => row.model)).toEqual(["deepseek-v4-flash"])
  expect(endpointOf(fake.profiles[0]!)).toBe("openai wire · api.openai.com")
  expect(endpointOf(fake.profiles[2]!)).toBe("codex · ChatGPT subscription")
  expect(endpointOf(fake.profiles[3]!)).toBe("offline · no network")
})

test("/model level 1 is providers — one row each, credential status on the row", async () => {
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={{ profile: "deepseek", model: "deepseek-v4-flash", effort: undefined }}
      onPick={() => {}}
      onNotice={() => {}}
      onClose={() => {}}
      load={async () => fake}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("api.deepseek.com"), 10_000)
    const frame = await settle(setup, 4)
    expect(frame).toContain("model · which provider a session runs on")
    // One row per profile, and the models are NOT on this screen.
    expect(frame).toContain("2 models")
    expect(frame).toContain("openai wire · api.openai.com")
    expect(frame).not.toContain("DeepSeek V4 Flash")
    expect(frame).not.toContain("GPT-5.6 Sol")
    expect(frame).toContain("no key · s to paste one")
    expect(frame).toContain("run `codex login`")
    expect(frame).toContain("✓ current")
    expect(frame).toContain("offline stand-in")
    expect(frame).toContain("+ add an OpenAI- or Anthropic-compatible provider")
    expect(frame).toMatchSnapshot()
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("/model level 2 is that provider's models: ←→ turns the dial, Enter picks, Esc goes back", async () => {
  const [picked, setPicked] = createSignal<ModelPick | null>(null)
  const [blocked, setBlocked] = createSignal<string | null>(null)
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={{ profile: "deepseek", model: "deepseek-v4-flash", effort: undefined }}
      onPick={setPicked}
      onNotice={setBlocked}
      onClose={() => {}}
      load={async () => fake}
    />
  ))
  try {
    // The cursor opens on the provider in force; Enter drills into its models.
    await until(() => setup.captureCharFrame().includes("api.deepseek.com"), 10_000)
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("DeepSeek V4 Pro"), 10_000)
    const frame = await settle(setup, 3)
    expect(frame).toContain("model · deepseek · 2 models")
    expect(frame).toContain("1M ctx")
    expect(frame).toContain("✓ current")
    expect(frame).toMatchSnapshot()

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

    // Esc is one level, not the whole picker.
    setup.mockInput.pressEscape()
    await until(() => setup.captureCharFrame().includes("which provider"), 10_000)

    // A provider without a key is still browsable — its models carry the
    // reason, and Enter on one says it rather than starting a session.
    setup.mockInput.pressKey("k")
    await settle(setup, 2)
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("model · openai"), 10_000)
    expect(setup.captureCharFrame()).toContain("no key · s to paste one")
    setup.mockInput.pressEnter()
    await until(() => blocked() !== null, 10_000)
    expect(blocked()).toContain("openai cannot run yet · no key · s to paste one")
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
  // Every id a profile lists is described — the picker never shows a bare id
  // for a built-in profile.
  for (const p of config.profiles) {
    if (p.kind === "scripted") continue
    for (const id of p.models) expect(config.models.some((m) => m.id === id)).toBe(true)
  }
  // Never a secret: only env var NAMES.
  const text = JSON.stringify(config)
  expect(text).not.toContain("api_key\"")
})

test("planLaunch: flags > last pick > active profile, and nothing runnable means offline + the picker", () => {
  // Explicit and runnable.
  expect(planLaunch({ profile: "deepseek", model: "deepseek-v4-pro" }, undefined, fake)).toEqual({
    pick: { profile: "deepseek", model: "deepseek-v4-pro", effort: undefined },
  })
  // Explicit but not runnable: refused with the reason, never substituted.
  expect(planLaunch({ profile: "openai" }, undefined, fake).refuse).toContain("openai has no API key")
  expect(planLaunch({ profile: "nope" }, undefined, fake).refuse).toContain("no profile named 'nope'")
  // The last pick, whole; a flag overrides one field of it.
  const last: ModelPick = { profile: "deepseek", model: "deepseek-v4-flash", effort: "high" }
  expect(planLaunch({}, last, fake)).toEqual({ pick: last })
  expect(planLaunch({ effort: "off" }, last, fake).pick?.effort).toBe("off")
  // The last pick lost its key → not the active profile either (no key) → offline + guide.
  const gone = planLaunch({}, { profile: "openai" }, fake)
  expect(gone.pick).toEqual({ profile: "scripted" })
  expect(gone.guide).toContain("openai has no API key")
  expect(gone.guide).toContain("offline stand-in")
  // No memory, active profile has no key: same, blaming the active profile.
  expect(planLaunch({}, undefined, fake).guide).toContain("openai has no API key")
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
    // Open the picker, land on scripted (the only runnable row here without keys
    // is scripted, or codex if this machine is logged in — pick scripted by name).
    await setup.mockInput.typeText("/model")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("model · which provider"), 15_000)
    // Down clamps on the "+ add a provider" row; one back up is scripted, the
    // last profile in default.toml. Enter opens its models, Enter picks.
    for (let i = 0; i < 40; i++) setup.mockInput.pressKey("j")
    setup.mockInput.pressKey("k")
    await settle(setup, 2)
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("model · scripted"), 15_000)
    setup.mockInput.pressEnter()
    await until(() => !sessionExists(ws, first), 15_000)
    // The empty first session is gone — replaced, not stacked — and the pick is remembered.
    const frame = await settle(setup, 3)
    expect(frame).not.toContain(first)
    expect(loadTuiState(statePath).model).toEqual({ profile: "scripted", model: "scripted-demo", effort: undefined })
    const sessions = await listSessions(ws)
    const mine = sessions.filter((s) => s.id !== first)
    expect(mine.length).toBeGreaterThan(0)

    // Use the (new) session, then pick again: this time a second tab appears.
    await setup.mockInput.typeText("probe")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("done"), 60_000)
    await setup.mockInput.typeText("/model")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("model · which provider"), 15_000)
    for (let i = 0; i < 40; i++) setup.mockInput.pressKey("j")
    setup.mockInput.pressKey("k")
    await settle(setup, 2)
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("model · scripted"), 15_000)
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("2/2") || /\[2\]|tab/.test(setup.captureCharFrame()), 15_000).catch(
      () => {},
    )
    const after = await listSessions(ws)
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
    await until(() => setup.captureCharFrame().includes("model · which provider"), 15_000)
    const frame = await settle(setup, 3)
    expect(frame).toContain("model · which provider")
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

test("credentials: a pasted key lands as a marked block in the user config, replaced in place next time, the rest untouched", () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-home-"))
  const path = join(dir, "config.toml")
  try {
    const { writeProfileKey, keyBlock } = require("../src/nulya/credentials.ts")
    // A fresh file (directory exists, file does not).
    const first = writeProfileKey(path, "deepseek", "sk-one")
    expect(first).toBe(keyBlock("deepseek", "sk-one"))
    // A human's content stays; our block is appended after a blank line.
    require("node:fs").writeFileSync(path, `# mine\n[provider]\nactive_profile = "deepseek"\n`)
    const appended = writeProfileKey(path, "deepseek", "sk-one")
    expect(appended.startsWith(`# mine\n[provider]\nactive_profile = "deepseek"\n\n# nulya: api_key for profile "deepseek"`)).toBe(true)
    // A second profile is a second block; rotating the first replaces it in place.
    writeProfileKey(path, "openrouter", "sk-or")
    const rotated = writeProfileKey(path, "deepseek", "sk-two")
    expect(rotated).not.toContain("sk-one")
    expect(rotated).toContain('name = "deepseek"\napi_key = "sk-two"')
    expect(rotated).toContain('name = "openrouter"\napi_key = "sk-or"')
    expect(rotated.indexOf("deepseek")).toBeLessThan(rotated.indexOf("openrouter"))
    expect((rotated.match(/\[\[provider\.profiles\]\]/g) ?? []).length).toBe(2)
    // Quotes and backslashes in a key survive TOML.
    const odd = writeProfileKey(path, "openrouter", `a"b${"\\"}c`)
    expect(odd).toContain(`api_key = "a\\"b\\\\c"`)
    expect(() => writeProfileKey(path, "bad name", "k")).toThrow()
    expect(() => writeProfileKey(path, "deepseek", "   ")).toThrow()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("a key pasted in /model makes the kernel see the profile as ready (real binary, NULYA_HOME)", async () => {
  const home = mkdtempSync(join(tmpdir(), "nulya-home-"))
  const env = { NULYA_HOME: home }
  try {
    const before = await configShow(ws, env)
    expect(before.paths.user).toBe(join(home, "config.toml"))
    const ds = before.profiles.find((p) => p.name === "deepseek")!
    // Only assert the file route: the env var may or may not be set on this machine.
    if (ds.credential_source !== "env") expect(ds.credential).toBe(false)

    const { writeProfileKey } = require("../src/nulya/credentials.ts")
    writeProfileKey(before.paths.user, "deepseek", "sk-test-not-real")
    const after = await configShow(ws, env)
    const ready = after.profiles.find((p) => p.name === "deepseek")!
    expect(ready.credential).toBe(true)
    expect(ready.credential_source).toBe("config")
    // The key itself is not in the projection.
    expect(JSON.stringify(after)).not.toContain("sk-test-not-real")
    // And a session on it freezes the real provider, not scripted.
    const id = await sessionNew(ws, { profile: "deepseek" }, env)
    const header = JSON.parse(require("node:fs").readFileSync(join(ws.dir, ".nulya", "sessions", `${id}.jsonl`), "utf8").split("\n")[0])
    expect(header.model_identity.provider).toBe("openai")
    expect(header.model_identity.model).toBe("deepseek-v4-flash")
    expect(JSON.stringify(header)).not.toContain("sk-test-not-real")
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
}, 30_000)

test("/model: s on a keyless row asks for the key, Enter saves it and the row turns ready", async () => {
  const written: Array<[string, string, string]> = []
  let keyed = false
  const load = async (): Promise<ConfigView> => ({
    ...fake,
    profiles: fake.profiles.map((p) =>
      p.name === "openai" && keyed ? { ...p, credential: true, credential_source: "config" as const } : p,
    ),
  })
  const [notice, setNotice] = createSignal<string | null>(null)
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={null}
      onPick={() => {}}
      onNotice={setNotice}
      onClose={() => {}}
      load={load}
      writeKey={(path, profile, key) => {
        written.push([path, profile, key])
        keyed = true
      }}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("no key · s to paste one"), 10_000)
    // The cursor opens on the first ready row (deepseek); go up to openai.
    setup.mockInput.pressKey("k")
    setup.mockInput.pressKey("k")
    await settle(setup, 2)
    setup.mockInput.pressKey("s")
    await until(() => setup.captureCharFrame().includes("API key for openai"), 10_000)
    expect(setup.captureCharFrame()).toContain("Enter save to /home/me/.nulya/config.toml")
    // j must NOT move the list while the input has the keyboard.
    await setup.mockInput.typeText("sk-pasted-j")
    setup.mockInput.pressEnter()
    await until(() => written.length === 1, 10_000)
    expect(written[0]).toEqual(["/home/me/.nulya/config.toml", "openai", "sk-pasted-j"])
    await until(() => setup.captureCharFrame().includes("ready · key in config"), 10_000)
    expect(notice()).toContain("api_key for openai saved to /home/me/.nulya/config.toml")
    // Esc backs out of a second entry without writing.
    setup.mockInput.pressKey("s")
    await until(() => setup.captureCharFrame().includes("API key for openai"), 10_000)
    setup.mockInput.pressEscape()
    await until(() => !setup.captureCharFrame().includes("API key for openai"), 10_000)
    expect(written.length).toBe(1)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("credentials: an added profile is one marked block, replaced whole (not by line count) next time", () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-home-"))
  const path = join(dir, "config.toml")
  try {
    const { writeProfile, writeProfileKey } = require("../src/nulya/credentials.ts")
    require("node:fs").writeFileSync(path, `# mine\n[provider]\nactive_profile = "deepseek"\n`)
    const first = writeProfile(path, {
      name: "openrouter",
      kind: "anthropic",
      base_url: "https://openrouter.ai/api",
      models: ["moonshotai/kimi-k3", "qwen/qwen4-max"],
      key: "sk-or",
    })
    expect(first).toContain("# mine")
    expect(first).toContain('kind = "anthropic"')
    expect(first).toContain('base_url = "https://openrouter.ai/api"')
    // The first id is also the profile's default, so `--profile openrouter` runs.
    expect(first).toContain('model = "moonshotai/kimi-k3"')
    expect(first).toContain('models = ["moonshotai/kimi-k3", "qwen/qwen4-max"]')
    expect(first).toContain('api_key = "sk-or"')

    // Something after it stays put, and rewriting with a SHORTER model list
    // replaces the whole block rather than leaving orphaned lines behind.
    writeProfileKey(path, "deepseek", "sk-ds")
    const again = writeProfile(path, {
      name: "openrouter",
      kind: "openai",
      base_url: "https://openrouter.ai/api/v1",
      models: ["moonshotai/kimi-k3"],
    })
    expect(again).toContain('name = "deepseek"\napi_key = "sk-ds"')
    expect(again).not.toContain("qwen/qwen4-max")
    expect(again).not.toContain("anthropic")
    expect(again).not.toContain("sk-or")
    expect((again.match(/\[\[provider\.profiles\]\]/g) ?? []).length).toBe(2)

    expect(() => writeProfile(path, { name: "bad name", kind: "openai", base_url: "https://x", models: ["m"] })).toThrow()
    expect(() => writeProfile(path, { name: "ok", kind: "openai", base_url: "", models: ["m"] })).toThrow()
    expect(() => writeProfile(path, { name: "ok", kind: "openai", base_url: "https://x", models: [] })).toThrow()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("/model: `a` walks the compatible-provider form and writes one profile", async () => {
  const written: ProfileDraft[] = []
  const [notice, setNotice] = createSignal<string | null>(null)
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={null}
      onPick={() => {}}
      onNotice={setNotice}
      onClose={() => {}}
      load={async () => fake}
      writeProfileBlock={(_path, draft) => written.push(draft)}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("+ add an OpenAI-"), 10_000)
    setup.mockInput.pressKey("a")
    await until(() => setup.captureCharFrame().includes("profile name"), 10_000)

    // A name that already exists is refused where it is typed, not on save —
    // and the text stays put so it can be corrected rather than retyped.
    await setup.mockInput.typeText("deepseek")
    setup.mockInput.pressEnter()
    await until(() => (notice() ?? "").includes("already exists"), 10_000)
    expect(setup.captureCharFrame()).toContain("profile name")
    erase(setup, "deepseek".length)

    await setup.mockInput.typeText("openrouter")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("Chat Completions"), 10_000)
    expect(setup.captureCharFrame()).toContain("anthropic · Messages")
    setup.mockInput.pressKey("j")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("base URL"), 10_000)

    // Nothing typed into a step leaks into the next one, and a URL is checked.
    await setup.mockInput.typeText("openrouter.ai")
    setup.mockInput.pressEnter()
    await until(() => (notice() ?? "").includes("starts with http"), 10_000)
    erase(setup, "openrouter.ai".length)
    await setup.mockInput.typeText("https://openrouter.ai/api/")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("model id(s)"), 10_000)
    await setup.mockInput.typeText("moonshotai/kimi-k3 , qwen/qwen4-max")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("API key for openrouter"), 10_000)
    await setup.mockInput.typeText("sk-or-xxx")
    setup.mockInput.pressEnter()
    await until(() => written.length === 1, 10_000)

    expect(written[0]).toEqual({
      name: "openrouter",
      kind: "anthropic",
      // The trailing slash is dropped: the kernel appends the wire's own path.
      base_url: "https://openrouter.ai/api",
      models: ["moonshotai/kimi-k3", "qwen/qwen4-max"],
      key: "sk-or-xxx",
    })
    expect(notice()).toContain("openrouter added to /home/me/.nulya/config.toml")
    // And the picker is back on the provider list, not stuck in the form.
    await until(() => setup.captureCharFrame().includes("model · which provider"), 10_000)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a provider added in /model is a profile the real kernel resolves (real binary, NULYA_HOME)", async () => {
  const home = mkdtempSync(join(tmpdir(), "nulya-home-"))
  const env = { NULYA_HOME: home }
  try {
    const { writeProfile } = require("../src/nulya/credentials.ts")
    const before = await configShow(ws, env)
    expect(before.profiles.some((p) => p.name === "my-endpoint")).toBe(false)
    writeProfile(before.paths.user, {
      name: "my-endpoint",
      kind: "openai",
      base_url: "https://example.invalid/v1",
      models: ["some-model", "other-model"],
      key: "sk-added-not-real",
    })
    const after = await configShow(ws, env)
    const added = after.profiles.find((p) => p.name === "my-endpoint")!
    expect(added.kind).toBe("openai")
    expect(added.base_url).toBe("https://example.invalid/v1")
    expect(added.models).toEqual(["some-model", "other-model"])
    // It can run: the key is right there in the file the kernel reads.
    expect(added.credential).toBe(true)
    expect(added.credential_source).toBe("config")
    expect(JSON.stringify(after)).not.toContain("sk-added-not-real")
    // And a session freezes it, model id and all.
    const id = await sessionNew(ws, { profile: "my-endpoint", model: "other-model" }, env)
    const line = require("node:fs")
      .readFileSync(join(ws.dir, ".nulya", "sessions", `${id}.jsonl`), "utf8")
      .split("\n")[0]
    const header = JSON.parse(line)
    expect(header.model_identity.provider).toBe("openai")
    expect(header.model_identity.model).toBe("other-model")
    expect(JSON.stringify(header)).not.toContain("sk-added-not-real")
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
}, 30_000)
