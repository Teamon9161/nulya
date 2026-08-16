/**
 * The kernel shapes `src/nulya/ledger.ts` reads back — the parts of a tool
 * result that a card turns into a chip. No renderer, no binary.
 */
import { expect, test } from "bun:test"
import { cancelMarkerOf, capabilitySummary, shellExitCode, splitShellOutput } from "../src/nulya/ledger.ts"

test("a plain shell result splits into stdout, stderr and the exit code", () => {
  const split = splitShellOutput("hello\nworld\n--- stderr ---\nwarn: x\n[exit 3]")
  expect(split.stdout).toBe("hello\nworld")
  expect(split.stderr).toBe("warn: x")
  expect(split.exit).toBe(3)
  expect(shellExitCode("[exit 0]")).toBe(0)
  expect(shellExitCode("no exit line at all")).toBeNull()
})

test("a spilled result keeps its exit code even though emit appended a footer", () => {
  // `emit.zig`: when anything was truncated the full output goes to disk and
  // `[full output: <path>]` is appended AFTER the shell tool's own `[exit N]`.
  const output = [
    "line 1",
    "[… output elided; use full output path below …]",
    "line 9000",
    "[exit 1]",
    "[full output: .nulya/scratch/spill-12-0.txt]",
  ].join("\n")
  expect(shellExitCode(output)).toBe(1)
  const split = splitShellOutput(output)
  expect(split.exit).toBe(1)
  // The footer is not part of the body: the spill path is a field of the tool
  // result already, and the card draws it once from there. (The elision marker
  // in the middle IS part of the output the model saw, and stays.)
  expect(split.stdout).not.toContain("[full output:")
  expect(split.stdout).toContain("output elided")
  expect(split.stdout).toContain("line 9000")

  // The step-budget clip footer is the same shape.
  const clipped = "some text\n[exit 0]\n[tool result clipped by step output budget; full output: .nulya/scratch/x]"
  expect(splitShellOutput(clipped)).toEqual({ stdout: "some text", stderr: "", exit: 0 })
})

test("an exit line inside the captured stdout does not win over the real one", () => {
  // The model can run a command whose own stdout contains a `[exit N]` (say it
  // printed a ledger line). The shell tool's exit line is the LAST one.
  const output = "nested says [exit 7]\nmore\n[exit 0]"
  expect(shellExitCode(output)).toBe(0)
  expect(splitShellOutput(output).stdout).toBe("nested says [exit 7]\nmore")
})

test("cancel markers are matched by their leading text", () => {
  expect(cancelMarkerOf("tool execution was canceled; side effects may be partial or unknown")).toBe(
    "canceled_executing",
  )
  expect(cancelMarkerOf("not executed because the step was canceled")).toBe("not_executed")
  expect(cancelMarkerOf("previous tool execution was interrupted before Nulya recorded results; …")).toBe(
    "interrupted",
  )
  expect(cancelMarkerOf("[exit 0]")).toBeNull()
})

test("a capability note's head line names its tools and skills", () => {
  const summary = capabilitySummary(
    ["Tools:", "- lint_zig — Lint Zig sources.", "  invoke: …", "", "Skills:", "- zig-style — House style."].join("\n"),
  )
  expect(summary).toEqual({ tools: ["lint_zig"], skills: ["zig-style"] })
})
