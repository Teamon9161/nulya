/**
 * `@path` references.
 *
 * The first four tests are tcode's own, one for one — `reference_token_avoids_
 * email_addresses`, `reference_matching_prefers_basenames_then_fuzzy_paths`,
 * `reference_matching_prioritizes_root_files`, `reference_labels_use_basenames_
 * unless_they_conflict`. They are copied deliberately: the behaviour is ported,
 * so the failures should be too, and a divergence in scoring should read as a
 * divergence from a known-good implementation rather than as a new opinion.
 *
 * The rest is nulya's own surface: the token the cursor is inside, the accent
 * on markers that resolve, and the index built from `git ls-files`.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import {
  activeReference,
  createProjectIndex,
  formatBytes,
  indexProject,
  knownReferenceRanges,
  max_index_entries,
  referenceBoundary,
  referenceCompletions,
  referenceMarker,
  referenceMatchOrder,
  referenceScore,
  withDirectories,
  type ReferenceCandidate,
} from "../src/references.ts"
import { tempWorkspace, until, type TempWorkspace } from "./support.ts"

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
  mkdirSync(join(ws.dir, "src", "ui"), { recursive: true })
  mkdirSync(join(ws.dir, "node_modules", "junk"), { recursive: true })
  writeFileSync(join(ws.dir, "README.md"), "# hi\n")
  writeFileSync(join(ws.dir, "src", "composition.zig"), "// the frozen contract\n")
  writeFileSync(join(ws.dir, "src", "ui", "App.tsx"), "export const App = () => null\n")
  writeFileSync(join(ws.dir, "node_modules", "junk", "index.js"), "module.exports = 1\n")
})

afterAll(() => {
  ws.cleanup()
})

const files = (paths: string[]): ReferenceCandidate[] => paths.map((path) => ({ path, kind: "file" }))

test("an at-sign only opens a reference at a word boundary, so email addresses are prose", () => {
  const email = [..."me@example.com"]
  expect(referenceBoundary(email, 2)).toBe(false)
  const mention = [..."read @src"]
  expect(referenceBoundary(mention, 5)).toBe(true)
  expect(activeReference("me@example.com", 14)).toBeNull()
})

test("matching prefers basenames, then path prefixes, then subsequences", () => {
  expect(referenceScore("crates/tcode-tui/src/app.rs", "app")).toBe(0)
  expect(referenceScore("crates/tcode-tui/src/app.rs", "crates")).toBe(1)
  expect(referenceScore("crates/tcode-tui/src/app.rs", "tuiapp")).not.toBeNull()
  expect(referenceScore("crates/tcode-tui/src/app.rs", "tuiapp")).toBeGreaterThanOrEqual(10)
  expect(referenceScore("crates/tcode-tui/src/app.rs", "xyz")).toBeNull()
  // An empty query matches everything, equally: the menu on a bare `@` is the
  // whole index in path order, not a ranking of nothing.
  expect(referenceScore("anything", "")).toBe(0)
})

test("root files outrank matching descendants before the score applies", () => {
  const matches: [number, string][] = [
    [0, "src/Cargo.toml"],
    [10, "Cargo.toml"],
    [0, "README.md"],
  ]
  matches.sort(([ls, lp], [rs, rp]) => referenceMatchOrder(ls, lp, rs, rp))
  expect(matches).toEqual([
    [0, "README.md"],
    [10, "Cargo.toml"],
    [0, "src/Cargo.toml"],
  ])
})

test("the menu labels with basenames unless two candidates share one", () => {
  const index: ReferenceCandidate[] = [
    { path: "src/ui/App.tsx", kind: "file" },
    { path: "test/App.tsx", kind: "file" },
    { path: "src/ui", kind: "directory" },
  ]
  const both = referenceCompletions(index, "app")
  // Two `App.tsx`: showing the basename twice would make the menu unusable.
  expect(both.map((m) => m.label).sort()).toEqual(["@src/ui/App.tsx", "@test/App.tsx"])

  const alone = referenceCompletions(index.slice(0, 1), "app")
  expect(alone[0]!.label).toBe("@App.tsx")
  expect(alone[0]!.replacement).toBe("@src/ui/App.tsx")
  expect(alone[0]!.description).toBe("file")

  const dir = referenceCompletions(index, "ui")[0]!
  expect(dir.replacement).toBe("@src/ui/")
  expect(dir.description).toBe("directory")

  // A path with a space in it has to be quoted, or the token ends at the space.
  expect(referenceMarker("my notes/todo.md")).toBe('@"my notes/todo.md"')
  expect(referenceMarker("src/app.ts")).toBe("@src/app.ts")
  expect(formatBytes(512)).toBe("512 B")
  expect(formatBytes(2048)).toBe("2.0 KiB")
  expect(formatBytes(3 * 1024 * 1024)).toBe("3.0 MiB")
})

test("the token under the cursor is the trigger, and it ends where the token does", () => {
  expect(activeReference("read @comp", 10)).toEqual({ start: 5, end: 10, query: "comp" })
  // A bare `@` is a valid trigger: the menu is the whole index.
  expect(activeReference("@", 1)).toEqual({ start: 0, end: 1, query: "" })
  // Mid-token: the query is what is BEHIND the cursor, the replacement is the
  // whole token — typing into the middle of a path must not orphan its tail.
  expect(activeReference("@src/app.ts", 5)).toEqual({ start: 0, end: 11, query: "src/" })
  // Past the end of a finished token there is nothing to complete.
  expect(activeReference("@src/app.ts and more", 20)).toBeNull()
  // Quoted references may hold spaces, and end at the closing quote.
  expect(activeReference('@"my notes/to', 13)).toEqual({ start: 0, end: 13, query: "my notes/to" })
  expect(activeReference('@"my notes/todo.md" then', 24)).toBeNull()
  expect(activeReference("nothing here", 12)).toBeNull()
})

test("only markers that resolve get the accent; an unknown @word is prose", () => {
  const index = files(["src/app.ts", "my notes/todo.md"])
  const text = 'see @src/app.ts and @not-a-file and @"my notes/todo.md" and me@example.com'
  const lit = knownReferenceRanges(text, index).map((range) => text.slice(range.start, range.end))
  expect(lit).toEqual(["@src/app.ts", '@"my notes/todo.md"'])

  // A directory marker keeps its trailing slash in the box and still resolves.
  expect(knownReferenceRanges("@src/", [{ path: "src", kind: "directory" }])).toHaveLength(1)
  expect(knownReferenceRanges("@nope", index)).toEqual([])
})

test("the index is git's own listing, with directories derived from it", async () => {
  // Not a repository yet: the fallback walk answers, and it prunes.
  const walked = await indexProject(ws.dir)
  expect(walked.map((c) => c.path)).toContain("src/composition.zig")
  expect(walked.some((c) => c.path.startsWith("node_modules"))).toBe(false)

  Bun.spawnSync({ cmd: ["git", "init", "-q"], cwd: ws.dir })
  writeFileSync(join(ws.dir, ".gitignore"), "node_modules/\n")
  const listed = await indexProject(ws.dir)
  const paths = listed.map((c) => c.path)
  expect(paths).toContain("README.md")
  expect(paths).toContain("src/ui/App.tsx")
  // gitignore semantics come from git, not from a second implementation here.
  expect(paths.some((p) => p.startsWith("node_modules"))).toBe(false)
  // Directories are derived, so one only appears when it holds something.
  expect(listed.find((c) => c.path === "src/ui")?.kind).toBe("directory")
  expect(listed.find((c) => c.path === "src")?.kind).toBe("directory")

  // `@comp` finds the file, which is the sentence in the contract.
  const found = referenceCompletions(listed, "comp")
  expect(found[0]!.replacement).toBe("@src/composition.zig")

  expect(max_index_entries).toBe(20_000)
  expect(withDirectories(["a/b/c.txt"]).map((c) => `${c.kind}:${c.path}`)).toEqual([
    "directory:a",
    "directory:a/b",
    "file:a/b/c.txt",
  ])
})

test("the index builds in the background and reports a file's size", async () => {
  const index = createProjectIndex(ws.dir)
  await until(() => index.candidates().length > 0, 10_000)
  expect(index.size({ path: "README.md", kind: "file" })).toBe(5)
  expect(index.size({ path: "src", kind: "directory" })).toBeNull()
  expect(index.size({ path: "gone.txt", kind: "file" })).toBeNull()
  // Touching a fresh index rebuilds nothing; it never blocks a keystroke either
  // way, so the only thing to assert is that it stays usable.
  index.touch()
  expect(index.candidates().length).toBeGreaterThan(0)
})
