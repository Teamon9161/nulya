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
  faceFullLine,
  orphanPins,
  pinAll,
  pinState,
  promote,
  quotaLine,
  resolvableStandingPins,
  readUserPins,
  setPinnedTools,
  stateLabel,
  toggle,
  toolId,
  unpinAll,
  writeUserPins,
  type PinSources,
} from "../src/pins.ts"
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

test("the switch moves a whole package: on only adds, off clears both lists it owns", () => {
  const ids = [toolId("std", "read"), toolId("std", "grep")]

  // ON only ever adds. Turning an extension on must not take a pin off
  // something else, and a tool already on stays exactly where it was written.
  expect(pinAll(ids, sources()).session).toEqual(ids)
  const half = pinAll(ids, sources({ user: [ids[0]!] }))
  expect(half.session).toEqual([ids[1]!])
  expect(half.user).toBeNull()
  expect(pinAll(ids, sources({ session: ids })).session).toBeNull()

  // OFF clears BOTH lists this panel writes — including `always`, which no
  // other key here subtracts: a pin left behind by a deactivation does not cost
  // a tool, it makes `session new` refuse outright.
  const off = unpinAll(ids, sources({ user: [ids[0]!], session: [ids[1]!] }))
  expect(off.user).toEqual([])
  expect(off.session).toEqual([])

  // A pin some other layer wrote still cannot be touched, and is named.
  const theirs = unpinAll(ids, sources({ merged: ids }))
  expect(theirs.user).toBeNull()
  expect(theirs.session).toBeNull()
  expect(theirs.notice).toContain("another config layer")
})

test("the switch state is the two axes read together, and `partial` is what it is called", () => {
  // Both axes agree.
  expect(switchState(true, 2, 2)).toBe("on")
  expect(switchState(true, 0, 0)).toBe("on") // a data package: no tools to pin
  expect(switchState(false, 2, 0)).toBe("off")
  // Active, half its face pinned — the state the panel used to draw nowhere.
  expect(switchState(true, 5, 3)).toBe("partial")
  // Pinned but no longer active: the one that makes `session new` refuse.
  expect(switchState(false, 1, 1)).toBe("partial")

  // Which is why those pins are dropped rather than kept.
  expect(orphanPins(["ext:std/read", "ext:gone/x"], ["ext:std/read"])).toEqual(["ext:gone/x"])
  expect(orphanPins([], ["ext:std/read"])).toEqual([])
})

test("the quota counts the builtin, because max_tools does", () => {
  expect(builtin_tools).toBe(1)
  expect(quotaLine(8, 5)).toBe("tools 1+5/8")
  expect(quotaLine(8, 6)).toBe("tools 1+6/8")
  // Over the line the panel does not prevent anything; it says what will happen
  // — in a sentence, and with the way out in it. `2+9/8 · nothing changed` was
  // the whole explanation somebody got for a switch that would not switch
  // (tui.md §11, T23).
  expect(quotaLine(8, 8)).toContain("tools 1+8/8")
  expect(quotaLine(8, 8)).toContain("1 more than registry.max_tools allows")
  expect(quotaLine(8, 8)).toContain("unpin one in the tools pane")
  expect(quotaLine(8, 10)).toContain("3 more than registry.max_tools allows")
})

test("a full tool face refuses the pins, not the extension", () => {
  // What the switch says when it activated something and could not pin its
  // tools: how full, how many are off the face, and both ways to use them.
  const line = faceFullLine(8, 6, 1)
  expect(line).toContain("tool face is full at 1+6/8")
  expect(line).toContain("1 tool not pinned")
  expect(line).toContain("Space in the tools pane")
  expect(line).toContain("ext run")
  expect(faceFullLine(8, 6, 2)).toContain("2 tools not pinned")
})

