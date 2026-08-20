/**
 * The code layer of goals/tui-plugin.md U3: loading a package's
 * `contributes.tui` module and the host API it gets.
 *
 * Four fixture packages, built once into a throwaway workspace store:
 *
 *  - `probe`   a whole plugin: a widget, a card for its own tool, a panel with
 *              keys, three commands, and both observers. Its module is
 *              `test/fixtures/probe-plugin.ts`, copied into the draft — so the
 *              file that runs here is type-checked against `plugin-api.d.ts`
 *              by `tsc`, and is loaded from a frozen version by absolute path,
 *              exactly as a real package's would be.
 *  - `future`  declares `api: 2`. One warning, skipped, nothing else affected.
 *  - `broken`  a module that does not parse. Same treatment.
 *  - `nosy`    registers a card for a tool it does not declare (D11). Its
 *              `activate` throws, its registrations are rolled back, and the
 *              other three packages are untouched.
 *
 * The split below is deliberate. Loading, versions, failures, the trusted-zone
 * queue and the per-package guards are asked of the HOST, with seams a test
 * supplies — no screen, no session, and every answer exact. The things that
 * are only true on a screen — a panel taking the keyboard, `Esc` giving it
 * back, a widget on the strip, a note reaching the ledger and folding back —
 * are asked of a rendered `App`.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { copyFileSync, mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import type { JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { PluginToolCard } from "../src/render/cards/PluginToolCard.tsx"
import { createPluginHost, plugin_api_version, type PluginHost } from "../src/plugins/host.ts"
import { tokenColor } from "../src/plugins/surface.tsx"
import { parseExtNote, wrapExtNote } from "../src/extnote.ts"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { describeTool } from "../src/render/registry.ts"
import { extBuild, extSetCurrent, sessionEvents, sessionList } from "../src/nulya/cli.ts"
import { default_settings } from "../src/state/settings.ts"
import type { LedgerEvent } from "../src/nulya/ledger.ts"
import type { ToolItem } from "../src/state/session.ts"
import { unsafe_settings, scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

let ws: TempWorkspace

const style: Style = createStyle(unsafe_settings, {})
/** The same screen with the code layer switched off (`[extensions] plugins`). */
const style_no_plugins: Style = createStyle(
  { ...unsafe_settings, extensions: { ...unsafe_settings.extensions, plugins: false } },
  {},
)

function extensionDir(id: string): string {
  return join(ws.dir, ".nulya", "extensions", id)
}

/**
 * A package whose only interesting part is its front-end module. `entry` is
 * deliberately outside `src/`: a script package's whole `src/` tree is already
 * collected into the snapshot, and putting the module there would ask whether
 * one file can be collected twice — a question no fixture needs to raise.
 */
function writePackage(
  id: string,
  module: string | null,
  over: Record<string, unknown> = {},
  tui: { entry: string; api: number } | null = { entry: "tui/main.ts", api: plugin_api_version },
): void {
  const dir = extensionDir(id)
  mkdirSync(join(dir, "tui"), { recursive: true })
  const contributes = { ...(tui ? { tui } : {}), ...((over["contributes"] as object) ?? {}) }
  writeFileSync(
    join(dir, "extension.json"),
    JSON.stringify({
      schema: "nulya.extension/v2",
      id,
      activation: "on_request",
      ...over,
      contributes,
    }),
  )
  if (module !== null) writeFileSync(join(dir, tui!.entry), module)
}

beforeAll(async () => {
  ws = tempWorkspace()

  // `probe` — the real one. A declared tool needs a runtime (`Manifest.validate`
  // refuses tools without one), and this one is never invoked: what the fixture
  // needs from `note` is that the manifest DECLARES it, which is the whole of
  // `registerCard`'s permission check.
  writePackage(
    "probe",
    null,
    {
      runtime: { entry: "src/main.ps1", interpreter: "powershell" },
      contributes: {
        tools: [
          {
            name: "note",
            description: "a tool the probe package draws its own card for",
            input: { type: "object", properties: { text: { type: "string" } } },
          },
        ],
      },
    },
    { entry: "tui/probe.ts", api: plugin_api_version },
  )
  mkdirSync(join(extensionDir("probe"), "src"), { recursive: true })
  writeFileSync(join(extensionDir("probe"), "src", "main.ps1"), "[Console]::Out.Write('{}')\n")
  copyFileSync(join(import.meta.dir, "fixtures", "probe-plugin.ts"), join(extensionDir("probe"), "tui", "probe.ts"))

  // `future` — a version this build does not implement.
  writePackage("future", "export function activate() {}\n", {}, { entry: "tui/main.ts", api: plugin_api_version + 1 })
  // `broken` — a module that does not parse.
  writePackage("broken", "export function activate( { this is not typescript !!!\n")
  // `nosy` — a card for somebody else's tool (D11).
  writePackage(
    "nosy",
    'export function activate(api) { api.registerWidget({ render: () => [[{ text: "nosy" }]] }); api.registerCard("shell", { render: () => [] }) }\n',
  )

  for (const id of ["probe", "future", "broken", "nosy"]) {
    const version = await extBuild(ws, `.nulya/extensions/${id}`)
    await extSetCurrent(ws, "activate", id, version)
  }
})

