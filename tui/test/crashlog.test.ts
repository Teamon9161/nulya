/**
 * `ui/crashlog.ts`: what OpenTUI swallows, this writes down — once per
 * distinct error, not once per timer tick that re-throws it.
 */
import { expect, test } from "bun:test"
import { mkdtempSync, readFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { createCrashLog, formatCrash } from "../src/ui/crashlog.ts"

test("an entry carries the moment, the hook and the stack", () => {
  const line = formatCrash(new Date("2026-08-28T07:00:00Z"), "uncaughtException", new Error("boom"))
  expect(line).toStartWith("[2026-08-28T07:00:00.000Z] uncaughtException: Error: boom")
  expect(line).toEndWith("\n")
})

test("a repeating error collapses into a count", () => {
  const dir = mkdtempSync(join(tmpdir(), "crashlog-"))
  const file = join(dir, "tui-crash.log")
  const sink = createCrashLog(file, () => new Date("2026-08-28T07:00:00Z"))
  const same = new Error("poisoned")
  for (let i = 0; i < 250; i++) sink.note("heartbeat-write", same)
  sink.note("uncaughtException", new Error("different"))
  const written = readFileSync(file, "utf8")
  const lines = written.split("\n").filter((l) => l.length > 0)
  // One line for the error, a handful for the repeat counter, one for the
  // next distinct error — not 250.
  expect(lines.length).toBeLessThan(10)
  expect(written).toContain("poisoned")
  expect(written).toContain("×")
  expect(written).toContain("different")
  expect(sink.count()).toBe(251)
})

test("a log that cannot be written stays silent", () => {
  const sink = createCrashLog("/proc/definitely/not/writable/tui-crash.log")
  expect(() => sink.note("uncaughtException", new Error("boom"))).not.toThrow()
})
