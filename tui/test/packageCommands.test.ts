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
  deprecatedActionNote,
  packageCompletions,
  parseAction,
  resolve,
  runArgs,
  withoutBuiltins,
  type PackageCommandRow,
} from "../src/packageCommands.ts"

test("parseAction reads the three verbs out of the object, keeping the run/skill target verbatim", () => {
  expect(parseAction({ with: true })).toEqual({ kind: "with" })
  expect(parseAction({ run: "propose" })).toEqual({ kind: "run", tool: "propose" })
  expect(parseAction({ skill: "std/note" })).toEqual({ kind: "skill", ref: "std/note" })
  // Whitespace inside a target is trimmed; the verb is a key, so it has none.
  expect(parseAction({ run: "  propose  " })).toEqual({ kind: "run", tool: "propose" })
  // The current spelling has nothing to warn about.
  expect(deprecatedActionNote({ with: true })).toBeNull()
  expect(deprecatedActionNote({ run: "propose" })).toBeNull()
})

test("parseAction: `wear` is the pre-D4 spelling of `with`, folded into the same kind", () => {
  expect(parseAction({ wear: true })).toEqual({ kind: "with" })
  expect(deprecatedActionNote({ wear: true })).toContain("with")
})

test("parseAction: a verb this build does not know is `unknown`, verbatim — an open vocabulary (D1)", () => {
  expect(parseAction({ review: "changes" })).toEqual({ kind: "unknown", word: "review" })
  expect(parseAction({})).toEqual({ kind: "unknown", word: "" })
  // `run`/`skill` with no target are not the closed shape either — there is no
  // tool or ref to act on, so this is the reader's fallback too.
  expect(parseAction({ run: true })).toEqual({ kind: "unknown", word: "run" })
  expect(parseAction({ skill: true })).toEqual({ kind: "unknown", word: "skill" })
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

function row(id: string, name: string, action: Record<string, unknown> = { with: true }): PackageCommandRow {
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
