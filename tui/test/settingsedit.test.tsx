/**
 * `/settings` writes (tui.md §11, T100): the minimal TOML edit underneath it,
 * and the panel that drives it.
 *
 * The pure half is where the guarantees are — the file stays the person's
 * document — so those are asserted on text rather than on a frame. The panel
 * half asserts what a key press DID: the file on disk, and the refusals that
 * leave it alone.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { SettingsView, draftOf } from "../src/ui/overlays/SettingsView.tsx"
import { StyleContext, liveStyle } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { loadSettings, settingsPaths } from "../src/state/settings.ts"
import { layerSets, patchAgainstFreshest, placeSetting, readLayer, writeSetting } from "../src/state/settingsfile.ts"
import { frameLines, settle, tempWorkspace, type TempWorkspace } from "./support.ts"

// ---------------------------------------------------------------- the writer

test("a key that is already there is replaced on its own line, and nothing else moves", () => {
  const before = [
    "# my settings, written by hand",
    "",
    "[transcript]",
    "# the one I care about",
    'diff = "expanded"   # keep this open',
    "max_width = 100",
    "",
    "[ui]",
    'theme = "nulya-dark"',
    "",
  ].join("\n")
  const after = placeSetting(before, "transcript", "diff", '"collapsed"')

  expect(after).toContain('diff = "collapsed"   # keep this open')
  // Everything that was not that value is byte for byte what it was.
  expect(after.replace('diff = "collapsed"', 'diff = "expanded"')).toBe(before)
})

test("a key the file does not have joins its table, not the end of the file", () => {
  const before = ["[transcript]", "max_width = 100", "", "[ui]", 'theme = "nulya-light"', ""].join("\n")
  const after = placeSetting(before, "transcript", "ascii", "true")
  const lines = after.split("\n")

  expect(lines.indexOf("ascii = true")).toBe(lines.indexOf("max_width = 100") + 1)
  // Which is to say: inside its own table, and above the next one.
  expect(lines.indexOf("ascii = true")).toBeLessThan(lines.indexOf("[ui]"))
})

test("a table the file does not have is added at the end, saying who added it", () => {
  const after = placeSetting("[ui]\nmotion = false\n", "driver", "mode", '"unsafe"')
  expect(after).toContain("[driver]")
  expect(after).toContain('mode = "unsafe"')
  expect(after.indexOf("[driver]")).toBeGreaterThan(after.indexOf("motion = false"))
  // A section this front end wrote says so; a key inside somebody's own table
  // does not, because the key is already its own anchor.
  expect(after).toContain("# nulya:")

  // The same on a file that does not exist yet.
  const fresh = placeSetting("", "ui", "theme", '"nulya-light"')
  expect(fresh).toContain("[ui]")
  expect(fresh).toContain('theme = "nulya-light"')
})

test("a file written with CRLF stays a file written with CRLF", () => {
  const before = '[transcript]\r\nmax_width = 100\r\nascii = false\r\n'
  const after = placeSetting(before, "transcript", "ascii", "true")
  expect(after).toContain("ascii = true")
  expect(after.split("\n").every((line) => line.length === 0 || line.endsWith("\r"))).toBe(true)
})

test("a value written over several lines is replaced as one value, not as one line", () => {
  const before = ["[approvals]", "allow = [", '  "git status",', '  "git diff",', "]", "", "[ui]", "motion = true", ""].join("\n")
  const after = placeSetting(before, "approvals", "allow", '["git log"]')

  expect(after).toContain('allow = ["git log"]')
  // The whole old value went, and the table after it is untouched — the danger
  // this guards against is replacing the first line and leaving the rest.
  expect(after).not.toContain("git status")
  expect(after).not.toContain('  "git diff",')
  expect(after).toContain("[ui]\nmotion = true")
})

test("a file this scanner cannot follow is refused rather than half-written", () => {
  // A multi-line basic string carrying what looks like a table header: the
  // scanner does not know `"""`, so the check that the key really came back
  // with the value asked for is what stops the write.
  const home = mkdtempSync(join(tmpdir(), "nulya-settings-"))
  try {
    const path = join(home, "tui.toml")
    const before = ['[ui]', 'note = """', "[transcript]", 'diff = "expanded"', '"""', ""].join("\n")
    writeFileSync(path, before)
    expect(() => writeSetting(path, "transcript.diff", "collapsed")).toThrow()
    expect(readFileSync(path, "utf8")).toBe(before)
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})

test("a write commits against the FRESHEST read, not the one it started with — a concurrent human edit is never lost", () => {
  // The shape of the race: `read()` answers A the first time (what the
  // write started patching against) and B — a person's own editor having
  // saved an extra line in between — the second (right before the commit).
  const A = '[transcript]\ndiff = "expanded"\n'
  const B = '[transcript]\ndiff = "expanded"\nmax_width = 120\n'
  let calls = 0
  const written: string[] = []
  const after = patchAgainstFreshest(
    () => (calls++ === 0 ? A : B),
    "transcript",
    "diff",
    "collapsed",
  )
  written.push(after)
  expect(after).toContain('diff = "collapsed"')
  // B's own edit — the human's — survived the write that raced it.
  expect(after).toContain("max_width = 120")
  expect(calls).toBe(2) // read exactly twice: once to patch, once to confirm nothing moved
})

test("when the freshest read agrees with the first, nothing about the result changes", () => {
  const same = '[transcript]\ndiff = "expanded"\n'
  const after = patchAgainstFreshest(() => same, "transcript", "diff", "collapsed")
  expect(after).toBe(placeSetting(same, "transcript", "diff", '"collapsed"'))
})

test("writeSetting leaves no temp file behind, on either a success or a refusal", () => {
  const home = mkdtempSync(join(tmpdir(), "nulya-settings-atomic-"))
  try {
    const path = join(home, "tui.toml")
    writeFileSync(path, '[transcript]\ndiff = "expanded"\n')
    writeSetting(path, "transcript.diff", "collapsed")
    expect(readFileSync(path, "utf8")).toContain('diff = "collapsed"')

    const brokenPath = join(home, "broken.toml")
    writeFileSync(brokenPath, ['[ui]', 'note = """', "[transcript]", 'diff = "expanded"', '"""', ""].join("\n"))
    expect(() => writeSetting(brokenPath, "transcript.diff", "collapsed")).toThrow()

    // Neither the successful write nor the refused one left a `.tmp-*`
    // sibling — the rename either landed or nothing was written at all.
    const leftover = readdirSync(home).filter((name) => name.includes(".tmp-"))
    expect(leftover).toEqual([])
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})

test("a layer is asked one question: does it set this key itself", () => {
  const home = mkdtempSync(join(tmpdir(), "nulya-settings-"))
  try {
    const path = join(home, "tui.toml")
    writeFileSync(path, '[transcript]\ndiff = "collapsed"\n')
    const layer = readLayer(path)
    expect(layerSets(layer, "transcript.diff")).toBe(true)
    expect(layerSets(layer, "transcript.ascii")).toBe(false)
    expect(layerSets(null, "transcript.diff")).toBe(false)
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})

test("a list is typed in the form it is shown in", () => {
  expect(draftOf({ key: "approvals.allow", value: "—", accepts: "", changed: false, edit: { kind: "list" } })).toBe("")
  expect(
    draftOf({ key: "approvals.allow", value: "git status, git diff", accepts: "", changed: true, edit: { kind: "list" } }),
  ).toBe("git status, git diff")
})

// ----------------------------------------------------------------- the panel

/**
 * A home of this run's own: the user layer is what the panel writes, and every
 * other test file in this process resolves it from `NULYA_HOME` too (`isolate.ts`).
 */
