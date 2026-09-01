/**
 * The three full-screen views (`/help`, `/settings`, `/usage`) and the one thing that
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
import { displayWidth } from "../src/ui/columns.ts"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { createSessionState } from "../src/state/session.ts"
import { default_settings, loadSettings, type Settings } from "../src/state/settings.ts"
import { createKeymap } from "../src/keymap.ts"
import { sessionList, sessionNew } from "../src/nulya/cli.ts"
import {
  unsafe_settings,
  frameLines,
  scripted_env,
  settle,
  statusLine,
  tempWorkspace,
  until,
  type TempWorkspace,
} from "./support.ts"

const style: Style = createStyle(unsafe_settings, {})

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
  // Tall enough for the whole page: this test's point is that EVERY command is
  // on it, and the page is a scrollbox, so a viewport that cuts the last two
  // rows would turn "not discoverable" into "not scrolled to".
  const setup = await overlay(() => <HelpView keys={createKeymap(default_settings)} onClose={() => {}} />, style, 100, 98)
  try {
    // Eight passes, not four: a busy machine can capture a half-painted frame,
    // and a snapshot that flaky is worse than none.
    const frame = await settle(setup, 8)
    expect(frame).toContain("help · keys and commands")
    expect(frame).toContain("escape")
    expect(frame).toContain("f3")
    // Folding has no binding any more — a click on a head line, or
    // browse mode — so the page must not print one.
    expect(frame).not.toContain("ctrl+o")
    // Nothing was overridden, so nothing claims to be.
    expect(frame).not.toContain("(tui.toml)")
    expect(frame).toMatchSnapshot()

    // Every command has a line here — that is what makes this page the one
    // place a command cannot exist without being discoverable (`commands.ts`).
    expect(frame).toContain("/step")
    expect(frame).toContain("/outcome <verdict> [note]")
    expect(frame).toContain("/quit")

    const rebound = createStyle({ ...default_settings, keys: { tasks: "ctrl+b" } }, {})
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

test("/help at eighty columns: every description broken by us, the key column cut, nothing wrapped", async () => {
  // A binding wider than the key column can ever be — a `[keys]` line in
  // tui.toml is somebody else's string, and this page has to print it beside a
  // description rather than let it push one around.
  const keys = { ...createKeymap(default_settings), quit: "ctrl+alt+shift+super+backspace+f12" }
  const setup = await overlay(() => <HelpView keys={keys} onClose={() => {}} />, style, 76, 60)
  try {
    const frame = await settle(setup, 8)
    const lines = frameLines(frame)
    for (const line of lines) expect(displayWidth(line)).toBeLessThanOrEqual(76)

    // The over-long binding is cut with `…` rather than allowed to reflow the
    // row, and its description is still on the same line as what is left of it.
    expect(frame).toContain("…")
    expect(frame).not.toContain("ctrl+alt+shift+super+backspace+f12")

    // The gutter is a column, not a coincidence: two rows put their description
    // at exactly the same offset, with at least two blanks in front of it.
    const quit = lines.find((line) => line.includes("kill the running step"))!
    const redraw = lines.find((line) => line.includes("redraw the screen"))!
    expect(quit.indexOf("kill the running step")).toBe(redraw.indexOf("redraw the screen"))
    expect(redraw).toMatch(/ctrl\+l {2,}redraw the screen/)

    // A description too long for its column costs a second ROW, indented under
    // the text column — never a wrap, and never a line over the width. The
    // scrollbar gets a column of its own: it used to paint over the last
    // character of every row (`…stops at its nex█`).
    const first = lines.findIndex((line) => line.includes("cancel the step"))
    expect(first).toBeGreaterThan(0)
    const rest = lines[first + 1]!
    expect(rest).toContain("next step boundary) · browse when idle")
    expect(rest.indexOf("next step")).toBe(redraw.indexOf("redraw the screen"))
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("/settings at eighty columns: a path too long for its column is cut, the closing sentence is broken", async () => {
  // A workspace whose path alone is wider than the screen: `settingsPaths`
  // derives from it, so this is the row with no natural limit.
  const deep = { ...ws, dir: join(ws.dir, "a-very-long-directory-name".repeat(4)) }
  const settings = await loadSettings(ws.dir, {})
  const setup = await overlay(() => <SettingsView ws={deep} onClose={() => {}} />, createStyle(settings, {}), 76, 40)
  try {
    const frame = await settle(setup, 6)
    const lines = frameLines(frame)
    for (const line of lines) expect(displayWidth(line)).toBeLessThanOrEqual(76)
    expect(frame).toContain("…")

    // The two tables keep their gutters: the state column, then the path. The
    // project row is found by its cut, not by the long name: on Windows the
    // temp prefix alone (`C:\Users\…\AppData\Local\Temp\nulya-tui-…`) can use
    // up the column before the repeated segment ever appears.
    const path = lines.find((line) => /absent {2,}\S/.test(line) && line.includes("…"))!
    expect(path).toMatch(/absent {2,}\S/)
    const key = lines.find((line) => line.includes("transcript.history_window"))!
    expect(key).toMatch(/transcript\.history_window {2,}\S/)

    // The footer is one line until `?` asks for the rest.
    expect(frame).toContain("Esc close · j/k move · Enter change · ? keys")
    expect(frame).not.toContain("the kernel's own config is a different chain")

    setup.mockInput.pressKey("?")
    const opened = await settle(setup, 4)
    for (const line of frameLines(opened)) expect(displayWidth(line)).toBeLessThanOrEqual(76)
    // The closing sentence is broken at its joints by us, one `<text>` a line.
    expect(opened).toContain("the kernel's own config is a different chain")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("/usage at eighty columns: the label column holds, the caveat is broken, a long tool id is cut", async () => {
  // A workspace of its own: the tool journal is what the table reads, and this
  // one needs a tool id longer than any column can be.
  const narrow = tempWorkspace()
  try {
    mkdirSync(join(narrow.dir, ".nulya"), { recursive: true })
    writeFileSync(
      join(narrow.dir, ".nulya", "tool-usage.jsonl"),
      [
        `{"v":1,"at":"2026-08-18T10:00:00Z","tool_id":"ext:a-package-with-a-very-long-name/a-tool-with-a-very-long-name","ok":true}`,
        `{"v":1,"at":"2026-08-18T10:00:01Z","tool_id":"builtin.shell","ok":true}`,
        "",
      ].join("\n"),
    )
    const state = createSessionState("s-narrow")
    state.applyEvent({
      seq: 1,
      kind: "assistant",
      text: "done",
      calls: [],
      usage: { input_tokens: 1200, output_tokens: 80, cache_read_tokens: 1080, cache_write_tokens: 0 },
    })

    const setup = await overlay(() => <UsageView ws={narrow} snapshot={state.snapshot} onClose={() => {}} />, style, 76, 30)
    try {
      const frame = await settle(setup, 6)
      const lines = frameLines(frame)
      for (const line of lines) expect(displayWidth(line)).toBeLessThanOrEqual(76)

      // The token block is a table, and its numbers are RIGHT-aligned: what
      // lines up is the last digit, because that is the digit that says whether
      // this is a hundred or a million.
      const input = lines.find((line) => line.includes("input tokens"))!
      const output = lines.find((line) => line.includes("output tokens"))!
      expect(input.indexOf("1200") + "1200".length).toBe(output.indexOf("80") + "80".length)
      expect(input).toMatch(/input tokens {2,}1200/)

      // The caveat is two lines broken at a joint, not one wrapped line.
      expect(frame).toContain("summed from the ledger, one step at a time")
      expect(frame).toContain("a step whose provider reported no usage is absent, not zero")

      // And the journal's long id is cut rather than allowed to reflow its row.
      expect(frame).toContain("…")
      expect(frame).not.toContain("a-tool-with-a-very-long-name")
      const shell = lines.find((line) => line.includes("builtin.shell"))!
      expect(shell).toMatch(/builtin\.shell {2,}1 uses {2,}100% ok/)
    } finally {
      setup.renderer.destroy()
    }
  } finally {
    narrow.cleanup()
  }
}, 60_000)

test("a [keys] override in tui.toml really moves a binding", async () => {
  mkdirSync(join(ws.dir, ".nulya"), { recursive: true })
  writeFileSync(join(ws.dir, ".nulya", "tui.toml"), '[keys]\nhelp = "ctrl+b"\n')
  const settings = await loadSettings(ws.dir, {})
  expect(settings.keys["help"]).toBe("ctrl+b")
  // Nobody is at this keyboard to answer the gate, so the tool call runs
  //; the binding is what this test is about.
  const bindings: Settings = { ...settings, driver: unsafe_settings.driver, extensions: unsafe_settings.extensions }

  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={createStyle(bindings, {})} driver={{ env: scripted_env }} />,
    { width: 80, height: 24 },
  )
  try {
    await settle(setup, 4)
    // A real step first: this session's shell call is what the `/usage` test
    // below reads out of `.nulya/tool-usage.jsonl`, and it is the only thing in
    // this file that puts a line there.
    await setup.mockInput.typeText("probe")
    setup.mockInput.pressEnter()
    await until(() => state.snapshot.items.some((item) => item.kind === "tool" && item.resolved))
    await settle(setup, 4)

    // The default binding is gone…
    setup.mockInput.pressKey("f1")
    expect(await settle(setup, 4)).not.toContain("help · keys and commands")
    // …and the one from the file works.
    setup.mockInput.pressKey("b", { ctrl: true })
    expect(await settle(setup, 5)).toContain("help · keys and commands")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("/settings shows the effective values and which file they came from", async () => {
  // Written by the test above; this view's whole job is to name it.
  const settings = await loadSettings(ws.dir, {})
  const rows = settingRows(settings)
  expect(rows.find((row) => row.key === "transcript.diff")?.value).toBe("expanded")
  expect(rows.find((row) => row.key === "keys.help")?.value).toBe("ctrl+b")

  const setup = await overlay(() => <SettingsView ws={ws} onClose={() => {}} />, createStyle(settings, {}))
  try {
    const frame = await settle(setup, 4)
    expect(frame).toContain("settings · tui.toml")
    expect(frame).toContain("applied")
    expect(frame).toContain(join(".nulya", "tui.toml"))
    expect(frame).toContain("transcript.history_window")
    expect(frame).toContain("keys.help")
  } finally {
    setup.renderer.destroy()
  }
})

test("/settings leads to the choices this front end makes, and a click opens one", async () => {
  const settings = await loadSettings(ws.dir, {})
  const opened: string[] = []
  const setup = await overlay(
    () => (
      <SettingsView
        ws={ws}
        onClose={() => {}}
        choices={[
          { label: "model", value: "deepseek-v4", command: "/model", open: () => opened.push("model") },
          { label: "permission mode", value: "ask", command: "/mode", open: () => opened.push("mode") },
        ]}
      />
    ),
    createStyle(settings, {}),
  )
  try {
    const frame = await settle(setup, 4)
    // The file-owned table is still the body of this screen; the choices are
    // what a person who came here by clicking `settings` can actually change.
    expect(frame).toContain("transcript.history_window")
    expect(frame).toContain("permission mode")
    // The command is on the row because that is how a keyboard reaches it: a
    // row that could only be clicked would be a control half this front end
    // cannot use.
    expect(frame).toContain("/model")

    const rows = frame.split("\n")
    const at = rows.findIndex((row) => row.includes("permission mode"))
    expect(at).toBeGreaterThanOrEqual(0)
    await setup.mockMouse.click(rows[at]!.indexOf("permission mode"), at)
    await settle(setup, 3)
    expect(opened).toEqual(["mode"])
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
    // 1080 cached of a 1200 + 1080 prompt: the share of the WHOLE prompt, not
    // of the uncached part (which would read 90% here and 900% on a good step).
    expect(frame).toContain("47% of prompt")
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
    // A judgment is not a turn: the ledger did not grow.
    expect(judged.events).toBe(0)
    expect(await settle(setup, 3)).toContain("partial")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

/**
 * Wearing a package is visible without opening anything.
 *
 * A `--with` member is usually nothing but a system prompt — a mode, an
 * identity — and it decides what the model thinks it is. It was on the draft
 * card and on the composition card, and nowhere at all once the card was
 * folded, which is how a session carrying `evolution` looked exactly like one
 * that was not. `/with` is the general form of `/evolve`, and needs no build.
 */
