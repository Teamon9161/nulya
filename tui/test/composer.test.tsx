/**
 * The composer on its own (`ui/Composer.tsx`): history walking, and the rule
 * that a key the screen consumed does not also edit the buffer.
 */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { useKeyboard } from "@opentui/solid"
import { Composer } from "../src/ui/Composer.tsx"
import { StyleContext, createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { settle } from "./support.ts"

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
