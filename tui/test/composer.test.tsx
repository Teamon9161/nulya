/**
 * The composer on its own (`ui/Composer.tsx`): history walking, and the rule
 * that a key the screen consumed does not also edit the buffer.
 */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { useKeyboard } from "@opentui/solid"
import { Composer } from "../src/ui/Composer.tsx"
import { completions } from "../src/commands.ts"
import { StyleContext, createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { settle } from "./support.ts"
import type { ProjectIndex } from "../src/references.ts"

const style = createStyle(default_settings, {})

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
  expect(completions("/s").map((c) => c.name)).toEqual(["/sessions", "/settings", "/step"])
  expect(completions("/mo").map((c) => c.name)).toEqual(["/model", "/mode"])
  expect(completions("/model").map((c) => c.name)).toEqual(["/model"])
  expect(completions("/nope")).toEqual([])
  // Past the first space it is arguments, not a command being chosen.
  expect(completions("/effort ").map((c) => c.name)).toEqual(["/effort"])
  expect(completions("/write me a poem about /model")).toEqual([])
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
    expect(sent).toEqual(["/sessions"])
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
