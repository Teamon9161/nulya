/**
 * `/with` (T8): a package worn for one session (`src/with.ts`).
 *
 * The whole claim under test is that wearing something changes THIS session's
 * composition and nothing else in the workspace — no `current` pointer moves,
 * so the next plain session is exactly what it was before.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { cpSync, existsSync } from "node:fs"
import { basename, dirname, join } from "node:path"
import { formatWithRef, parseWithRef, type WithRef } from "../src/with.ts"
import { packageCommands } from "../src/extensions.ts"
import { parseAction } from "../src/packageCommands.ts"
import { extBuild, extList, extSetCurrent, sessionList, sessionNew } from "../src/nulya/cli.ts"
import { tabLabels } from "../src/ui/TabBar.tsx"
import { tempWorkspace, type TempWorkspace } from "./support.ts"
import type { Tab } from "../src/state/tabs.ts"

let ws: TempWorkspace

const evolution_draft = "extensions/evolution"

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

test("a --with ref splits into id and version, and survives the round trip", () => {
  expect(parseWithRef("evolution")).toEqual({ id: "evolution" })
  expect(parseWithRef("  evolution  ")).toEqual({ id: "evolution" })
  expect(parseWithRef("web.search@v-0123456789ab")).toEqual({ id: "web.search", version: "v-0123456789ab" })
  expect(parseWithRef("")).toBeNull()
  expect(parseWithRef("@v-1")).toBeNull()
  expect(parseWithRef("evolution@")).toBeNull()
  expect(formatWithRef({ id: "evolution" })).toBe("evolution")
  expect(formatWithRef({ id: "evolution", version: "v-1" })).toBe("evolution@v-1")
})

/**
 * A tab wearing a package says so (tui.md §11, T31).
 *
 * `/evolve` opens a SECOND tab on the same model as the first, so without this
 * the two read identically — and the only difference between them is which one
 * thinks it is the slow loop. That was the bug: nothing on screen distinguished
 * a session carrying `evolution` from one that was not.
 */
test("a draft tab is named by what it wears as well as what it runs on", () => {
  const draft = (model: string, bring?: WithRef): Tab => ({
    kind: "draft",
    key: `draft-${model}-${bring?.id ?? ""}`,
    pick: () => ({ profile: "scripted", model }),
    setPick: () => {},
    bring: () => bring,
    setBring: () => {},
    effort: () => undefined,
    setEffort: () => {},
  })

  expect(tabLabels([draft("scripted-demo")])).toEqual(["scripted-demo (new)"])
  // The version is not in the label: it is a content hash nobody reads, and the
  // question this line answers is "which tab", not "which build".
  expect(tabLabels([draft("scripted-demo", { id: "evolution", version: "v-abc123" })])).toEqual([
    "scripted-demo · evolution (new)",
  ])
  // Two tabs on one model, one of them wearing something: told apart by the
  // package, so neither needs the `#n` that identical labels fall back to.
  expect(tabLabels([draft("scripted-demo"), draft("scripted-demo", { id: "evolution" })])).toEqual([
    "scripted-demo (new)",
    "scripted-demo · evolution (new)",
  ])
})

/**
 * The package the repository ships (`extensions/evolution`, DESIGN §7.6), and
 * the path `/evolve` takes since T53: the package DECLARES the command, so it
 * reaches the slash chain the way `/ask` does — through `current`.
 *
 * Copied into the throwaway workspace rather than built in place: a build writes
 * to the store, and the repository's own store is not a test fixture.
 */
test("/evolve is the evolution package's own command, and wearing it composes one session", async () => {
  // `<repo>/zig-out/bin/nulya[.exe]` — anything else is a binary from PATH,
  // with no repository beside it, and this test has nothing to copy.
  const zigOut = dirname(dirname(ws.bin))
  if (basename(zigOut) !== "zig-out") return
  const source = join(dirname(zigOut), evolution_draft)
  if (!existsSync(source)) return
  cpSync(source, join(ws.dir, evolution_draft), { recursive: true })

  const version = await extBuild(ws, evolution_draft)
  expect(version.startsWith("v-")).toBe(true)
  // Building twice is the same version and the same bytes: a version id is a
  // hash of the draft (physics #5).
  expect(await extBuild(ws, evolution_draft)).toBe(version)

  // Built and not yet activated: no `current`, so no command. This is the whole
  // behaviour change of T53 — `/evolve` used to build on demand and therefore
  // always existed; now it exists exactly when the package is active.
  expect((await extList(ws)).find((entry) => entry.id === "evolution")!.current).toBeNull()
  expect((await packageCommands(ws)).some((row) => row.command.name === "evolve")).toBe(false)

  await extSetCurrent(ws, "activate", "evolution", version)
  const declared = (await packageCommands(ws)).find((row) => row.command.name === "evolve")
  expect(declared?.id).toBe("evolution")
  // `{with: true}`: typing it opens a tab wearing the package, activating nothing
  // further — the same verb `/with` is.
  expect(parseAction(declared!.command.action)).toEqual({ kind: "with" })
  // And the declared command is the ONLY one — nothing invents a second
  // `/evolution` from the package's name (T54: commands exist by declaration).
  expect((await packageCommands(ws)).some((row) => row.command.name === "evolution")).toBe(false)

  // Wearing is membership in ONE composition: the plain session next to it is
  // untouched, even though `current` now points somewhere.
  const worn = await sessionNew(ws, { profile: "scripted", with: ["evolution"] })
  const plain = await sessionNew(ws, { profile: "scripted" })
  const listed = await sessionList(ws)
  expect(listed.find((row) => row.id === worn)!.composition.active).toEqual([`evolution@${version}`])
  expect(listed.find((row) => row.id === plain)!.composition.active).toEqual([])
}, 120_000)