afterAll(() => {
  ws.cleanup()
})

// ── The host, without a screen ──────────────────────────────────────────────

/** Seams that answer nothing, so a test can override only what it is about. */
function hostWith(over: Partial<Parameters<typeof createPluginHost>[0]> = {}): PluginHost {
  return createPluginHost({
    ws,
    enabled: true,
    statePath: join(ws.dir, `tui-state-host-${Math.random().toString(36).slice(2)}.json`),
    session: () => null,
    tasks: () => [],
    appendNote: async () => {},
    compact: async () => ({ session: "s-child", parent: { session: "s-parent", seq: 1 } }),
    openTab: () => {},
    wearNext: () => {},
    notice: () => {},
    zoneBusy: () => false,
    ...over,
  })
}

describe("loading", () => {
  test("a package's module is loaded from its frozen version, and a bad one costs only a warning", async () => {
    const host = hostWith()
    await host.load()

    // The one that works, loaded — from the store, at the version `current`
    // names, by absolute path (the `bun build --compile` fact this whole
    // milestone turns on, verified in tui-plugin §6).
    const probe = host.loaded().find((one) => one.id === "probe")
    expect(probe).toBeDefined()
    expect(probe!.version).toStartWith("v-")
    expect(probe!.entry).toContain("versions")
    expect(probe!.entry).toEndWith("probe.ts")

    const warnings = host.warnings().join("\n")
    // An API version this build does not implement: named, skipped, and the
    // sentence says both numbers so the reader knows which side is old.
    expect(warnings).toContain("future")
    expect(warnings).toContain(`plugin API ${plugin_api_version + 1}`)
    // A module that does not parse: named, skipped.
    expect(warnings).toContain("broken")
    // A card for a tool the package does not declare: `activate` threw (D11).
    expect(warnings).toContain("nosy")
    expect(warnings).toContain("cannot draw a card for 'shell'")

    // …and none of that stopped the good one. This is the whole of D10: one
    // bad plugin never takes the front end down.
    expect(host.commands().some((row) => row.name === "probe-panel")).toBe(true)
    expect(host.widgets().some((row) => row.pkg === "probe")).toBe(true)
    // `nosy` registered a widget BEFORE it threw, and the rollback took it
    // back: a half-activated plugin is not a plugin.
    expect(host.widgets().some((row) => row.pkg === "nosy")).toBe(false)
  }, 60_000)

  test("a package may only draw its own tool's card", async () => {
    const host = hostWith()
    await host.load()
    expect(host.cardFor("note")?.pkg).toBe("probe")
    // The builtin, and any other package's tool: nobody registered it, and
    // `nosy` proved above that trying throws rather than quietly winning.
    expect(host.cardFor("shell")).toBeNull()
  }, 60_000)

  test("a built-in command cannot be taken, even by a loaded plugin", async () => {
    const host = hostWith()
    await host.load()
    expect(host.commands().some((row) => row.name === "model")).toBe(false)
    expect(host.warnings().join("\n")).toContain("'/model' is a built-in command")
  }, 60_000)

  test("the switch off means nothing is loaded at all", async () => {
    const host = hostWith({ enabled: false })
    await host.load()
    expect(host.loaded()).toHaveLength(0)
    expect(host.commands()).toHaveLength(0)
    expect(host.widgets()).toHaveLength(0)
    expect(host.warnings()).toHaveLength(0)
  }, 30_000)

  test("loading twice adds nothing: a module that has run has run", async () => {
    const host = hostWith()
    await host.load()
    const first = host.loaded().length
    const warned = host.warnings().length
    await host.load()
    expect(host.loaded()).toHaveLength(first)
    expect(host.warnings()).toHaveLength(warned)
    expect(host.commands().filter((row) => row.name === "probe-panel")).toHaveLength(1)
  }, 60_000)
})

