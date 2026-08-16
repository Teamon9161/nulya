/**
 * The three T4 views (`/help`, `/settings`, `/usage`) and the one thing that
 * makes a keymap worth having: a `[keys]` line in `tui.toml` really does move
 * the binding, in the app and in the help page that documents it.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import type { JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { HelpView } from "../src/ui/overlays/HelpView.tsx"
import { SettingsView, settingRows } from "../src/ui/overlays/SettingsView.tsx"
import { UsageView } from "../src/ui/overlays/UsageView.tsx"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { createSessionState } from "../src/state/session.ts"
import { default_settings, loadSettings } from "../src/state/settings.ts"
import { createKeymap } from "../src/keymap.ts"
import { sessionList, sessionNew } from "../src/nulya/cli.ts"
import { scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

const style: Style = createStyle(default_settings, {})

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

async function overlay(node: () => JSX.Element, theme = style, width = 100, height = 40) {
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={theme}>
        <FoldContext.Provider value={createFoldStore()}>{node()}</FoldContext.Provider>
      </StyleContext.Provider>
    ),
    { width, height },
  )
  return setup
}

test("/help lists the bindings that are actually in force", async () => {
  const setup = await overlay(() => <HelpView keys={createKeymap(default_settings)} onClose={() => {}} />, style, 100, 60)
  try {
    // Eight passes, not four: a busy machine captured a half-painted frame once
    // (T1's `settle()` note) and a snapshot that flaky is worse than none.
    const frame = await settle(setup, 8)
    expect(frame).toContain("help · keys and commands")
    expect(frame).toContain("escape")
    expect(frame).toContain("ctrl+o")
    expect(frame).toContain("f3")
    // Nothing was overridden, so nothing claims to be.
    expect(frame).not.toContain("(tui.toml)")
    expect(frame).toMatchSnapshot()

    // Every command has a line here — that is what makes this page the one
    // place a command cannot exist without being discoverable (`commands.ts`).
    expect(frame).toContain("/step")
    expect(frame).toContain("/outcome <verdict> [note]")
    expect(frame).toContain("/quit")

    const rebound = createStyle({ ...default_settings, keys: { fold: "ctrl+b" } }, {})
    const second = await overlay(() => <HelpView keys={createKeymap(rebound.settings)} onClose={() => {}} />)
    try {
      const changed = await settle(second, 4)
      expect(changed).toContain("ctrl+b")
      expect(changed).toContain("(tui.toml)")
    } finally {
      second.renderer.destroy()
    }
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a [keys] override in tui.toml really moves the fold key", async () => {
  mkdirSync(join(ws.dir, ".nulya"), { recursive: true })
  writeFileSync(join(ws.dir, ".nulya", "tui.toml"), '[keys]\nfold = "ctrl+b"\n')
  const settings = await loadSettings(ws.dir, {})
  expect(settings.keys["fold"]).toBe("ctrl+b")

  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={createStyle(settings, {})} driver={{ env: scripted_env }} />,
    { width: 80, height: 24 },
  )
  try {
    await settle(setup, 4)
    await setup.mockInput.typeText("probe")
    setup.mockInput.pressEnter()
    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved))
    const occurrences = (frame: string) => frame.split("hello-from-nulya").length - 1
    expect(occurrences(await settle(setup, 5))).toBe(1)

    // The default binding is gone…
    setup.mockInput.pressKey("o", { ctrl: true })
    expect(occurrences(await settle(setup, 4))).toBe(1)
    // …and the one from the file works.
    setup.mockInput.pressKey("b", { ctrl: true })
    expect(occurrences(await settle(setup, 5))).toBe(2)
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("/settings shows the effective values and which file they came from", async () => {
  // Written by the test above; this view's whole job is to name it.
  const settings = await loadSettings(ws.dir, {})
  const rows = settingRows(settings)
  expect(rows.find((row) => row.key === "transcript.edit_diff")?.value).toBe("expanded")
  expect(rows.find((row) => row.key === "keys.fold")?.value).toBe("ctrl+b")

  const setup = await overlay(() => <SettingsView ws={ws} onClose={() => {}} />, createStyle(settings, {}))
  try {
    const frame = await settle(setup, 4)
    expect(frame).toContain("settings · tui.toml")
    expect(frame).toContain("applied")
    expect(frame).toContain(join(".nulya", "tui.toml"))
    expect(frame).toContain("transcript.history_window")
    expect(frame).toContain("keys.fold")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("/usage separates this session's tokens from the durable tool journal", async () => {
  const state = createSessionState("s-usage")
  // A whole step, both mouths: the stream as it happened, then the ledger line
  // that priced it. What the view shows is the ledger's number, once.
  state.applyStream({
    stream: "model",
    event: "usage",
    input_tokens: 1150,
    output_tokens: 80,
    cache_read_tokens: 1080,
    cache_write_tokens: 0,
  })
  state.applyEvent({
    seq: 1,
    kind: "assistant",
    text: "done",
    calls: [],
    usage: { input_tokens: 1200, output_tokens: 80, cache_read_tokens: 1080, cache_write_tokens: 0 },
  })
  state.applyStream({ stream: "step", event: "end", status: "completed" })

  const setup = await overlay(() => <UsageView ws={ws} snapshot={state.snapshot} onClose={() => {}} />)
  try {
    const frame = await settle(setup, 4)
    expect(frame).toContain("this session's tokens")
    expect(frame).toContain("steps priced")
    expect(frame).toContain("1 · 1 watched here")
    expect(frame).toContain("1200")
    expect(frame).toContain("90% of input")
    // The journal the kernel keeps across sessions; the step above ran `shell`.
    expect(frame).toContain("tool usage · .nulya/tool-usage.jsonl")
    expect(frame).toContain("builtin.shell")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("/outcome records how this session went, without touching the session file", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} />,
    { width: 90, height: 24 },
  )
  try {
    await settle(setup, 4)
    // A word that is not a verdict explains itself and records nothing.
    await setup.mockInput.typeText("/outcome sort-of")
    setup.mockInput.pressEnter()
    expect(await settle(setup, 4)).toContain("/outcome <success|partial|failure>")
    expect((await sessionList(ws)).find((row) => row.id === id)!.outcome).toBeNull()

    await setup.mockInput.typeText("/outcome partial the shell call worked")
    setup.mockInput.pressEnter()
    await until(async () => (await sessionList(ws)).find((row) => row.id === id)?.outcome !== null, 20_000)
    const judged = (await sessionList(ws)).find((row) => row.id === id)!
    expect(judged.outcome?.verdict).toBe("partial")
    expect(judged.outcome?.note).toBe("the shell call worked")
    // A judgment is not a turn: the ledger did not grow (DESIGN §3.3).
    expect(judged.events).toBe(0)
    expect(await settle(setup, 3)).toContain("partial")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

test("F1 opens help and Esc closes it", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} />,
    { width: 90, height: 40 },
  )
  try {
    await settle(setup, 4)
    expect(setup.captureCharFrame()).not.toContain("help · keys and commands")

    setup.mockInput.pressKey("F1")
    expect(await settle(setup, 4)).toContain("help · keys and commands")

    setup.mockInput.pressEscape()
    expect(await settle(setup, 4)).not.toContain("help · keys and commands")

    // The slash command is the same door.
    await setup.mockInput.typeText("/usage")
    setup.mockInput.pressEnter()
    expect(await settle(setup, 4)).toContain("this session's tokens")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)
