/**
 * The mouse pointer: one sequence per change, and the shape handed back on the
 * way out (`ui/pointer.ts`).
 *
 * The de-duplication is the load-bearing part. `onMouseOver` fires for every
 * cell the pointer crosses, so a version that wrote unconditionally would put
 * an escape sequence on the wire at mouse-move rate.
 */
import { expect, test } from "bun:test"
import { pointer, releasePointer, setPointerSink } from "../src/ui/pointer.ts"

function collector(): { written: string[]; write(bytes: string): void } {
  const written: string[] = []
  return { written, write: (bytes: string) => void written.push(bytes) }
}

test("a shape is asked for once, however many times it is set", () => {
  const sink = collector()
  setPointerSink(sink)
  pointer("text")
  pointer("text")
  pointer("text")
  expect(sink.written).toEqual(["\x1b]22;text\x1b\\"])
  pointer("default")
  pointer("text")
  expect(sink.written.length).toBe(3)
})

test("leaving hands the shape back to the terminal", () => {
  const sink = collector()
  setPointerSink(sink)
  pointer("text")
  releasePointer()
  expect(sink.written.at(-1)).toBe("\x1b]22;\x1b\\")
  // Nothing to give back twice.
  releasePointer()
  expect(sink.written.length).toBe(2)
})