describe("trusted zones", () => {
  /**
   * A panel a plugin asked for while the approval dialog, the mode picker or
   * `/provider`'s key field is up does not open — it QUEUES, and lands when
   * the zone clears (D4). Nothing here is detectable from the plugin's side,
   * which is the point: there is no failure to retry around.
   */
  test("a panel opened while a zone is up waits, and takes no keys until it clears", async () => {
    let busy = true
    const host = hostWith({ zoneBusy: () => busy })
    await host.load()
    const open = host.commands().find((row) => row.name === "probe-panel")!
    await open.run({ args: "", session: null })

    expect(host.panel()).toBeNull()
    expect(host.handleKey({ name: "j", ctrl: false, shift: false, meta: false })).toBe(false)
    // …and the zone's own keys are untouched: the host never even asked.
    expect(host.handleKey({ name: "escape", ctrl: false, shift: false, meta: false })).toBe(false)

    busy = false
    expect(host.panel()?.pkg).toBe("probe")
    expect(host.handleKey({ name: "j", ctrl: false, shift: false, meta: false })).toBe(true)
  }, 60_000)

  test("Ctrl+C never reaches a plugin, panel or no panel", async () => {
    const host = hostWith()
    await host.load()
    await host.commands().find((row) => row.name === "probe-panel")!.run({ args: "", session: null })
    expect(host.panel()).not.toBeNull()
    expect(host.handleKey({ name: "c", ctrl: true, shift: false, meta: false })).toBe(false)
  }, 60_000)

  test("Esc closes a panel the plugin declined to handle", async () => {
    const host = hostWith()
    await host.load()
    await host.commands().find((row) => row.name === "probe-panel")!.run({ args: "", session: null })
    expect(host.panel()).not.toBeNull()
    expect(host.handleKey({ name: "escape", ctrl: false, shift: false, meta: false })).toBe(true)
    expect(host.panel()).toBeNull()
  }, 60_000)
})

describe("observe", () => {
  test("every stream line and ledger event reaches a plugin that asked", async () => {
    const host = hostWith()
    await host.load()
    const widget = host.widgets().find((row) => row.pkg === "probe")!
    expect(widget.renderer.render(80)[0]!.map((span) => span.text).join("")).toContain("streams 0 · events 0")

    host.observe({ kind: "stream", line: { stream: "model", event: "text_delta", text: "hi" } }, "s-1")
    host.observe({ kind: "stream", line: { stream: "model", event: "started" } }, "s-1")
    host.observe({ kind: "event", event: { seq: 3, kind: "user_text", text: "hello" } as unknown as LedgerEvent }, "s-1")
    expect(widget.renderer.render(80)[0]!.map((span) => span.text).join("")).toContain("streams 2 · events 1")
  }, 60_000)
})

// ── Pure: the line contract ─────────────────────────────────────────────────

describe("the line contract", () => {
  /**
   * `NO_COLOR` is free precisely because a plugin never names a colour (D9):
   * every token collapses to the terminal's own foreground, and the plugin's
   * text is unchanged.
   */
  test("NO_COLOR collapses every token a plugin can name", () => {
    const mono = createStyle(default_settings, { NO_COLOR: "1" })
    const tokens = ["fg", "muted", "dim", "faint", "accent.user", "accent.evolve", "ok", "err", "warn"] as const
    for (const token of tokens) expect(tokenColor(mono, token)).toBe(mono.theme.fg)
    // …and in colour they are genuinely different, so the collapse above is a
    // fact about NO_COLOR rather than about the mapping being a stub.
    expect(tokenColor(style, "err")).not.toBe(tokenColor(style, "ok"))
    // A token from a later contract than this build: ordinary foreground, the
    // same reading an unknown `render` hint gets (D12).
    expect(tokenColor(style, "chartreuse" as never)).toBe(style.theme.fg)
  })

  test("the note sentinel round-trips, and a body quoting it survives", () => {
    const wrapped = wrapExtNote("probe", "finding", "look at </ext-note> in line 3")
    const parsed = parseExtNote(wrapped)!
    expect(parsed.pkg).toBe("probe")
    expect(parsed.kind).toBe("finding")
    expect(parsed.text).toBe("look at </ext-note> in line 3")
    // Parsing never depends on the contract's wording (`approvalnote.ts`'s own
    // rule): a turn written by an older TUI must fold in a newer one.
    expect(parseExtNote(wrapExtNote("probe", "finding", "plain", false))?.text).toBe("plain")
    expect(parseExtNote("just a user turn")).toBeNull()
  })
})