let home: string
let restore: string | undefined
let ws: TempWorkspace

beforeAll(() => {
  restore = process.env["NULYA_HOME"]
  home = mkdtempSync(join(tmpdir(), "nulya-settings-home-"))
  process.env["NULYA_HOME"] = home
  ws = tempWorkspace()
})

afterAll(() => {
  if (restore === undefined) delete process.env["NULYA_HOME"]
  else process.env["NULYA_HOME"] = restore
  ws.cleanup()
  rmSync(home, { recursive: true, force: true })
})

/**
 * The panel under a LIVE style, which is what `main.tsx` gives it: a write is
 * only finished when the screen it came from is drawn from the new file, so the
 * reload is part of what these tests drive rather than something they stub out.
 */
async function panel(render: (onEdited: () => Promise<void>) => JSX.Element, width = 100, height = 40) {
  const live = liveStyle(await loadSettings(ws.dir), {})
  const reload = async () => live.reload(await loadSettings(ws.dir))
  return await testRender(
    () => (
      <StyleContext.Provider value={live.style}>
        <FoldContext.Provider value={createFoldStore()}>{render(reload)}</FoldContext.Provider>
      </StyleContext.Provider>
    ),
    { width, height },
  )
}

/** Click the row whose line carries `text`; twice is "act on it". */
async function clickRow(setup: Awaited<ReturnType<typeof panel>>, text: string, times = 1) {
  for (let i = 0; i < times; i++) {
    const lines = frameLines(setup.captureCharFrame())
    const at = lines.findIndex((line) => line.includes(text))
    expect(at).toBeGreaterThanOrEqual(0)
    await setup.mockMouse.click(lines[at]!.indexOf(text), at)
    await settle(setup, 3)
  }
}

