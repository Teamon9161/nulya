/**
 * The composer on its own (`ui/Composer.tsx`): history walking, and the rule
 * that a key the screen consumed does not also edit the buffer.
 */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { useKeyboard } from "@opentui/solid"
import { Composer, wrappedRows } from "../src/ui/Composer.tsx"
import { completions } from "../src/commands.ts"
import { displayWidth } from "../src/ui/columns.ts"
import { StyleContext, createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { frameLines, settle } from "./support.ts"
import type { ProjectIndex } from "../src/references.ts"
import type { SkillTable } from "../src/skills.ts"
import type { PackageCommandTable } from "../src/packageCommands.ts"

const style = createStyle(default_settings, {})

test("the box is as tall as what is in it", async () => {
  // The count behind the growing composer (T26). CJK is two columns wide, so a
  // line of it wraps at half the characters — the reason this counts display
  // width rather than `text.length`.
  expect(wrappedRows("", 40)).toBe(1)
  expect(wrappedRows("short", 40)).toBe(1)
  expect(wrappedRows("one\ntwo\nthree", 40)).toBe(3)
  expect(wrappedRows("a".repeat(85), 40)).toBe(3)
  expect(wrappedRows("看".repeat(30), 40)).toBe(2)
  // A trailing newline is a row: the cursor is sitting on it.
  expect(wrappedRows("one\n", 40)).toBe(2)

  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <Composer onSubmit={() => {}} />
      </StyleContext.Provider>
    ),
    { width: 40, height: 10 },
  )
  try {
    await settle(setup, 3)
    const rowsOf = (frame: string) => frame.split("\n").filter((row) => row.includes("│")).length
    expect(rowsOf(setup.captureCharFrame())).toBe(1)
    await setup.mockInput.typeText("a word that will not fit on one line of a forty column box")
    expect(rowsOf(await settle(setup, 3))).toBeGreaterThan(1)
  } finally {
    setup.renderer.destroy()
  }
})