// ── On a screen ─────────────────────────────────────────────────────────────

const tool_item: ToolItem = {
  key: "e7:call-1",
  seq: 7,
  kind: "tool",
  callId: "call-1",
  tool: "note",
  args: '{"text":"the probe wrote this"}',
  state: "done",
  ok: true,
  output: "recorded",
  spillPath: null,
  resolved: true,
  awaiting: false,
  taskResult: null,
}

/** The transcript's own defaults, but with tool bodies open: the body is the subject here. */
const expanded_style: Style = createStyle(
  { ...unsafe_settings, transcript: { ...unsafe_settings.transcript, tool_output: "expanded" } },
  {},
)

/** One card, drawn on its own — the same harness `test/render.test.tsx` uses. */
async function cardFrame(node: () => JSX.Element): Promise<string> {
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={expanded_style}>
        <FoldContext.Provider value={createFoldStore()}>{node()}</FoldContext.Provider>
      </StyleContext.Provider>
    ),
    { width: 80, height: 10 },
  )
  try {
    return await settle(setup, 4)
  } finally {
    setup.renderer.destroy()
  }
}

test("a plugin card draws its own body inside the host's frame", async () => {
  const frame = await cardFrame(() => (
    <PluginToolCard
      item={tool_item}
      presentation={describeTool(
        { tool: "note", args: tool_item.args, output: "recorded" },
        expanded_style.glyphs,
      )}
      card={{
        pkg: "probe",
        tool: "note",
        renderer: {
          render: (view) => [
            [{ text: "probe card", token: "accent.tool" }, { text: ` · ${view.state}`, token: "dim" }],
            [{ text: view.args, token: "fg" }],
          ],
        },
      }}
      revision={0}
    />
  ))
  // The host's frame — the extension glyph and the ordinary head line, so a
  // plugin card cannot make a call look like something other than a call.
  expect(frame).toContain("⌘ note")
  // …and the plugin's own body inside it.
  expect(frame).toContain("probe card · done")
  expect(frame).toContain("the probe wrote this")
}, 60_000)

/**
 * A renderer that throws must cost its own rows and nothing else: a plugin is
 * somebody else's code inside a render pass, and an exception escaping it
 * would take the screen down (D10).
 */
test("a renderer that throws costs its own rows and nothing else", async () => {
  const frame = await cardFrame(() => (
    <PluginToolCard
      item={tool_item}
      presentation={describeTool(
        { tool: "note", args: tool_item.args, output: "recorded" },
        expanded_style.glyphs,
      )}
      card={{
        pkg: "probe",
        tool: "note",
        renderer: {
          render: () => {
            throw new Error("no idea how to draw this")
          },
        },
      }}
      revision={0}
    />
  ))
  // The card is still a card — the head line the host drew is untouched — and
  // the failure is reported where the body would have been, naming the package
  // so the next question has an address.
  expect(frame).toContain("⌘ note")
  expect(frame).toContain("probe could not draw this")
  expect(frame).toContain("no idea how to draw this")
}, 60_000)