test("a tab wearing a package says so on the draft card and on the status line", async () => {
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        pick={{ profile: "scripted", model: "scripted-demo" }}
        style={style}
        driver={{ env: scripted_env }}
        statePath={join(ws.dir, "tui-state-wearing.json")}
      />
    ),
    { width: 100, height: 30 },
  )
  try {
    await settle(setup, 4)
    expect(setup.captureCharFrame()).not.toContain("evolution")

    await setup.mockInput.typeText("/with evolution")
    setup.mockInput.pressEnter()
    const frame = await settle(setup, 4)
    // The draft card's `with` row, and the chip under the composer that will
    // still be there once the card is gone — visible once the notice that
    // answered `/with` has come off that line on its own.
    expect(frame).toContain("with        evolution")
    await until(() => statusLine(setup).includes("◈ evolution"), 15_000)
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


test("global overlay shortcuts keep working while an overlay is open", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} />,
    { width: 90, height: 40 },
  )
  try {
    await settle(setup, 4)

    setup.mockInput.pressKey("F2")
    await until(() => setup.captureCharFrame().includes("extensions ·"), 15_000)

    setup.mockInput.pressKey("F3")
    await until(() => setup.captureCharFrame().includes("sessions ·"), 15_000)
    expect(setup.captureCharFrame()).not.toContain("extensions ·")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)