test("Enter on a two-value key writes the other one, and the screen is drawn from what was written", async () => {
  const setup = await panel((onEdited) => <SettingsView ws={ws} onClose={() => {}} onEdited={onEdited} />)
  try {
    await settle(setup, 4)
    // The cursor opens on the first key of the table, so Enter acts on it.
    setup.mockInput.pressEnter()
    await settle(setup, 6)

    const written = await loadSettings(ws.dir)
    expect(written.transcript.diff).toBe("collapsed")
    expect(written.sources).toContain(settingsPaths(ws.dir)[0]!)
    // The row itself moved: the write went round through the file and back to
    // the screen, which is the whole of what "it takes effect" means here.
    const row = frameLines(setup.captureCharFrame()).find((line) => line.includes("transcript.diff"))!
    expect(row).toContain("collapsed")

    // And back again: a toggle is a toggle, and the second write finds the line
    // the first one made rather than adding another.
    setup.mockInput.pressEnter()
    await settle(setup, 6)
    expect((await loadSettings(ws.dir)).transcript.diff).toBe("expanded")
    const file = readFileSync(settingsPaths(ws.dir)[0]!, "utf8")
    expect(file.match(/^diff = /gm)?.length).toBe(1)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a key with more than two values is chosen from a list, and choosing writes once", async () => {
  const setup = await panel((onEdited) => <SettingsView ws={ws} onClose={() => {}} onEdited={onEdited} />)
  try {
    await settle(setup, 4)
    await clickRow(setup, "transcript.thinking", 2)

    // The picker is up: every value of that key, with the one in force marked.
    const frame = setup.captureCharFrame()
    expect(frame).toContain("transcript.thinking")
    expect(frame).toContain("expanded")
    expect(frame).toContain("collapsed")
    // The table is not on the screen while its picker is.
    expect(frame).not.toContain("approvals.manifest_readonly")

    // Up from the value in force, so the choice is a different one.
    setup.mockInput.pressKey("k")
    setup.mockInput.pressEnter()
    await settle(setup, 6)
    expect((await loadSettings(ws.dir)).transcript.thinking).toBe("collapsed")
    // …and the table is back.
    expect(setup.captureCharFrame()).toContain("approvals.manifest_readonly")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a typed value is checked before it is written, and a bad one changes nothing", async () => {
  const setup = await panel((onEdited) => <SettingsView ws={ws} onClose={() => {}} onEdited={onEdited} />)
  try {
    await settle(setup, 4)
    await clickRow(setup, "approvals.allow", 2)

    // A list is typed in the form the value column shows it in.
    await setup.mockInput.typeText("git status, git diff")
    setup.mockInput.pressEnter()
    await settle(setup, 4)
    expect((await loadSettings(ws.dir)).approvals.allow).toEqual(["git status", "git diff"])

    // A number that is not one is refused, said in words, and not written.
    await clickRow(setup, "transcript.max_width", 2)
    await setup.mockInput.typeText("wide")
    setup.mockInput.pressEnter()
    const refused = await settle(setup, 4)
    expect(refused).toContain("whole number")
    expect((await loadSettings(ws.dir)).transcript.max_width).toBe(100)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a key the project layer sets is marked, and the write is refused rather than made where it would not count", async () => {
  const project = settingsPaths(ws.dir)[1]!
  mkdirSync(join(ws.dir, ".nulya"), { recursive: true })
  writeFileSync(project, '[ui]\nmotion = false\n')
  try {
    const setup = await panel((onEdited) => <SettingsView ws={ws} onClose={() => {}} onEdited={onEdited} />)
    try {
      await settle(setup, 4)
      const marked = frameLines(setup.captureCharFrame()).find((line) => line.includes("ui.motion"))!
      expect(marked).toContain("project layer")

      await clickRow(setup, "ui.motion", 2)
      const said = await settle(setup, 4)
      expect(said).toContain("would do nothing")
      expect(layerSets(readLayer(settingsPaths(ws.dir)[0]!), "ui.motion")).toBe(false)
    } finally {
      setup.renderer.destroy()
    }
  } finally {
    rmSync(project, { force: true })
  }
}, 60_000)

test("a binding is not written from here, and the row says where it is", async () => {
  const user = settingsPaths(ws.dir)[0]!
  writeFileSync(user, '[keys]\nhelp = "ctrl+b"\n')
  const setup = await panel((onEdited) => <SettingsView ws={ws} onClose={() => {}} onEdited={onEdited} />)
  try {
    await settle(setup, 4)
    await clickRow(setup, "keys.help", 2)
    const said = await settle(setup, 4)
    expect(said).toContain("[keys]")
    // Nothing was invented under a name whose set is open.
    expect(readFileSync(user, "utf8")).toContain('help = "ctrl+b"')
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)