test("the widget is on the strip, the panel takes the keyboard, and Esc gives it back", async () => {
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        pick={{ profile: "scripted" }}
        style={style}
        driver={{ env: scripted_env }}
        statePath={join(ws.dir, "tui-state-plugins-screen.json")}
      />
    ),
    { width: 100, height: 30 },
  )
  try {
    // The widget: a persistent row above the composer, with the host's
    // attribution glyph in front of the plugin's own head line.
    await untilFrame(setup, "probe · streams", true, 60_000)
    expect(setup.captureCharFrame()).toContain("◈ probe")

    // The panel: opened by the plugin's own command, and it says whose it is.
    await setup.mockInput.typeText("/probe-panel")
    setup.mockInput.pressEnter()
    await untilFrame(setup, "probe panel")
    let frame = setup.captureCharFrame()
    expect(frame).toContain("this panel is an extension's")
    expect(frame).toContain("cursor 0 · j moves")
    expect(frame).toContain("Esc close")

    // It owns the keyboard: `j` reaches the plugin rather than the composer.
    setup.mockInput.pressKey("j")
    await untilFrame(setup, "cursor 1")
    expect(setup.captureCharFrame()).not.toContain("› j")

    // …and `Esc` takes it down, whatever the plugin does with keys.
    setup.mockInput.pressEscape()
    await untilFrame(setup, "probe panel", false)
    frame = setup.captureCharFrame()
    // The widget stays: it is not a dialog, it is a row.
    expect(frame).toContain("probe · streams")
  } finally {
    setup.renderer.destroy()
  }
}, 180_000)

test("appendNote lands in the ledger as a user turn and folds back to the plugin's own words", async () => {
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        pick={{ profile: "scripted" }}
        style={style}
        driver={{ env: scripted_env }}
        statePath={join(ws.dir, "tui-state-plugins-note.json")}
      />
    ),
    { width: 100, height: 30 },
  )
  try {
    await untilFrame(setup, "probe · streams", true, 60_000)

    // A session first: a note is a user turn, and a draft has nothing to
    // append to (the host says so rather than inventing a session).
    await setup.mockInput.typeText("hello")
    setup.mockInput.pressEnter()
    await untilFrame(setup, "● done", true, 60_000)
    const id = await onlySessionSince()

    await setup.mockInput.typeText("/probe-note the plan is missing a step")
    setup.mockInput.pressEnter()
    const isNote = (event: LedgerEvent): event is Extract<LedgerEvent, { kind: "user_text" }> =>
      event.kind === "user_text" && (event as Extract<LedgerEvent, { kind: "user_text" }>).text.includes("<ext-note ")
    await until(async () => (await sessionEvents(ws, id)).some(isNote), 60_000)
    const note = (await sessionEvents(ws, id)).find(isNote)!
    // The ledger keeps the sentinel and its contract — that is what the model
    // reads, and what says the package assembled this on a person's behalf.
    expect(note.text).toContain('pkg="probe"')
    expect(note.text).toContain('kind="finding"')
    expect(parseExtNote(note.text)?.text).toBe("the plan is missing a step")

    // The transcript folds it back to what was said, badged with who said it.
    await settle(setup, 4)
    const frame = setup.captureCharFrame()
    expect(frame).toContain("the plan is missing a step")
    expect(frame).toContain("probe · finding")
    expect(frame).not.toContain("<ext-note")
  } finally {
    setup.renderer.destroy()
  }
}, 180_000)

test("with the switch off the screen is exactly what U2 left: no widget, no plugin command", async () => {
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        pick={{ profile: "scripted" }}
        style={style_no_plugins}
        driver={{ env: scripted_env }}
        statePath={join(ws.dir, "tui-state-plugins-off.json")}
      />
    ),
    { width: 100, height: 30 },
  )
  try {
    await settle(setup, 8)
    expect(setup.captureCharFrame()).not.toContain("probe · streams")
    // The command is not a command: it falls through the whole chain and would
    // be sent to the model verbatim, which is what an unknown `/name` has
    // always done (`commands.ts`).
    await setup.mockInput.typeText("/probe-panel")
    const frame = await settle(setup, 4)
    expect(frame).not.toContain("open the probe panel")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

/**
 * Wait for the screen to say something, RENDERING as it waits.
 *
 * A plugin surface repaints when the host's revision changes, and a revision
 * is a signal — nothing repaints until a render pass runs. So a bare poll on
 * `captureCharFrame` can spin on a stale frame forever; this asks for the
 * frame it is about to read.
 */
async function untilFrame(
  setup: { renderOnce(): Promise<unknown>; captureCharFrame(): string },
  want: string,
  present = true,
  timeoutMs = 30_000,
): Promise<void> {
  await until(async () => {
    await setup.renderOnce()
    return setup.captureCharFrame().includes(want) === present
  }, timeoutMs)
}

/** The id of the one session this file's workspace has grown, once there is one. */
async function onlySessionSince(): Promise<string> {
  let id: string | null = null
  await until(async () => {
    const listed = await sessionList(ws)
    id = listed[0]?.id ?? null
    return id !== null
  }, 30_000)
  return id!
}