test("rows come only from extensions a pin could actually resolve through", () => {
  const entries: ExtensionEntry[] = [
    entry("std", "v-1", ["read", "grep"]),
    // No `current`: `session new --pin` would fail — the pin brings its package in, and there is nothing to bring.
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

test("the list holds only rows with a checkbox, and says how many it folded", () => {
  // The audiences are the packages' own (`driverTools`, DESIGN §7.2.1) — which
  // is why `agent` splits: one model tool, three driver ones. Before T34 the
  // whole package was driver-only because its id was on a list here, and its
  // delegation entry point was folded away with the rest.
  const entries: ExtensionEntry[] = [
    { ...entry("agent", "v-1", ["agent", "list", "render", "run"]), driverTools: ["list", "render", "run"] },
    { ...entry("compact", "v-1", ["compact"]), driverTools: ["compact"] },
    entry("std", "v-1", ["read", "grep"]),
  ]
  const rows = toolRows(entries, sources({ user: [toolId("std", "read")] }), [])

  // Collapsed: the four driver tools are gone and every remaining row is a
  // switch somebody can throw. Expanded: the same list as before T33.
  expect(shownRows(rows, false).map((row) => row.id)).toEqual([
    toolId("agent", "agent"),
    toolId("std", "grep"),
    toolId("std", "read"),
  ])
  expect(shownRows(rows, true).map((row) => row.id)).toEqual(rows.map((row) => row.id))
  expect(foldedRows(rows)).toHaveLength(4)
  expect(foldLine(4, false)).toContain("4 driver tools")
  expect(foldLine(4, false)).toContain("ext run")
  expect(foldLine(4, false)).toContain("d shows")
  expect(foldLine(1, true)).toContain("1 driver tool ")
  expect(foldLine(1, true)).toContain("d folds")

  // A driver tool with a pin somehow down stays visible: it is the one row here
  // that IS a state, and taking it back is what this pane is for.
  const pinned = toolRows(entries, sources({ user: [toolId("compact", "compact")] }), [])
  expect(shownRows(pinned, false).map((row) => row.id)).toContain(toolId("compact", "compact"))
  expect(foldedRows(pinned)).toHaveLength(3)
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

  const built = Bun.spawnSync({ cmd: [ws.bin, "ext", "sync", "--activate"], cwd: ws.dir, env: process.env })
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
    driverTools: [],
    skills: [],
    systemPrompts: [],
    commands: [],
    ui: null,
    root: ".nulya/extensions",
    shadowed: false,
  }
}

test("a tool its package brings into every session reads as on, and this panel will not toggle it", () => {
  // `[extensions] session_with` puts `--pin ext:agent/agent` on every session
  // this front end starts (T42). No pin list names it, so the panel used to
  // draw an empty checkbox about a tool the model was calling all day.
  const sources = { user: [], session: ["ext:std/read"], merged: [], composed: ["ext:agent/agent"] }
  expect(pinState("ext:agent/agent", sources)).toBe("composed")
  expect(stateLabel(pinState("ext:agent/agent", sources))).toBe("with the package")
  // …and it counts on the face, once, beside the lists.
  expect(nextFace(sources)).toEqual(["ext:std/read", "ext:agent/agent"])

  // Neither key writes anything: the decision is in `tui.toml`, and a checkbox
  // that appears to turn it off would be a lie the next session corrects.
  const off = toggle("ext:agent/agent", sources)
  expect(off.user).toBeNull()
  expect(off.session).toBeNull()
  expect(off.notice).toContain("session_with")
  expect(promote("ext:agent/agent", sources).session).toBeNull()
})

/**
 * What a standing list may legally name, and therefore what a stale one gets
 * repaired against (`App.healStandingPins`, `ExtView.dropOrphanPins`).
 *
 * One condition, the kernel's: no `current` means nothing for the pin to bring
 * in, and no session. There used to be a second, this front end's own — a
 * standing pin on a package that declared itself opt-in would wear that mode in
 * every session — and it went with the declaration (K8): reach is stated by the
 * person now, in `[extensions] with` or in `/ext`, both of them visible.
 */
test("a package with a resolvable current offers every tool a standing pin can name", () => {
  const entry = (
    id: string,
    tools: string[],
    over: Partial<{ current: string | null; shadowed: boolean }> = {},
  ) => ({ id, tools, current: "v-1", shadowed: false, ...over })

  const available = resolvableStandingPins([
    entry("std", ["read", "edit"]),
    // Driver tools are in: `audience` is the package's advice about whose face
    // a tool belongs on, not a rule about what may be pinned.
    entry("agent", ["agent", "run"]),
    // A mode's tools are in too, now. Pinning one is a real decision a person
    // can make and take back — and the pin brings its package into every
    // session, which is the same thing `[extensions] with` would say.
    entry("plan", ["propose", "todo"]),
    // Nothing points at a version, and an earlier root already answers for this
    // id: neither can resolve either.
    entry("guide", ["guide"], { current: null }),
    entry("compact", ["compact"], { shadowed: true }),
  ])
  expect(available).toEqual([
    "ext:std/read",
    "ext:std/edit",
    "ext:agent/agent",
    "ext:agent/run",
    "ext:plan/propose",
    "ext:plan/todo",
  ])

  // The two lines that would make every `session new` refuse, found by the same
  // predicate that repairs them.
  expect(orphanPins(["ext:std/read", "ext:guide/guide", "ext:ask/ask"], available)).toEqual([
    "ext:guide/guide",
    "ext:ask/ask",
  ])
})
