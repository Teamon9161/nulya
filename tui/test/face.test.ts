/**
 * The tool-face panel's policy.
 *
 * Two halves. The transitions and the quota line are pure — "what would the next
 * session's tool face be" is a question that must be answerable without a
 * filesystem — and the config write-back runs against real files, because it is
 * text surgery on somebody's hand-written TOML and the only proof that comments
 * survive is a comment that survived.
 *
 * The last test is the one that matters most: the whole chain, a member's tool
 * selection into a real `session new`, checked against what the kernel froze.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import {
  builtin_tools,
  deselectAll,
  faceFullLine,
  faceState,
  orphanTools,
  promote,
  quotaLine,
  readUserSelection,
  resolvableSelections,
  selectAll,
  setMembers,
  stateLabel,
  toggle,
  toolId,
  writeUserSelection,
  type FaceSources,
} from "../src/face.ts"
import { foldLine, foldedRows, nextFace, shownRows, switchState, toolRows } from "../src/ui/overlays/ExtView.tsx"
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

const sources = (over: Partial<FaceSources> = {}): FaceSources => ({
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

  expect(faceState(read, where)).toBe("always")
  expect(faceState(grep, where)).toBe("session")
  // In the merged projection but not in the user file: a project or system layer
  // wrote it, and the panel says so instead of offering a checkbox that lies.
  expect(faceState(write, where)).toBe("other")
  expect(faceState(toolId("std", "glob"), where)).toBe("off")
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

test("the switch moves a whole package: on only adds, off clears both lists it owns", () => {
  const ids = [toolId("std", "read"), toolId("std", "grep")]

  // ON only ever adds. Turning an extension on must not take a pin off
  // something else, and a tool already on stays exactly where it was written.
  expect(selectAll(ids, sources()).session).toEqual(ids)
  const half = selectAll(ids, sources({ user: [ids[0]!] }))
  expect(half.session).toEqual([ids[1]!])
  expect(half.user).toBeNull()
  expect(selectAll(ids, sources({ session: ids })).session).toBeNull()

  // OFF clears BOTH lists this panel writes — including `always`, which no
  // other key here subtracts: a pin left behind by a deactivation does not cost
  // a tool, it makes `session new` refuse outright.
  const off = deselectAll(ids, sources({ user: [ids[0]!], session: [ids[1]!] }))
  expect(off.user).toEqual([])
  expect(off.session).toEqual([])

  // A pin some other layer wrote still cannot be touched, and is named.
  const theirs = deselectAll(ids, sources({ merged: ids }))
  expect(theirs.user).toBeNull()
  expect(theirs.session).toBeNull()
  expect(theirs.notice).toContain("another config layer")
})

test("the switch state is the two axes read together, and `partial` is what it is called", () => {
  // Both axes agree.
  expect(switchState(true, 2, 2)).toBe("active")
  expect(switchState(true, 0, 0)).toBe("active") // a data package: no tools to pin
  expect(switchState(false, 2, 0)).toBe("inactive")
  // Active, half its face pinned — the state the panel used to draw nowhere.
  expect(switchState(true, 5, 3)).toBe("partial")
  // Pinned but no longer active: the one that makes `session new` refuse.
  expect(switchState(false, 1, 1)).toBe("partial")

  // Which is why those pins are dropped rather than kept.
  expect(orphanTools(["ext:std/read", "ext:gone/x"], ["ext:std/read"])).toEqual(["ext:gone/x"])
  expect(orphanTools([], ["ext:std/read"])).toEqual([])
})

test("the quota counts the builtin, because max_tools does", () => {
  expect(builtin_tools).toBe(1)
  expect(quotaLine(8, 5)).toBe("tools 1+5/8")
  expect(quotaLine(8, 6)).toBe("tools 1+6/8")
  // Over the line the panel does not prevent anything; it says what will happen
  // — in a sentence, and with the way out in it. `2+9/8 · nothing changed` was
  // the whole explanation somebody got for a switch that would not switch
  //.
  expect(quotaLine(8, 8)).toContain("tools 1+8/8")
  expect(quotaLine(8, 8)).toContain("1 more than registry.max_tools allows")
  expect(quotaLine(8, 8)).toContain("take one off in the tools pane")
  expect(quotaLine(8, 10)).toContain("3 more than registry.max_tools allows")
})

test("a full tool face refuses the selection, not the extension", () => {
  // What the switch says when it activated something and could not select its
  // tools: how full, how many are off the face, and both ways to use them.
  const line = faceFullLine(8, 6, 1)
  expect(line).toContain("tool face is full at 1+6/8")
  expect(line).toContain("1 tool left off")
  expect(line).toContain("Space in the tools pane")
  expect(line).toContain("ext run")
  expect(faceFullLine(8, 6, 2)).toContain("2 tools left off")
})

test("rows come only from extensions a selection could actually resolve through", () => {
  const entries: ExtensionEntry[] = [
    entry("std", "v-1", ["read", "grep"]),
    // No `current`: `session new --with` would fail — there is nothing to resolve.
    { ...entry("mode", "v-1", ["nope"]), current: null },
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

test("collapsed, the list is the switches: `auto` and `internal` rows both fold away", () => {
  // The surfaces are the packages' own — which is why `agent`
  // splits: one pinnable tool, three internal ones.
  const entries: ExtensionEntry[] = [
    { ...entry("agent", "v-1", ["agent", "list", "render", "run"]), manualTools: ["agent"], internalTools: ["list", "render", "run"] },
    { ...entry("compact", "v-1", ["compact"]), manualTools: [], internalTools: ["compact"] },
    { ...entry("plan", "v-1", ["propose", "todo"]), manualTools: [], autoTools: ["propose", "todo"] },
    entry("std", "v-1", ["read", "grep"]),
  ]
  const rows = toolRows(entries, sources({ user: [toolId("std", "read")] }), [])

  // Collapsed: every remaining row is a switch somebody can throw. The `auto`
  // pair is gone with the internal four — a checkbox no key in this pane can
  // change is worse than no row.
  expect(shownRows(rows, false).map((row) => row.id)).toEqual([
    toolId("agent", "agent"),
    toolId("std", "grep"),
    toolId("std", "read"),
  ])
  expect(shownRows(rows, true).map((row) => row.id)).toEqual(rows.map((row) => row.id))
  expect(foldedRows(rows)).toHaveLength(6)

  // The line groups them by the word that explains each: they have no checkbox
  // for two different reasons, and one count would say neither.
  const line = foldLine(foldedRows(rows), false)
  expect(line).toContain("2 auto")
  expect(line).toContain("4 internal")
  expect(line).toContain("d shows")
  expect(foldLine(foldedRows(rows), true)).toContain("d folds")
  // A fold holding one kind names only that kind.
  expect(foldLine(foldedRows(toolRows([entries[1]!], sources({}), [])), false)).not.toContain("auto")

  // A row with a pin somehow down stays visible whatever its surface: it is the
  // one row here that IS a state, and taking it back is what this pane is for.
  const pinned = toolRows(entries, sources({ user: [toolId("compact", "compact")] }), [])
  expect(shownRows(pinned, false).map((row) => row.id)).toContain(toolId("compact", "compact"))
  expect(foldedRows(pinned)).toHaveLength(5)
})

test("the config write replaces one line and leaves every other byte alone", () => {
  const written = [
    "# my nulya config",
    "",
    "[provider]",
    'active_profile = "deepseek"  # the cheap one',
    "",
    "[registry]",
    "max_tools = 8",
    "",
    "[extensions]",
    "# each selected tool costs a slot and prefix tokens",
    'with = ["std:read"]',
    "paths = []",
  ].join("\n")

  const next = setMembers(written, ["std:read,grep"])
  expect(next).toContain("# my nulya config")
  expect(next).toContain('active_profile = "deepseek"  # the cheap one')
  expect(next).toContain("# each selected tool costs a slot and prefix tokens")
  expect(next).toContain("max_tools = 8")
  expect(next).toContain("paths = []")
  expect(next.split("\n").filter((line: string) => line.startsWith("with"))).toHaveLength(1)
  // And the kernel's own reader agrees with what the panel thinks it wrote.
  expect((Bun.TOML.parse(next) as any).extensions.with).toEqual(["std:read,grep"])

  // A multi-line array is one span, not one line.
  const spread = ["[extensions]", "with = [", '  "a",', '  "b",', "]", "paths = []"].join("\n")
  const flattened = setMembers(spread, ["a"])
  expect((Bun.TOML.parse(flattened) as any).extensions.with).toEqual(["a"])
  expect(flattened).toContain("paths = []")

  // No key: it joins the table it belongs to. No table: both appear.
  expect((Bun.TOML.parse(setMembers("[extensions]\npaths = []\n", ["x"])) as any).extensions).toEqual({
    paths: [],
    with: ["x"],
  })
  const fresh = Bun.TOML.parse(setMembers('[provider]\nactive_profile = "openai"\n', ["x"])) as any
  expect(fresh.extensions.with).toEqual(["x"])
  expect(fresh.provider.active_profile).toBe("openai")
})

test("writing round-trips through the file, leaving membership somebody wrote alone", () => {
  const path = join(ws.dir, "config.toml")
  writeFileSync(path, '[extensions]\n# keep me\nwith = ["guide"]\n')
  writeUserSelection(path, ["ext:std/read", "ext:std/grep"])
  expect(readFileSync(path, "utf8")).toContain("# keep me")
  expect(readUserSelection(path)).toEqual(["ext:std/read", "ext:std/grep"])
  // The bare member nobody selected a tool for is still a member.
  expect((Bun.TOML.parse(readFileSync(path, "utf8")) as any).extensions.with).toContain("guide")

  writeUserSelection(path, [])
  expect(readUserSelection(path)).toEqual([])
  expect((Bun.TOML.parse(readFileSync(path, "utf8")) as any).extensions.with).toEqual(["guide", "std"])

  // A path that never existed is not an error: the user file is optional.
  expect(readUserSelection(join(ws.dir, "nope.toml"))).toEqual([])
})

test("the `this TUI` list becomes a member's tool selection, and the kernel freezes exactly it", async () => {
  // A data extension contributes no tools, so the real end-to-end proof needs a
  // real declaration. `ext build` freezes the manifest; the selection then names
  // a tool the frozen version declares, which is what `session new` checks.
  const home = join(ws.dir, ".nulya", "extensions", "notes")
  mkdirSync(join(home, "src"), { recursive: true })
  writeFileSync(
    join(home, "extension.json"),
    JSON.stringify({
      schema: "nulya.extension/v2",
      id: "notes",
      runtime: { entry: "src/main.sh", interpreter: "sh" },
      contributes: {
        // `surface: "manual"` out loud: the kernel's default is `auto` now, and
        // only a `manual` tool needs a selection to reach the model.
        tools: [
          { name: "append", description: "add a line", surface: "manual", input: { type: "object", properties: {} } },
          { name: "read", description: "read it back", surface: "manual", input: { type: "object", properties: {} } },
        ],
      },
    }),
  )
  writeFileSync(join(home, "src", "main.sh"), "#!/bin/sh\ncat >/dev/null\n")

  const built = Bun.spawnSync({ cmd: [ws.bin, "ext", "sync", "--activate"], cwd: ws.dir, env: process.env })
  expect(new TextDecoder().decode(built.stdout)).toContain("notes")

  const id = await sessionNew(ws, { profile: "scripted", with: ["notes:append"] })
  const header = await readHeader(ws, id)
  expect(header!.composition.native_tools).toContain("ext:notes/append")
  // The one NOT selected is the control: membership is not a tool face (D4).
  expect(header!.composition.native_tools).not.toContain("ext:notes/read")

  // And a selection the store cannot resolve is the kernel's refusal, verbatim
  // — never something the panel predicts.
  await expect(sessionNew(ws, { profile: "scripted", with: ["notes:nosuch"] })).rejects.toThrow(/session new/)
})

function entry(id: string, current: string, tools: string[]): ExtensionEntry {
  return {
    id,
    current,
    versions: [{ version: current, mtime: 0 }],
    kind: "script",
    tools,
    manualTools: tools,
    autoTools: [],
    internalTools: [],
    skills: [],
    systemPrompts: [],
    commands: [],
    ui: null,
    layer: "user",
  }
}

test("an auto-surface tool its package brings into every session reads as on, and this panel will not toggle it", () => {
  // A composed package contributes `surface:\"auto\"` tools to every session
  // this front end starts. No selection names them, so the panel must not draw
  // an empty checkbox about a tool the model can call.
  const sources = { user: [], session: ["ext:std/read"], merged: [], composed: ["ext:agent/agent"] }
  expect(faceState("ext:agent/agent", sources)).toBe("composed")
  expect(stateLabel(faceState("ext:agent/agent", sources))).toBe("with the package")
  // …and it counts on the face, once, beside the lists.
  expect(nextFace(sources)).toEqual(["ext:std/read", "ext:agent/agent"])

  // Neither key writes anything: the decision is in `tui.toml`, and a checkbox
  // that appears to turn it off would be a lie the next session corrects.
  const off = toggle("ext:agent/agent", sources)
  expect(off.user).toBeNull()
  expect(off.session).toBeNull()
  expect(off.notice).toContain("composed package membership")
  expect(promote("ext:agent/agent", sources).session).toBeNull()
})

/**
 * What a standing member list may legally select, and therefore what a stale one
 * gets repaired against (`App.healOrphanSelections`, `ExtView.dropOrphanTools`).
 *
 * One condition, the kernel's: no `current` means nothing for the member to
 * resolve, and no session.
 */
test("a package with a resolvable current offers only its surface-manual tools", () => {
  const entry = (
    id: string,
    manualTools: string[],
    over: Partial<{ current: string | null; shadowed: boolean }> = {},
  ) => ({ id, manualTools, current: "v-1", shadowed: false, ...over })

  const available = resolvableSelections([
    entry("std", ["read", "edit"]),
    // `run` is internal, `propose`/`todo` are auto: neither needs selecting, so
    // neither may appear on a standing list.
    entry("agent", ["agent"]),
    entry("plan", []),
    // Nothing points at a version, and an earlier root already answers for this
    // id: neither can resolve either.
    entry("guide", ["guide"], { current: null }),
    entry("compact", [], { shadowed: true }),
  ])
  expect(available).toEqual([
    "ext:std/read",
    "ext:std/edit",
    "ext:agent/agent",
  ])

  // Lines for auto-surface or inactive tools would make every `session new`
  // refuse, found by the same predicate that repairs them.
  expect(orphanTools(["ext:std/read", "ext:guide/guide", "ext:ask/ask", "ext:plan/propose"], available)).toEqual([
    "ext:guide/guide",
    "ext:ask/ask",
    "ext:plan/propose",
  ])
})
