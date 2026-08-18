/**
 * The pin panel's policy (tui.md §11, T12).
 *
 * Two halves. The transitions and the quota line are pure — "what would the next
 * session's tool face be" is a question that must be answerable without a
 * filesystem — and the config write-back runs against real files, because it is
 * text surgery on somebody's hand-written TOML and the only proof that comments
 * survive is a comment that survived.
 *
 * The last test is the one that matters most: the whole chain, `--pin` argv into
 * a real `session new`, checked against what the kernel actually froze.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import {
  builtin_tools,
  pinState,
  promote,
  quotaLine,
  readUserPins,
  setPinnedTools,
  stateLabel,
  toggle,
  toggleAll,
  toolId,
  writeUserPins,
  type PinSources,
} from "../src/pins.ts"
import { nextFace, toolRows } from "../src/ui/overlays/ExtView.tsx"
import { readHeader } from "../src/nulya/files.ts"
import { sessionNew } from "../src/nulya/cli.ts"
import type { ExtensionEntry } from "../src/nulya/files.ts"
import { tempWorkspace, type TempWorkspace } from "./support.ts"

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

const sources = (over: Partial<PinSources> = {}): PinSources => ({
  user: [],
  session: [],
  merged: [],
  ...over,
})

test("three states, and toggling one never edits a layer this panel does not own", () => {
  const read = toolId("std", "read")
  const grep = toolId("std", "grep")
  const write = toolId("std", "write")
  const where = sources({ user: [read], session: [grep], merged: [read, write] })

  expect(pinState(read, where)).toBe("always")
  expect(pinState(grep, where)).toBe("session")
  // In the merged projection but not in the user file: a project or system layer
  // wrote it, and the panel says so instead of offering a checkbox that lies.
  expect(pinState(write, where)).toBe("other")
  expect(pinState(toolId("std", "glob"), where)).toBe("off")
  expect(stateLabel("session")).toBe("this TUI")

  const refused = toggle(write, where)
  expect(refused.user).toBeNull()
  expect(refused.session).toBeNull()
  expect(refused.notice).toContain("another config layer")
  expect(promote(write, where).user).toBeNull()
})

test("on goes to `this TUI` first; `A` is the second key that writes a config file", () => {
  const glob = toolId("std", "glob")

  // Off → session. Trying a tool out costs nothing and leaves nothing behind.
  const tried = toggle(glob, sources())
  expect(tried.session).toEqual([glob])
  expect(tried.user).toBeNull()

  // Session → off, again without touching the config.
  const dropped = toggle(glob, sources({ session: [glob] }))
  expect(dropped.session).toEqual([])
  expect(dropped.user).toBeNull()

  // `A` promotes, and takes the session copy away in the same move: two rows of
  // state for one pin would be a lie on screen even though the kernel unions.
  const forever = promote(glob, sources({ session: [glob] }))
  expect(forever.user).toEqual([glob])
  expect(forever.session).toEqual([])
  expect(promote(glob, sources({ user: [glob] })).user).toBeNull()

  // Always → off removes it from the config, which is the ONLY subtraction
  // there is: `session new` unions its two pin sources, so nothing can take a
  // config pin away for one session (D2).
  expect(toggle(glob, sources({ user: [glob], merged: [glob] })).user).toEqual([])
})

test("a package toggles together, off if any of it is on", () => {
  const ids = [toolId("std", "read"), toolId("std", "grep")]
  const on = toggleAll(ids, sources())
  expect(on.session).toEqual(ids)

  // One on is enough to make the whole gesture mean "off".
  const off = toggleAll(ids, sources({ session: [ids[0]!] }))
  expect(off.session).toEqual([])

  // A package whose tools all belong to another layer: nothing to do, said out loud.
  const theirs = toggleAll(ids, sources({ merged: ids }))
  expect(theirs.session).toBeNull()
  expect(theirs.notice).toContain("another config layer")
})

test("the quota counts the builtins, because max_tools does", () => {
  expect(builtin_tools).toBe(2)
  expect(quotaLine(8, 5)).toBe("tools 2+5/8")
  expect(quotaLine(8, 6)).toBe("tools 2+6/8")
  // Over the line the panel does not prevent anything; it says what will happen.
  expect(quotaLine(8, 7)).toContain("over registry.max_tools")
  expect(quotaLine(8, 7)).toContain("refuse")
})

test("rows come only from extensions a pin could actually resolve through", () => {
  const entries: ExtensionEntry[] = [
    entry("std", "v-1", ["read", "grep"]),
    // No `current`: `session new --pin` would fail with PinNamesUnknownExtension.
    { ...entry("mode", "v-1", ["nope"]), current: null },
    // Shadowed by an earlier root: this copy never runs.
    { ...entry("old", "v-1", ["stale"]), shadowed: true },
  ]
  const where = sources({ user: [toolId("std", "read")] })
  const rows = toolRows(entries, where, [{ toolId: toolId("std", "read"), uses: 4, ok: 3 }])
  expect(rows.map((row) => row.id)).toEqual([toolId("std", "grep"), toolId("std", "read")])
  expect(rows[1]!.state).toBe("always")
  expect(rows[1]!.uses).toBe(4)
  expect(rows[0]!.uses).toBe(0)

  // What the next session would carry: the merged config plus our own, once each.
  expect(nextFace(sources({ merged: ["a", "b"], session: ["b", "c"] }))).toEqual(["a", "b", "c"])
})

test("the config write replaces one line and leaves every other byte alone", () => {
  const written = [
    "# my nulya config",
    "",
    "[provider]",
    'active_profile = "deepseek"  # the cheap one',
    "",
    "[registry]",
    "# each pin costs a slot and prefix tokens",
    "max_tools = 8",
    'pinned_native_tools = ["ext:std/read"]',
    "",
    "[extensions]",
    "paths = []",
  ].join("\n")

  const next = setPinnedTools(written, ["ext:std/read", "ext:std/grep"])
  expect(next).toContain("# my nulya config")
  expect(next).toContain('active_profile = "deepseek"  # the cheap one')
  expect(next).toContain("# each pin costs a slot and prefix tokens")
  expect(next).toContain("max_tools = 8")
  expect(next).toContain("paths = []")
  expect(next).toContain('pinned_native_tools = ["ext:std/read", "ext:std/grep"]')
  expect(next.split("\n").filter((line) => line.startsWith("pinned_native_tools"))).toHaveLength(1)
  // And the kernel's own reader agrees with what the panel thinks it wrote.
  expect((Bun.TOML.parse(next) as any).registry.pinned_native_tools).toEqual(["ext:std/read", "ext:std/grep"])

  // A multi-line array is one span, not one line.
  const spread = ["[registry]", "pinned_native_tools = [", '  "ext:a/one",', '  "ext:b/two",', "]", "max_tools = 6"].join(
    "\n",
  )
  const flattened = setPinnedTools(spread, ["ext:a/one"])
  expect((Bun.TOML.parse(flattened) as any).registry.pinned_native_tools).toEqual(["ext:a/one"])
  expect(flattened).toContain("max_tools = 6")

  // No key: it joins the table it belongs to. No table: both appear.
  expect((Bun.TOML.parse(setPinnedTools("[registry]\nmax_tools = 6\n", ["x"])) as any).registry).toEqual({
    max_tools: 6,
    pinned_native_tools: ["x"],
  })
  const fresh = Bun.TOML.parse(setPinnedTools('[provider]\nactive_profile = "openai"\n', ["x"])) as any
  expect(fresh.registry.pinned_native_tools).toEqual(["x"])
  expect(fresh.provider.active_profile).toBe("openai")
  expect(setPinnedTools("", [])).toBe("[registry]\npinned_native_tools = []\n")
})

test("writing round-trips through the file, and reads back as the kernel would", () => {
  const path = join(ws.dir, "config.toml")
  writeFileSync(path, "[registry]\n# keep me\nmax_tools = 8\n")
  writeUserPins(path, ["ext:std/read", "ext:std/grep"])
  expect(readFileSync(path, "utf8")).toContain("# keep me")
  expect(readUserPins(path)).toEqual(["ext:std/read", "ext:std/grep"])

  writeUserPins(path, [])
  expect(readUserPins(path)).toEqual([])
  expect(readFileSync(path, "utf8")).toContain("# keep me")

  // A path that never existed is not an error: the user file is optional.
  expect(readUserPins(join(ws.dir, "nope.toml"))).toEqual([])
})

test("the `this TUI` list becomes --pin, and the kernel freezes exactly it", async () => {
  // A data extension contributes no tools, so the real end-to-end proof needs a
  // real declaration. `ext build` freezes the manifest; the pin then names a
  // tool the frozen version declares, which is what `session new` checks.
  const home = join(ws.dir, ".nulya", "extensions", "notes")
  mkdirSync(join(home, "src"), { recursive: true })
  writeFileSync(
    join(home, "extension.json"),
    JSON.stringify({
      schema: "nulya.extension/v2",
      id: "notes",
      runtime: { entry: "src/main.sh", interpreter: "sh" },
      contributes: {
        tools: [
          { name: "append", description: "add a line", input: { type: "object", properties: {} } },
          { name: "read", description: "read it back", input: { type: "object", properties: {} } },
        ],
      },
    }),
  )
  writeFileSync(join(home, "src", "main.sh"), "#!/bin/sh\ncat >/dev/null\n")

  const built = Bun.spawnSync({ cmd: [ws.bin, "ext", "sync", "--activate"], cwd: ws.dir })
  expect(new TextDecoder().decode(built.stdout)).toContain("notes")

  const pins = [toolId("notes", "append")]
  const id = await sessionNew(ws, { profile: "scripted", pin: pins })
  const header = await readHeader(ws, id)
  expect(header!.composition.native_tools).toContain("ext:notes/append")
  // The one NOT pinned is the control: membership is not a tool face (D4).
  expect(header!.composition.native_tools).not.toContain("ext:notes/read")

  // And a pin the store cannot resolve is the kernel's refusal, verbatim —
  // never something the panel predicts (DESIGN §5.1).
  await expect(sessionNew(ws, { profile: "scripted", pin: ["ext:notes/nosuch"] })).rejects.toThrow(/pin/)
})

function entry(id: string, current: string, tools: string[]): ExtensionEntry {
  return {
    id,
    current,
    versions: [{ version: current, mtime: 0 }],
    kind: "script",
    tools,
    skills: [],
    systemPrompts: [],
    permissions: { fs: [], network: [], process: [] },
    root: ".nulya/extensions",
    shadowed: false,
  }
}