test("Up walks the whole history, not just the last message", async () => {
  const sent: string[] = []
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <Composer onSubmit={(text) => sent.push(text)} />
      </StyleContext.Provider>
    ),
    { width: 60, height: 6 },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("one")
    setup.mockInput.pressEnter()
    await setup.mockInput.typeText("two")
    setup.mockInput.pressEnter()
    await setup.mockInput.typeText("three")
    setup.mockInput.pressEnter()
    await settle(setup, 2)
    expect(sent).toEqual(["one", "two", "three"])

    // Up recalls the most recent…
    setup.mockInput.pressArrow("up")
    expect(await settle(setup, 2)).toContain("three")
    // …and Up again keeps walking back, because the buffer is still the recalled
    // entry rather than something the user typed.
    setup.mockInput.pressArrow("up")
    let frame = await settle(setup, 2)
    expect(frame).toContain("two")
    expect(frame).not.toContain("three")
    setup.mockInput.pressArrow("up")
    frame = await settle(setup, 2)
    expect(frame).toContain("one")
    // Past the oldest there is nothing; the buffer stays.
    setup.mockInput.pressArrow("up")
    expect(await settle(setup, 2)).toContain("one")
    // Down comes forward again, and past the newest the buffer is empty.
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressArrow("down")
    setup.mockInput.pressArrow("down")
    frame = await settle(setup, 2)
    expect(frame).not.toContain("one")
    expect(frame).not.toContain("three")
    expect(frame).toContain("message nulya")

    // Editing a recalled entry hands Up/Down back to the cursor.
    setup.mockInput.pressArrow("up")
    await setup.mockInput.typeText("!")
    expect(await settle(setup, 2)).toContain("three!")
    setup.mockInput.pressArrow("up")
    expect(await settle(setup, 2)).toContain("three!")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("completions: only the first word, and an exact name still explains itself", () => {
  expect(completions("")).toEqual([])
  expect(completions("hello")).toEqual([])
  expect(completions("/s").map((c) => c.name)).toEqual(["/sessions", "/sidebar", "/settings", "/step"])
  expect(completions("/mo").map((c) => c.name)).toEqual(["/model", "/mode"])
  expect(completions("/model").map((c) => c.name)).toEqual(["/model"])
  expect(completions("/nope")).toEqual([])
  // Past the first space it is arguments, not a command being chosen.
  expect(completions("/effort ").map((c) => c.name)).toEqual(["/effort"])
  expect(completions("/write me a poem about /model")).toEqual([])
})

test("an alias completes, behind the listed names, and says where it goes", () => {
  // Not on the table (`/help` names one word per concept) but not a dead end
  // either: somebody typing another harness's word gets told where it lands.
  expect(completions("/res").map((c) => c.name)).toEqual(["/resume"])
  expect(completions("/resume")[0]?.what).toContain("/sessions")
  // A listed name beats an alias for the same prefix: `/effort` is the concept.
  expect(completions("/e").map((c) => c.name)).toEqual(["/effort", "/env", "/ext", "/exit"])
})

test("a `/` line lists the commands it could still be, and Tab finishes it", async () => {
  const sent: string[] = []
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <Composer onSubmit={(text) => sent.push(text)} />
      </StyleContext.Provider>
    ),
    { width: 90, height: 14 },
  )
  try {
    await settle(setup, 3)
    // Nothing typed: no menu.
    expect(await settle(setup, 2)).not.toContain("/sessions")

    await setup.mockInput.typeText("/se")
    let frame = await settle(setup, 3)
    expect(frame).toContain("/sessions")
    expect(frame).toContain("/settings")
    expect(frame).not.toContain("/model")

    // Tab completes to the first match; the menu narrows to it.
    setup.mockInput.pressTab()
    frame = await settle(setup, 3)
    expect(frame).toContain("/sessions")
    expect(frame).not.toContain("/settings")
    setup.mockInput.pressEnter()
    await settle(setup, 2)
    // Enter sends what is written — the completion is text, not a selection.
    // The trailing space is the argument affordance: `/sessions` takes an
    // optional id, and every command that takes one is completed with room for
    // it. `runCommand` trims, so a bare Enter still means the bare command.
    expect(sent).toEqual(["/sessions "])
    expect(await settle(setup, 2)).not.toContain("/settings")

    // A command that takes arguments is completed with room for them, and the
    // menu keeps explaining it while they are typed.
    await setup.mockInput.typeText("/ef")
    setup.mockInput.pressTab()
    await setup.mockInput.typeText("high")
    frame = await settle(setup, 3)
    expect(frame).toContain("/effort high")
    expect(frame).toContain("the next step runs with it")

    // Ordinary prose that happens to contain a slash gets no menu.
    setup.mockInput.pressEnter()
    await setup.mockInput.typeText("look at src/main.zig")
    frame = await settle(setup, 3)
    expect(frame).not.toContain("Tab completes")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("both completion menus at eighty columns: one row a candidate, cut, nothing wrapped", async () => {
  // Two things nobody sizes a fixed column for: a skill's description (clipped
  // at a hundred characters, which is still wider than this screen) and a path
  // out of somebody else's repository.
  const skills: SkillTable = {
    entries: () => [
      {
        ref: "ext:a-package@v-1/settle",
        name: "settle",
        description:
          "settle a long-running argument about layout by measuring every cell twice and writing the answer down where the next reader will find it",
      },
    ],
    invalidate: () => {},
    ready: async () => [],
  }
  // Two files of the same name: the menu then labels both with their whole
  // path, which is where a `@` row grows past any column.
  const index: ProjectIndex = {
    candidates: () => [
      { path: "src/settle.ts", kind: "file" },
      { path: "src/very/deep/nesting/that/nobody/planned/for/settle.ts", kind: "file" },
    ],
    touch: () => {},
    size: () => 4096,
  }
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <Composer onSubmit={() => {}} references={index} skills={skills} />
      </StyleContext.Provider>
    ),
    { width: 76, height: 16 },
  )
  const fits = (frame: string) => {
    for (const line of frameLines(frame)) expect(displayWidth(line)).toBeLessThanOrEqual(76)
    return frame
  }
  try {
    await settle(setup, 3)

    // The `/` menu: the built-in verb and the skill under it, each one row.
    await setup.mockInput.typeText("/se")
    const slash = fits(await settle(setup, 4))
    expect(slash).toContain("/sessions")
    expect(slash).toContain("/settle")
    expect(slash).toContain("…")
    expect(slash).not.toContain("where the next reader will find it")
    const rows = frameLines(slash)
    const sessions = rows.find((line) => line.includes("/sessions"))!
    const settle_row = rows.find((line) => line.includes("/settle"))!
    // One offset for the description column, and a gutter in front of it.
    expect(sessions.indexOf("everything in")).toBe(settle_row.indexOf("settle a long"))
    expect(sessions).toMatch(/\/sessions \[<id>\] {2,}everything in/)

    // The `@` menu: a path longer than the screen is cut, not wrapped.
    setup.mockInput.pressEnter()
    await setup.mockInput.typeText("read @settle")
    const at = fits(await settle(setup, 4))
    expect(at).toContain("@src/settle.ts")
    expect(at).toContain("…")
    expect(at).not.toContain("nobody/planned/for/settle.ts")
    expect(at).toMatch(/@src\/settle\.ts {2,}file · 4/)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a skill sharing a name with a declared package command is offered once, as the command", async () => {
  // `evolution` contributes both a `/evolve` command and a skill directory
  // whose SKILL.md is named `evolve` — dispatch always tries the package
  // command first (`runPackageCommand` before `skillTurn`), so the skill
  // entry can never actually be what Enter runs. Listing it too would show a
  // row the menu could not reach.
  const skills: SkillTable = {
    entries: () => [{ ref: "ext:evolution@v-1/evolve", name: "evolve", description: "report template and recipes" }],
    invalidate: () => {},
    ready: async () => [],
  }
  const packages: PackageCommandTable = {
    entries: () => [
      {
        id: "evolution",
        name: "evolve",
        description: "reviews finished sessions",
        action: { with: "Review the recent sessions." },
      },
    ],
    invalidate: () => {},
    ready: async () => [],
  }
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <Composer onSubmit={() => {}} skills={skills} packages={packages} />
      </StyleContext.Provider>
    ),
    { width: 76, height: 16 },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("/evo")
    const frame = await settle(setup, 4)
    // One row, not two — and it is the package's own description, not the
    // skill's, since the package command is what dispatch would actually run.
    expect((frame.match(/\/evolve\b/g) ?? []).length).toBe(1)
    expect(frame).toContain("reviews finished sessions")
    expect(frame).not.toContain("report template and recipes")
  } finally {
    setup.renderer.destroy()
  }
})

