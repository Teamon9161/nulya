import { parseKeypress, type CliRenderer, type ParsedKey } from "@opentui/core"

const query = "\x1b[?9001$p"
const enable = "\x1b[?9001h"
const disable = "\x1b[?9001l"

const namedKeys: Record<number, string> = {
  8: "backspace", 9: "tab", 13: "return", 27: "escape", 32: "space",
  33: "pageup", 34: "pagedown", 35: "end", 36: "home",
  37: "left", 38: "up", 39: "right", 40: "down", 45: "insert", 46: "delete",
}

/** Win32 input records carry UTF-16 units, not necessarily whole characters. */
export function createWin32KeyHandler(emit: (key: ParsedKey) => void): (sequence: string) => boolean {
  let surrogate = ""
  return (raw) => {
    const match = /^\x1b\[([\d;]*)_$/.exec(raw)
    if (!match) return false
    const fields = match[1]!.split(";")
    if (fields.length > 6) return false
    const [vk, scan, unit, down, state, repeat] = Array.from({ length: 6 }, (_, i) =>
      fields[i] ? Number(fields[i]) : i === 5 ? 1 : 0) as [number, number, number, number, number, number]
    if (![vk, scan, unit, repeat].every((value) => Number.isInteger(value) && value <= 65535)
      || !Number.isInteger(state) || state > 0xffffffff || down > 1) return false
    // Modifier-only and key-up records must not become text or submit again.
    if (!down || !repeat || (unit === 0 && (vk === 16 || vk === 17 || vk === 18 || vk === 91 || vk === 92))) return true

    let text = unit ? String.fromCharCode(unit) : ""
    if (unit >= 0xd800 && unit <= 0xdbff) {
      surrogate = text
      return true
    }
    if (unit >= 0xdc00 && unit <= 0xdfff) {
      text = surrogate ? surrogate + text : "\ufffd"
      surrogate = ""
    } else if (surrogate) {
      const replacement = parseKeypress("\ufffd")!
      emit({ ...replacement, raw })
      surrogate = ""
    }

    let ctrl = (state & 12) !== 0
    let meta = (state & 3) !== 0
    // AltGr synthesizes Ctrl+RightAlt; its printable result is ordinary text.
    if ((state & 1) !== 0 && ctrl && unit >= 32) ctrl = meta = false
    const parsed = text ? parseKeypress(text) : null
    const name = namedKeys[vk] ?? (vk >= 112 && vk <= 135 ? `f${vk - 111}`
      : ctrl && vk >= 65 && vk <= 90 ? String.fromCharCode(vk + 32) : parsed?.name)
    if (!name) return true
    const key: ParsedKey = {
      name, ctrl, meta, option: meta, shift: (state & 16) !== 0,
      sequence: text, raw, number: /^[0-9]$/.test(name), source: "raw", eventType: "press",
      capsLock: (state & 128) !== 0, numLock: (state & 32) !== 0,
    }
    for (let i = 0; i < repeat; i++) emit({ ...key, repeated: i > 0, eventType: i > 0 ? "repeat" : "press" })
    return true
  }
}

/** Query before changing modes; unsupported terminals keep their existing input. */
export function installWin32Keyboard(renderer: CliRenderer, write: (sequence: string) => void): () => void {
  const decode = createWin32KeyHandler((key) => renderer.keyInput.processParsedKey(key))
  let changed = false
  let answered = false
  let disposed = false
  const handler = (sequence: string): boolean => {
    const response = /^\x1b\[\?9001;([0-4])\$y$/.exec(sequence)
    if (!response) return decode(sequence)
    if (!answered && response[1] === "2") {
      changed = true
      write(enable)
    }
    answered = true
    return true
  }
  const dispose = () => {
    if (disposed) return
    disposed = true
    renderer.removeInputHandler(handler)
    renderer.off("destroy", dispose)
    process.off("exit", dispose)
    if (changed) write(disable)
  }
  renderer.prependInputHandler(handler)
  renderer.once("destroy", dispose)
  process.once("exit", dispose)
  write(query)
  return dispose
}
