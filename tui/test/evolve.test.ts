/**
 * `/evolve` and `/mode` (T8): a package worn for one session (`src/evolve.ts`).
 *
 * The whole claim under test is that wearing something changes THIS session's
 * composition and nothing else in the workspace — no `current` pointer moves,
 * so the next plain session is exactly what it was before.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { cpSync, existsSync } from "node:fs"
import { basename, dirname, join } from "node:path"
import { buildEvolution, evolution_draft, formatWithRef, parseWithRef } from "../src/evolve.ts"
import { extList, sessionList, sessionNew } from "../src/nulya/cli.ts"
import { tempWorkspace, type TempWorkspace } from "./support.ts"

let ws: TempWorkspace

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
 * The package the repository ships (`extensions/evolution`, DESIGN §7.6). It is
 * copied into the throwaway workspace rather than built in place: a build writes
 * to the store, and the repository's own store is not a test fixture.
 */
test("/evolve builds the shipped package and wears it for one session", async () => {
  // `<repo>/zig-out/bin/nulya[.exe]` — anything else is a binary from PATH,
  // with no repository beside it, and this test has nothing to copy.
  const zigOut = dirname(dirname(ws.bin))
  if (basename(zigOut) !== "zig-out") return
  const source = join(dirname(zigOut), evolution_draft)
  if (!existsSync(source)) return
  cpSync(source, join(ws.dir, evolution_draft), { recursive: true })

  const ref = await buildEvolution(ws)
  expect(ref.id).toBe("evolution")
  expect(ref.version?.startsWith("v-")).toBe(true)
  // Building twice is the same version and the same bytes: a version id is a
  // hash of the draft (physics #5), which is what makes `/evolve` safe to run
  // whenever, without anybody remembering whether it was built.
  expect((await buildEvolution(ws)).version).toBe(ref.version)

  // Built, and deliberately NOT activated: `--with` is membership, not a pointer.
  expect((await extList(ws)).find((entry) => entry.id === "evolution")!.current).toBeNull()

  const worn = await sessionNew(ws, { profile: "scripted", with: [formatWithRef(ref)] })
  const plain = await sessionNew(ws, { profile: "scripted" })
  const listed = await sessionList(ws)
  expect(listed.find((row) => row.id === worn)!.composition.active).toEqual([`evolution@${ref.version}`])
  expect(listed.find((row) => row.id === plain)!.composition.active).toEqual([])
}, 120_000)