test("an `@` lists project paths, ↑↓ picks one and Tab writes the path in", async () => {
  const sent: string[] = []
  // A fixed index rather than a real repository: what is under test here is the
  // interaction, and `references.test.ts` is where the index comes from a real
  // `git ls-files`.
  const index: ProjectIndex = {
    candidates: () => [
      { path: "src/composition.zig", kind: "file" },
      { path: "src/compact.ts", kind: "file" },
      { path: "README.md", kind: "file" },
    ],
    touch: () => {},
    size: () => 120,
  }
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <Composer onSubmit={(text) => sent.push(text)} references={index} />
      </StyleContext.Provider>
    ),
    { width: 90, height: 14 },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("read @comp")
    let frame = await settle(setup, 3)
    expect(frame).toContain("@compact.ts")
    expect(frame).toContain("@composition.zig")
    expect(frame).not.toContain("README")
    expect(frame).toContain("120 B")

    // ↑↓ move the menu's selection and nothing else while it is up.
    setup.mockInput.pressArrow("down")
    await settle(setup, 2)
    setup.mockInput.pressTab()
    frame = await settle(setup, 3)
    expect(frame).toContain("read @src/composition.zig")
    // The token is gone, so the menu is too.
    expect(frame).not.toContain("Tab inserts the path")

    setup.mockInput.pressEnter()
    await settle(setup, 2)
    // The path goes in as TEXT; the file's contents are the model's to fetch (D5).
    expect(sent).toEqual(["read @src/composition.zig "])

    // An email address is prose, not a half-typed reference.
    await setup.mockInput.typeText("write to me@example.com")
    frame = await settle(setup, 3)
    expect(frame).not.toContain("Tab inserts the path")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a long paste folds into a placeholder and comes back whole on submit", async () => {
  const sent: string[] = []
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <Composer onSubmit={(text) => sent.push(text)} />
      </StyleContext.Provider>
    ),
    { width: 90, height: 14 },
  )
  try {
    await settle(setup, 3)
    // Short pastes are unchanged: this is the behaviour that must not regress.
    await setup.mockInput.pasteBracketedText("a short one")
    expect(await settle(setup, 3)).toContain("a short one")
    setup.mockInput.pressEnter()
    await settle(setup, 2)
    expect(sent).toEqual(["a short one"])

    const long = Array.from({ length: 40 }, (_, i) => `line ${i}`).join("\n")
    await setup.mockInput.typeText("look at ")
    await setup.mockInput.pasteBracketedText(long)
    let frame = await settle(setup, 4)
    // The box shows a token, not forty lines, and says what the token holds.
    expect(frame).toContain("[Pasted text #1]")
    expect(frame).toContain("40 lines")
    expect(frame).not.toContain("line 39")

    setup.mockInput.pressEnter()
    await settle(setup, 3)
    // What reaches the caller is exactly what was pasted, where it was pasted.
    expect(sent[1]).toBe(`look at ${long}`)

    // One Backspace takes the whole token rather than chewing the `]` off it.
    await setup.mockInput.pasteBracketedText(long)
    expect(await settle(setup, 3)).toContain("[Pasted text #2]")
    setup.mockInput.pressBackspace()
    frame = await settle(setup, 3)
    expect(frame).not.toContain("[Pasted text #2]")
    expect(frame).not.toContain("40 lines")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a key the screen consumed does not also edit the buffer", async () => {
  // The screen's global listener runs before the focused textarea; without
  // `preventDefault()` a consumed key (say Ctrl+W bound to close-tab) would ALSO
  // fire the textarea's own binding for it (delete the word behind the cursor).
  let consumed = 0
  function Screen() {
    useKeyboard((key) => {
      if (key.name === "w" && key.ctrl) {
        key.preventDefault()
        consumed += 1
      }
    })
    return <Composer onSubmit={() => {}} />
  }
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <Screen />
      </StyleContext.Provider>
    ),
    { width: 60, height: 6 },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("keep this word")
    expect(await settle(setup, 2)).toContain("keep this word")
    setup.mockInput.pressKey("w", { ctrl: true })
    expect(consumed).toBe(1)
    expect(await settle(setup, 2)).toContain("keep this word")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)


