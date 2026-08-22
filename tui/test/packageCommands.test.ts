/**
 * The pure half of package-declared slash commands (goals/tui-plugin.md U2):
 * parsing a `Command.action`, the args a `run <tool>` sends, and the merge
 * rules the composer's completion menu and `ui/App.tsx`'s dispatch share.
 *
 * The harvesting half (`extensions.packageCommands`, one `ext list` plus a
 * manifest read per active id) is exercised against the real binary in
 * `test/plugin.test.ts`, alongside dispatch through the actual UI.
 */
import { expect, test } from "bun:test"
import {
  dedupe,
  isDeprecatedWearAction,
  packageCompletions,
  parseAction,
  resolve,
  runArgs,
  withoutBuiltins,
  type PackageCommandRow,
} from "../src/packageCommands.ts"

test("parseAction reads the three verbs, keeping the run/skill target verbatim", () => {
  expect(parseAction("with")).toEqual({ kind: "with" })
  expect(parseAction("run propose")).toEqual({ kind: "run", tool: "propose" })
  expect(parseAction("skill std/note")).toEqual({ kind: "skill", ref: "std/note" })
  // Whitespace around the verb itself is trimmed; the target keeps its own.
  expect(parseAction("  with  ")).toEqual({ kind: "with" })
})

test("parseAction: `wear` is the pre-D4 spelling, folded into the same `with` kind for one release", () => {
  expect(parseAction("wear")).toEqual({ kind: "with" })
  expect(parseAction("  wear  ")).toEqual({ kind: "with" })
  expect(isDeprecatedWearAction("wear")).toBe(true)
  expect(isDeprecatedWearAction("  wear  ")).toBe(true)
  expect(isDeprecatedWearAction("with")).toBe(false)
  expect(isDeprecatedWearAction("run propose")).toBe(false)
})

test("parseAction: a word this build does not know is `unknown`, verbatim — an open vocabulary (D1)", () => {
  expect(parseAction("review changes")).toEqual({ kind: "unknown", word: "review changes" })
  expect(parseAction("")).toEqual({ kind: "unknown", word: "" })
  // `run`/`skill` with nothing after the verb are not the closed shape either —
  // there is no tool or ref to act on, so this is the reader's fallback too.
  expect(parseAction("run")).toEqual({ kind: "unknown", word: "run" })
  expect(parseAction("skill")).toEqual({ kind: "unknown", word: "skill" })
})

test("runArgs: empty text is no arguments, literal JSON objects pass through verbatim", () => {
  expect(runArgs("")).toEqual({})
  expect(runArgs('{"path":"src"}')).toEqual({ path: "src" })
  expect(runArgs("42")).toEqual({ text: "42" })
  expect(runArgs("[1,2,3]")).toEqual({ text: "[1,2,3]" })
})

test("runArgs: free text is wrapped, because ext run's own CLI requires a JSON object", () => {
  expect(runArgs("find the parser")).toEqual({ text: "find the parser" })
})

function row(id: string, name: string, action = "with"): PackageCommandRow {
  return { id, name, description: `${name} from ${id}`, action }
}

test("withoutBuiltins: a built-in name is never offered to a package, no matter who declares it", () => {
  const builtins = new Set(["model", "mode"])
  const rows = [row("plan", "model"), row("plan", "review"), row("ask", "mode")]
  expect(withoutBuiltins(rows, builtins)).toEqual([row("plan", "review")])
})

test("dedupe: two packages declaring the same name — the first in scan order wins, the rest are reported", () => {
  const rows = [row("plan", "review"), row("other", "review"), row("plan", "todo")]
  const { winners, shadowed } = dedupe(rows)
  expect(winners).toEqual([row("plan", "review"), row("plan", "todo")])
  expect(shadowed).toEqual([{ row: row("other", "review"), heldBy: "plan" }])
})

test("resolve: built-ins first, then first-in-scan-order per name — one function, no dispatcher writes it twice", () => {
  const builtins = new Set(["model"])
  const rows = [row("plan", "model"), row("plan", "review"), row("other", "review")]
  const { winners, shadowed } = resolve(rows, builtins)
  expect(winners).toEqual([row("plan", "review")])
  // The built-in-shadowed row never even reaches the name-collision check.
  expect(shadowed).toEqual([{ row: row("other", "review"), heldBy: "plan" }])
})

test("packageCompletions: prefix matches while typing, exact match keeps the description up once the space lands", () => {
  const rows = [row("plan", "plan"), row("plan", "planner")]
  expect(packageCompletions(rows, "/pl").map((m) => m.name)).toEqual(["/plan", "/planner"])
  expect(packageCompletions(rows, "/plan args").map((m) => m.name)).toEqual(["/plan"])
  expect(packageCompletions(rows, "not a slash")).toEqual([])
  expect(packageCompletions(rows, "/nope args")).toEqual([])
})
