import { expect, test } from "bun:test"
import { testRender, useKeyboard } from "@opentui/solid"
import { createTestRenderer } from "@opentui/core/testing"
import type { ParsedKey } from "@opentui/core"
import { createWin32KeyHandler, installWin32Keyboard } from "../src/terminalkeys.ts"
import { Composer } from "../src/ui/Composer.tsx"
import { StyleContext, createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { settle } from "./support.ts"

const record = (vk: number, unit = 0, state = 0, down = 1, repeat = 1) =>
  `\x1b[${vk};0;${unit};${down};${state};${repeat}_`
const style = createStyle(default_settings, {})

test("Win32 records preserve shortcut modifiers, named keys, repeats and printable AltGr", () => {
  const keys: ParsedKey[] = []
  const decode = createWin32KeyHandler((key) => keys.push(key))
  decode(record(13, 13, 16))
  decode(record(13, 10, 8))
  decode(record(65, 1, 24))
  decode(record(112, 0, 8))
  decode(record(37, 0, 16))
  decode(record(50, 64, 9))
  decode(record(65, 97, 0, 1, 2))
  expect(keys.map((key) => [key.name, key.ctrl, key.shift, key.meta])).toEqual([
    ["return", false, true, false], ["return", true, false, false],
    ["a", true, true, false], ["f1", true, false, false], ["left", false, true, false],
    ["@", false, false, false], ["a", false, false, false], ["a", false, false, false],
  ])
  expect(keys.at(-1)?.eventType).toBe("repeat")
  const count = keys.length
  decode(record(13, 13, 0, 0))
  decode(record(16, 0, 16))
  expect(keys).toHaveLength(count)
  expect(decode("\x1b[A")).toBe(false)
  expect(decode("\x1b[13;0;13;2;0;1_")).toBe(false)
  expect(decode("\x1b[13;0;65536;1;0;1_")).toBe(false)
})

test("Win32 UTF-16 records preserve Chinese text and combine emoji across key-up events", () => {
  const keys: ParsedKey[] = []
  const decode = createWin32KeyHandler((key) => keys.push(key))
  decode(record(0, "中".charCodeAt(0)))
  decode(record(0, 0xd83d))
  decode(record(0, 0xd83d, 0, 0))
  decode(record(0, 0xde42))
  expect(keys.map((key) => key.sequence)).toEqual(["中", "🙂"])
  expect(decode("\x1b[;;;1;;_")).toBe(true)
})

for (const state of [0, 1, 2, 3, 4]) {
  test(`Win32 negotiation: mode state ${state} changes only a supported, initially disabled mode`, async () => {
    const setup = await createTestRenderer({ width: 30, height: 4 })
    const writes: string[] = []
    const dispose = installWin32Keyboard(setup.renderer, (sequence) => writes.push(sequence))
    try {
      expect(writes).toEqual(["\x1b[?9001$p"])
      setup.renderer.stdin.emit("data", Buffer.from(`\x1b[?9001;${state}$y`))
      setup.renderer.stdin.emit("data", Buffer.from(`\x1b[?9001;${state}$y`))
      expect(writes).toEqual(state === 2 ? ["\x1b[?9001$p", "\x1b[?9001h"] : ["\x1b[?9001$p"])
      setup.renderer.destroy()
      dispose()
      expect(writes).toEqual(state === 2
        ? ["\x1b[?9001$p", "\x1b[?9001h", "\x1b[?9001l"] : ["\x1b[?9001$p"])
    } finally {
      dispose()
      setup.renderer.destroy()
    }
  })
}

test("Win32 bytes reach Composer through the real parser: modified Enter is newline, plain Enter sends once", async () => {
  const sent: string[] = []
  let consumed = 0
  function Screen() {
    useKeyboard((key) => {
      if (key.name === "w" && key.ctrl) {
        key.preventDefault()
        consumed += 1
      }
    })
    return <Composer onSubmit={(text) => sent.push(text)} />
  }
  const setup = await testRender(() => (
    <StyleContext.Provider value={style}><Screen /></StyleContext.Provider>
  ), { width: 60, height: 10 })
  const writes: string[] = []
  const dispose = installWin32Keyboard(setup.renderer, (sequence) => writes.push(sequence))
  const send = (bytes: string) => setup.renderer.stdin.emit("data", Buffer.from(bytes))
  try {
    await settle(setup, 3)
    send("\x1b[?9001;2$y")
    // The terminal can split one record across pipe reads and batch many others.
    send("\x1b[0;0;")
    send(`${"中".charCodeAt(0)};1;0;1_`)
    send(record(0, 0xd83d) + record(0, 0xde42) + record(13, 13, 16))
    send(record(66, 98) + record(13, 10, 8))
    send(record(67, 99) + record(13, 13, 24))
    send(record(68, 100) + record(87, 23, 8))
    await settle(setup, 2)
    expect(sent).toEqual([])
    expect(consumed).toBe(1)
    send(record(13, 13) + record(13, 13, 0, 0))
    await settle(setup, 2)
    expect(sent).toEqual(["中🙂\nb\nc\nd"])
    // Legacy/bracketed input remains handled by OpenTUI, not our decoder.
    await setup.mockInput.pasteBracketedText("legacy\npaste")
    setup.mockInput.pressEnter()
    await settle(setup, 2)
    expect(sent.at(-1)).toBe("legacy\npaste")
  } finally {
    dispose()
    setup.renderer.destroy()
  }
}, 60_000)