test("disabled composer stays visible but does not take text", async () => {
  const sent: string[] = []
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <Composer disabled onSubmit={(text) => sent.push(text)} />
      </StyleContext.Provider>
    ),
    { width: 60, height: 6 },
  )
  try {
    await settle(setup, 3)
    expect(setup.captureCharFrame()).toContain("message nulya")
    await setup.mockInput.typeText("should not land")
    setup.mockInput.pressEnter()
    const frame = await settle(setup, 3)
    expect(frame).toContain("message nulya")
    expect(frame).not.toContain("should not land")
    expect(sent).toEqual([])
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)


test("Ctrl+V pastes clipboard TEXT too, and a long one folds like any other paste", async () => {
  const long = Array.from({ length: 40 }, (_, i) => `line ${i}`).join("\n")
  let holds = "just this"
  const sent: string[] = []
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <Composer
          readClipboard={async () => ({
            status: "read",
            representation: { mimeType: "text/plain", bytes: new TextEncoder().encode(holds) },
          })}
          onSubmit={(text) => sent.push(text)}
        />
      </StyleContext.Provider>
    ),
    { width: 70, height: 12 },
  )
  try {
    await settle(setup, 3)
    // The gesture used to be claimed and then spent looking for an image, so on
    // a terminal that hands the key over a text paste vanished.
    setup.mockInput.pressKey("v", { ctrl: true })
    expect(await settle(setup, 4)).toContain("just this")

    holds = long
    setup.mockInput.pressKey("v", { ctrl: true })
    expect(await settle(setup, 4)).toContain("[Pasted text #1]")

    setup.mockInput.pressEnter()
    await settle(setup, 3)
    // What the placeholder stood for is what gets sent, exactly as through the
    // bracketed path: one gesture, one fold, one expansion.
    expect(sent).toHaveLength(1)
    expect(sent[0]).toBe(`just this${long}`)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)


test("Ctrl+V attaches a clipboard image and submits it as an image block", async () => {
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])
  const sent: { text: string; images: readonly { bytes: Uint8Array; mediaType: string }[] }[] = []
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <Composer
          readClipboard={async () => ({ status: "read", representation: { mimeType: "image/png", bytes: png } })}
          onSubmit={(text, _interrupt, images = []) => sent.push({ text, images })}
        />
      </StyleContext.Provider>
    ),
    { width: 70, height: 10 },
  )
  try {
    await settle(setup, 3)
    setup.mockInput.pressKey("v", { ctrl: true })
    let frame = await settle(setup, 4)
    expect(frame).toContain("[Image #1]")
    expect(frame).toContain("image/png")

    await setup.mockInput.typeText(" explain this")
    setup.mockInput.pressEnter()
    await settle(setup, 3)
    expect(sent).toHaveLength(1)
    expect(sent[0]!.text).toBe(" explain this")
    expect(sent[0]!.images).toHaveLength(1)
    expect(sent[0]!.images[0]!.bytes).toEqual(png)

    // The same whole-token Backspace behaviour as folded text attachments.
    setup.mockInput.pressKey("v", { ctrl: true })
    frame = await settle(setup, 4)
    expect(frame).toContain("[Image #2]")
    setup.mockInput.pressBackspace()
    expect(await settle(setup, 3)).not.toContain("[Image #2]")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)
