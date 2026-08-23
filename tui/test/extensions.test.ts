/**
 * Installing what is on disk (tui.md §11, T11): the parse of `ext sync`, the
 * decision about a project store, and the three keys the question offers.
 *
 * The parse runs against the REAL binary — a store root with drafts in it, and
 * a real sync — so a change to the kernel's line shapes fails here rather than
 * showing a blank column. The decision itself is pure and is exercised on its
 * own: whether to ask is a policy, and policy should be readable without a
 * filesystem.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import {
  extList,
  extSeed,
  extSetCurrent,
  extSync,
  parseSyncLine,
  parseSyncReport,
  sessionNew,
  type SyncReport,
} from "../src/nulya/cli.ts"
import {
  actionFor,
  adoptBundled,
  answerFor,
  builtContributions,
  describeDrafts,
  draftColumn,
  failedIds,
  needsZigIds,
  pinsOf,
  standingWith,
  planProjectStore,
  promptConsequence,
  promptText,
  std_pins,
  stdEditPinDecision,
  summarize,
  syncRoot,
} from "../src/extensions.ts"
import { modelTools, readHeader } from "../src/nulya/files.ts"
import { default_settings, loadSettings, withPackage } from "../src/state/settings.ts"
import { draftHelp } from "../src/ui/overlays/ExtView.tsx"
import { tempWorkspace, type TempWorkspace } from "./support.ts"

let ws: TempWorkspace

/** A data (skills-only) draft: no compiler anywhere in this file. */
function writeDraft(dir: string, id: string, body: string) {
  const skill = join(dir, ".nulya", "extensions", id, "skills", "demo")
  mkdirSync(skill, { recursive: true })
  writeFileSync(
    join(dir, ".nulya", "extensions", id, "extension.json"),
    JSON.stringify({ schema: "nulya.extension/v2", id, contributes: { skills: ["skills/demo"] } }),
  )
  writeFileSync(join(skill, "SKILL.md"), `---\nname: demo\ndescription: ${body}\n---\n${body}\n`)
}

beforeAll(() => {
  ws = tempWorkspace()
  writeDraft(ws.dir, "one.mode", "the first")
  writeDraft(ws.dir, "two.mode", "the second")
  mkdirSync(join(ws.dir, ".nulya", "extensions", "broken"), { recursive: true })
  writeFileSync(join(ws.dir, ".nulya", "extensions", "broken", "extension.json"), "{not json")
})

afterAll(() => {
  ws.cleanup()
})

test("a plan says what each draft would become and writes nothing; the pass then says what it did", async () => {
  const plan = await extSync(ws, { dryRun: true })
  expect(plan.lines.map((line) => line.id).sort()).toEqual(["broken", "one.mode", "two.mode"])
  const one = plan.lines.find((line) => line.id === "one.mode")!
  expect(one.state).toBe("not built")
  expect(one.version).toMatch(/^v-[0-9a-f]+$/)
  expect(plan.lines.find((line) => line.id === "broken")!.state).toBe("failed")
  expect(plan.built).toBe(2)
  expect(plan.failed).toBe(1)
  // A plan is a plan: `/ext` opens on it, and nothing appears in the store.
  expect(draftColumn(one)).toBe("not built")

  const done = await extSync(ws)
  expect(done.built).toBe(2)
  expect(done.failed).toBe(1)
  for (const id of ["one.mode", "two.mode"]) {
    expect(done.lines.find((line) => line.id === id)!.state).toBe("built")
  }
  // Idempotent, and nothing was activated: building is mechanical, pointing
  // `current` is a decision.
  const again = await extSync(ws)
  expect(again.already).toBe(2)
  expect(again.lines.find((line) => line.id === "one.mode")!.activation).toBeNull()
})

test("--activate reports the three answers a pointer can have: moved, already there, left alone", async () => {
  const activated = await extSync(ws, { activate: true })
  const one = activated.lines.find((line) => line.id === "one.mode")!
  expect(one.activation).toBe("activated")
  expect(draftColumn(one)).toBe("built")

  // Already the current one: a second pass has nothing to move.
  const settled = await extSync(ws, { activate: true })
  expect(settled.lines.find((line) => line.id === "one.mode")!.activation).toBe("active")
  expect(draftColumn(settled.lines.find((line) => line.id === "one.mode")!)).toBe("active")

  // Somebody edits the draft and points `current` back at the older version:
  // the sync must not undo that decision.
  const old = one.version!
  writeDraft(ws.dir, "one.mode", "edited since")
  const rebuilt = await extSync(ws, { activate: true })
  const fresh = rebuilt.lines.find((line) => line.id === "one.mode")!
  expect(fresh.version).not.toBe(old)
  expect(fresh.activation).toBe("activated")

  await Bun.spawn({ cmd: [ws.bin, "ext", "activate", "one.mode", old], cwd: ws.dir, env: process.env }).exited
  const kept = await extSync(ws, { activate: true })
  const held = kept.lines.find((line) => line.id === "one.mode")!
  expect(held.activation).toBe("kept")
  expect(held.detail).toBe(old)
})

test("the line parse reads every shape the kernel prints, and ignores what is not a draft line", () => {
  expect(parseSyncLine("guide: v-abc123 built")).toMatchObject({ state: "built", activation: null })
  expect(parseSyncLine("compact: v-abc123 built (copied from /home/x/.nulya/extensions) -> current")).toMatchObject({
    state: "built",
    copiedFrom: "/home/x/.nulya/extensions",
    activation: "activated",
  })
  expect(parseSyncLine("m: v-a1 already built (current stays v-b2)")).toMatchObject({
    state: "already built",
    activation: "kept",
    detail: "v-b2",
  })
  expect(parseSyncLine("m: v-a1 not built (available from .nulya/extensions)")).toMatchObject({
    state: "not built",
    copiedFrom: ".nulya/extensions",
  })
  expect(parseSyncLine("demo: needs zig (compiled draft; set NULYA_ZIG or use the embedded toolchain)")?.state).toBe(
    "needs zig",
  )
  expect(parseSyncLine("bad: failed: InvalidJson")).toMatchObject({ state: "failed", detail: "InvalidJson" })
  // Not draft lines: the summary, the empty-root sentence, a note.
  expect(parseSyncLine("2 built, 1 already built, 1 failed")).toBeNull()
  expect(parseSyncLine("no drafts in .nulya/extensions")).toBeNull()
  expect(parseSyncReport("x: v-a1 built\n1 built, 0 already built, 0 failed\n").lines).toHaveLength(1)
})

function report(lines: string[]): SyncReport {
  return parseSyncReport(lines.join("\n"))
}

function inventoryOf(lines: string[], holds: string[] = []) {
  return { drafts: report(lines), holds }
}

test("a project store is asked about once, and only when it holds something", () => {
  const store = "/repo/.nulya/extensions"
  const drafts = inventoryOf(["a.mode: v-a1 not built", "b.mode: v-b1 already built"])

  // Nothing there: no question, nothing to install.
  expect(planProjectStore(store, inventoryOf([]), false, []).kind).toBe("none")
  // Trusted already: build it, no question.
  expect(planProjectStore(store, drafts, true, []).kind).toBe("ready")
  // Untrusted: ask — once. Declining is remembered, not repeated.
  const ask = planProjectStore(store, drafts, false, [])
  expect(ask.kind).toBe("ask")
  expect(planProjectStore(store, drafts, false, [store]).kind).toBe("none")

  if (ask.kind !== "ask") throw new Error("unreachable")
  const text = promptText(ask)
  expect(text).toContain(store)
  expect(text).toContain("a.mode")
  // The three keys are one per line, like the packages above them, and the
  // text ends on the answer line itself: the key is typed after the `›`.
  expect(text).toContain("\n  t  trust + build + activate\n  s  build only\n  n  not now\n› ")
  expect(text.endsWith("› ")).toBe(true)
  expect(describeDrafts(drafts)[0]).toContain("not built")
})

test("a checkout that ships BUILT versions and no source is the case the question exists for", () => {
  const store = "/repo/.nulya/extensions"
  const shipped = inventoryOf([], ["compact", "handoff"])
  const ask = planProjectStore(store, shipped, false, [])
  expect(ask.kind).toBe("ask")
  if (ask.kind !== "ask") throw new Error("unreachable")
  // Named, because a person deciding whether to trust a store has to see what
  // is in it — and these have no draft line to appear on.
  expect(ask.drafts.join(" ")).toContain("compact")
  expect(ask.drafts.join(" ")).toContain("already built here")
  // Trusted, it is simply usable; nothing needs building.
  expect(planProjectStore(store, shipped, true, []).kind).toBe("ready")
})

test("the three keys map to what actually runs, and anything else installs nothing", () => {
  expect(actionFor(answerFor("t")!)).toEqual({ trust: true, sync: true, activate: true })
  expect(actionFor(answerFor("s")!)).toEqual({ trust: false, sync: true, activate: false })
  expect(actionFor(answerFor("n")!)).toEqual({ trust: false, sync: false, activate: false })
  // Esc and Enter are "not now": a person who did not choose has not consented.
  expect(answerFor("escape")).toBe("skip")
  expect(answerFor("return")).toBe("skip")
  // Anything else is not an answer at all — the question stays open. A stray
  // byte (a terminal reply, an escape SEQUENCE, an IME chunk) must not be read
  // as a quiet "no" that is then remembered as asked-and-declined.
  expect(answerFor("q")).toBeNull()
  expect(answerFor("sequence")).toBeNull()
  expect(answerFor("\0")).toBeNull()
})

test("a finished pass leaves one line worth reading, and names what it could not build", () => {
  expect(summarize("user store", report(["3 built, 1 already built, 0 failed"]))).toBe("user store: 3 built · 1 already")
  // No line to read it off, so the kernel's total stands as failures — the safe
  // direction (see `parseSyncReport`).
  expect(summarize("this checkout", report(["0 built, 0 already built, 2 failed"]))).toBe("this checkout: 0 built · 2 failed")

  // A count is not news anybody can act on. `std: needs zig` scrolling past as
  // "3 failed" is how it stayed invisible (tui.md §11, T22).
  const failed = report([
    "std: needs zig (compiled draft; set NULYA_ZIG or use the embedded toolchain)",
    "guide: v-abc123456789 already built",
    "broken: failed: ManifestUnreadable",
    "1 built, 1 already built, 2 failed",
  ])
  expect(failedIds(failed)).toEqual(["broken"])
  expect(needsZigIds(failed)).toEqual(["std"])
  expect(failedIds(report(["1 built, 0 already built, 0 failed"]))).toEqual([])
  expect(needsZigIds(report(["1 built, 0 already built, 0 failed"]))).toEqual([])
})

/**
 * The kernel adds "needs zig" into its failure total (`cli/ext.zig`), and for
 * one line on a status bar that is a lie by merge: a machine with no toolchain
 * and a draft that does not compile want opposite things done about them. Read
 * as one number, the first looks like the second — which sent a reader to check
 * a zig install that was working perfectly.
 */
test("a pass tells a broken draft apart from a machine that cannot compile one", () => {
  const both = report([
    "std: needs zig (compiled draft; put zig on PATH)",
    "ask: needs zig (compiled draft; put zig on PATH)",
    "broken: failed: ManifestUnreadable",
    "0 built, 0 already built, 3 failed",
  ])
  expect(summarize("user store", both)).toBe("user store: 0 built · 1 failed · 2 need zig")

  // Only a toolchain missing: nothing here is broken, and the line must not say
  // "failed" at all.
  const toolchain = report([
    "std: needs zig (compiled draft; put zig on PATH)",
    "ask: needs zig (compiled draft; put zig on PATH)",
    "0 built, 0 already built, 2 failed",
  ])
  expect(summarize("user store", toolchain)).toBe("user store: 0 built · 2 need zig")

  // Only broken drafts: unchanged from before the split.
  const broken = report(["broken: failed: ManifestUnreadable", "0 built, 0 already built, 1 failed"])
  expect(summarize("user store", broken)).toBe("user store: 0 built · 1 failed")

  // The count can never go negative, however the two disagree.
  const odd = report(["std: needs zig (compiled draft; put zig on PATH)", "0 built, 0 already built, 0 failed"])
  expect(summarize("user store", odd)).toBe("user store: 0 built · 1 need zig")
})

test("a draft with no version says what stopped it, in the kernel's own words", () => {
  expect(draftHelp(null)).toEqual([])
  expect(draftHelp(parseSyncLine("guide: v-abc123456789 already built"))).toEqual([])

  // The shape the kernel prints today: the repair, with the absolute directory
  // a toolchain can be unpacked into, is IN that sentence — so it is relayed
  // whole and nothing here rewrites it.
  const shim = draftHelp(
    parseSyncLine(
      "std: needs zig (compiled draft; the zig at C:\\Users\\me\\bin\\zig.exe could not report its version from the store root — set NULYA_ZIG to a zig 0.16.0 executable, or unpack zig 0.16.0 into C:\\Users\\me\\AppData\\Local\\nulya\\toolchains\\zig\\0.16.0 (a nulya built with -Dembed-toolchain needs neither))",
    ),
  )
  expect(shim.length).toBe(2)
  expect(shim[0]).toContain("could not report its version from the store root")
  expect(shim[0]).toContain("toolchains\\zig\\0.16.0")
  // The one thing the kernel cannot know from where it stands.
  expect(shim[1]).toContain("build.zig.zon")

  const none = draftHelp(
    parseSyncLine("std: needs zig (compiled draft; put zig on PATH, set NULYA_ZIG to a zig 0.16.0 executable, or unpack zig 0.16.0 into /home/me/.local/share/nulya/toolchains/zig/0.16.0 (a nulya built with -Dembed-toolchain needs neither))"),
  )
  expect(none[0]).toContain("put zig on PATH")
  // An older binary's shorter sentence still parses and is still relayed.
  expect(draftHelp(parseSyncLine("std: needs zig (compiled draft; set NULYA_ZIG or use the embedded toolchain)"))[0]).toContain(
    "set NULYA_ZIG",
  )

  expect(draftHelp(parseSyncLine("broken: failed: ManifestUnreadable"))[0]).toContain("ManifestUnreadable")
  expect(draftHelp(parseSyncLine("new: v-abc123456789 not built"))[0]).toContain("never been built")
})

test("the binary's bundled drafts seed into a store — dry-run counts them, a second pass leaves them alone", async () => {
  const ws = tempWorkspace()
  const home = join(ws.dir, "home")
  const env = { NULYA_HOME: home }
  try {
    const plan = await extSeed(ws, { user: true, dryRun: true, env })
    expect(plan.seeded).toBe(8)
    expect(plan.already).toBe(0)
    expect(plan.ids).toEqual(["agent", "ask", "compact", "evolution", "guide", "handoff", "plan", "std"])

    const first = await extSeed(ws, { user: true, ids: ["guide"], env })
    expect(first.seeded).toBe(1)
    const again = await extSeed(ws, { user: true, ids: ["guide"], env })
    expect(again.seeded).toBe(0)
    expect(again.already).toBe(1)
    expect(again.updated).toEqual([])
    expect(again.mine).toEqual([])

    // An edited draft is somebody's: seeding names it and leaves it, and only
    // `--force` puts the binary's own source back (T42).
    const manifest = join(home, "extensions", "guide", "extension.json")
    const shipped = readFileSync(manifest, "utf8")
    writeFileSync(manifest, `${shipped}\n`)
    const edited = await extSeed(ws, { user: true, ids: ["guide"], env })
    expect(edited.mine).toEqual(["guide"])
    expect(readFileSync(manifest, "utf8")).toBe(`${shipped}\n`)

    const forced = await extSeed(ws, { user: true, ids: ["guide"], force: true, env })
    expect(forced.updated).toEqual(["guide"])
    expect(readFileSync(manifest, "utf8")).toBe(shipped)
  } finally {
    ws.cleanup()
  }
})

/**
 * The bundled install is nobody's question any more (tui.md §11, T23), so the
 * whole of the consent lives in one rule: only what `ext seed` says arrived THIS
 * run is turned on. The first two cases are that rule with no binary in sight —
 * each returns before it would spawn anything.
 */
test("only the bundled ids that arrived this run are activated", async () => {
  const built = report([
    "std: v-aaaaaaaa built",
    "guide: v-bbbbbbbb built",
    "evolution: v-cccccccc built",
    "3 built, 0 already built, 0 failed",
  ])

  // Nothing arrived: a later start finds all five drafts already in the store
  // and must leave every pointer alone — including the one somebody turned off
  // in `/ext` yesterday.
  expect(await adoptBundled(ws, [], built, join(ws.dir, "adopt-none.json"))).toEqual([])

  // Arrived, but this machine could not build it: there is no version to point
  // at, and `needs zig` is `/ext`'s news to deliver, not an activation's.
  const stuck = report(["std: needs zig (compiled draft; put zig on PATH)", "0 built, 0 already built, 1 failed"])
  expect(await adoptBundled(ws, ["std"], stuck, join(ws.dir, "adopt-stuck.json"))).toEqual([])
})

/**
 * A MODE that arrives is switched on like anything else (K8).
 *
 * It used to be the one exception: activating a package that contributed a
 * system prompt composed it, so every session on the machine started paying for
 * that prompt, and a background pass had no business deciding it. Activating
 * composes nothing now (DESIGN §5.1) — `[extensions] with` and `/ext`'s Enter
 * are what would — so the exception has nothing left to protect.
 *
 * Against a real store, because the claim is that the pointer MOVES: a
 * fabricated version id would fail to activate and return the same empty list
 * the old rule did, which is exactly the difference being asserted.
 */
test("a bundled mode that arrives is activated too, and the pointer really moves", async () => {
  const store = tempWorkspace()
  try {
    const root = syncRoot(store, false)
    writeDraft(store.dir, "mode.pkg", "a mode")
    writeFileSync(
      join(root, "mode.pkg", "extension.json"),
      JSON.stringify({
        schema: "nulya.extension/v2",
        id: "mode.pkg",
        contributes: { system_prompts: ["prompts/identity.md"] },
      }),
    )
    mkdirSync(join(root, "mode.pkg", "prompts"), { recursive: true })
    writeFileSync(join(root, "mode.pkg", "prompts", "identity.md"), "you are a mode\n")
    // A data package: no toolchain, so this runs on any machine.
    const report = await extSync(store)
    const line = report.lines.find((entry) => entry.id === "mode.pkg")!
    expect(line.version).toMatch(/^v-/)
    expect((await extList(store)).find((entry) => entry.id === "mode.pkg")!.current).toBeNull()

    // `adoptBundled` targets the USER store, so it is not the caller here — the
    // rule it now follows is: point `current` at what arrived, whatever the
    // package contributes.
    await extSetCurrent(store, "activate", "mode.pkg", line.version!)
    expect((await extList(store)).find((entry) => entry.id === "mode.pkg")!.current).toBe(line.version)

    // And that changed no composition: a session opened here has no member.
    const id = await sessionNew(store, { profile: "scripted" })
    expect((await readHeader(store, id))!.composition.active).toEqual([])
  } finally {
    store.cleanup()
  }
})

/**
 * Which half of `/ext`'s switch a package needs (K8).
 *
 * Activating alone composes nothing (DESIGN §5.1), so the switch has to write a
 * standing MEMBERSHIP entry for anything only a member can give — and must not
 * for a pure tool package, whose pins bring it in by themselves. Two ways of
 * saying one thing would be two things to take back.
 */
test("only a package with something a member alone can give gets a standing with entry", () => {
  const what = (over: Partial<Parameters<typeof standingWith>[0]> = {}) => ({
    skills: [] as string[],
    systemPrompts: [] as string[],
    commands: [],
    ui: null,
    ...over,
  })

  // A mode: its prompt reaches a session only through membership.
  expect(standingWith(what({ systemPrompts: ["prompts/identity.md"] }))).toBe(true)
  // A skill lands in the catalog the same way, and so do a slash command and a
  // front-end module — none of them has a pin to arrive by.
  expect(standingWith(what({ skills: ["skills/guide"] }))).toBe(true)
  expect(standingWith(what({ commands: [{ name: "plan", description: "", action: "with" }] }))).toBe(true)
  expect(standingWith(what({ ui: { entry: "tui/plan.ts", api: 1 } }))).toBe(true)

  // A pure tool package: `compact`, `handoff`, `ask`. Nothing here needs an
  // entry, because a pin brings the package in at `current` all by itself.
  expect(standingWith(what())).toBe(false)
})

test("what a mode's switch says, in both directions", () => {
  const on = promptConsequence("evolution", true)
  expect(on).toContain("EVERY new session")
  expect(on).toContain("/with evolution")
  expect(on).toContain("Enter again to turn it off")
  // A mode nobody wrote a command for still gets the per-session way in.
  expect(promptConsequence("house.style", true)).toContain("/with house.style")
  expect(promptConsequence("evolution", false)).toContain("no longer enters new sessions")
})

test("what a built version contributes is read from the root that sync wrote it to, and null when absent", async () => {
  const store = tempWorkspace()
  try {
    const root = syncRoot(store, false)
    expect(root).toBe(join(store.dir, ".nulya", "extensions"))
    // Nothing built: the honest answer is "don't know", and every reader of
    // this has to keep it distinguishable from "contributes nothing".
    expect(await builtContributions(store, root, "ghost", "v-nope")).toBeNull()

    writeDraft(store.dir, "mode.pkg", "a mode")
    const manifest = join(root, "mode.pkg", "extension.json")
    writeFileSync(
      manifest,
      JSON.stringify({
        schema: "nulya.extension/v2",
        id: "mode.pkg",
        contributes: { system_prompts: ["prompts/identity.md"] },
      }),
    )
    mkdirSync(join(root, "mode.pkg", "prompts"), { recursive: true })
    writeFileSync(join(root, "mode.pkg", "prompts", "identity.md"), "you are a mode\n")
    const built = await extSync(store)
    const line = built.lines.find((entry) => entry.id === "mode.pkg")!
    expect(line.version).toMatch(/^v-/)

    const what = await builtContributions(store, root, "mode.pkg", line.version!)
    expect(what?.systemPrompts).toEqual(["prompts/identity.md"])
    // A prompt is something only a member gets, so `/ext`'s switch has to write
    // the standing membership entry as well as move the pointer (K8).
    expect(standingWith(what!)).toBe(true)
  } finally {
    store.cleanup()
  }
})

test("the edit pin migration adopts only once the active std can honour it, and never twice", () => {
  const five = std_pins.filter((pin) => pin !== "ext:std/edit")
  const six_tools = ["read", "write", "append", "edit", "grep", "glob"]
  // The case it exists for: a list written when `edit` was a builtin, on a
  // machine whose std has since been rebuilt with it.
  expect(stdEditPinDecision(five, six_tools)).toBe("adopt")
  // Same list, but the std that is active here is the old build: a pin the
  // kernel cannot resolve would refuse every `session new`, so wait.
  expect(stdEditPinDecision(five, ["read", "write", "append", "grep", "glob"])).toBe("wait")
  expect(stdEditPinDecision(five, null)).toBe("wait")
  // Nothing to migrate: no std pins at all, or `edit` already there — and the
  // answer does not depend on the store, so a fresh machine never lists it.
  expect(stdEditPinDecision([], null)).toBe("done")
  expect(stdEditPinDecision(["ext:std/read"], null)).toBe("done")
  expect(stdEditPinDecision(std_pins, six_tools)).toBe("done")
  expect(stdEditPinDecision(std_pins, null)).toBe("done")
})

/**
 * The four hard-coded lists this file used to hold are gone (tui.md §11, T34):
 * which of a package's tools belong on the model's face is the package's own
 * word (`audience`, DESIGN §7.2.1), read out of the frozen manifest.
 */
test("the pins an activation writes come from the manifest, per tool, for a package nobody here has heard of", () => {
  const pkg = (id: string, tools: string[], driverTools: string[] = []) => ({ id, tools, driverTools })

  // Silence is read as `model`, which is what every manifest written before the
  // field existed means — and the kernel deliberately does not write the
  // default in for a package that said nothing.
  expect(pinsOf(pkg("std", ["read", "edit"]))).toEqual(["ext:std/read", "ext:std/edit"])
  expect(modelTools(pkg("std", ["read", "edit"]))).toEqual(["read", "edit"])

  // One package, both answers: the delegation entry point is the model's, the
  // three commands a driver runs are not. A per-PACKAGE list could not say this.
  expect(pinsOf(pkg("agent", ["agent", "list", "render", "run"], ["list", "render", "run"]))).toEqual([
    "ext:agent/agent",
  ])

  // All driver: the switch is membership alone, and that is not half-anything —
  // `nulya ext run` reaches the tool without a pin.
  expect(pinsOf(pkg("compact", ["compact"], ["compact"]))).toEqual([])

  // And a package this repository never heard of gets the same answer, which is
  // the whole point of asking the manifest instead of a list of bundled ids.
  expect(pinsOf(pkg("acme.patrol", ["watch", "sweep"], ["sweep"]))).toEqual(["ext:acme.patrol/watch"])
})

/**
 * The rule that used to live beside `pinsOf` (`standingPinsOf`) is gone with
 * the declaration it read (K8).
 *
 * Its history is worth keeping: `/ext`'s switch wrote `pinsOf` for `plan` and
 * `ask`, both of which had declared themselves opt-in, and the three lines it
 * left in `tui-state.json` made EVERY later `session new` exit 1 with
 * `PinNamesUnknownExtension` — a front end that could not open a session at
 * all. A pin brings its package in now (ext-review lane B), so such a line
 * composes the package rather than refusing, and composing is what a standing
 * pin is FOR. There is one answer to "which tools does the switch pin", and
 * `pinsOf` is it.
 */
test("the switch pins every model-facing tool a package declares, whatever kind of package it is", () => {
  const pkg = (id: string, tools: string[]) => ({ id, tools, driverTools: [] })

  expect(pinsOf(pkg("std", ["read", "edit"]))).toEqual(["ext:std/read", "ext:std/edit"])
  // A mode is no exception. Its tools reach a face in every session the pin
  // brings the package into — which is what the person asked for by pressing
  // Enter on its row, and what `/ext` takes back by pressing it again.
  expect(pinsOf(pkg("plan", ["propose", "todo"]))).toEqual(["ext:plan/propose", "ext:plan/todo"])
  expect(pinsOf(pkg("ask", ["ask"]))).toEqual(["ext:ask/ask"])
})

test("the std pin list is the frozen manifest's, with the literal only as a cold-start fallback", async () => {
  const store = tempWorkspace()
  try {
    const root = join(store.dir, ".nulya", "extensions")
    mkdirSync(join(root, "std", "src"), { recursive: true })
    writeFileSync(join(root, "std", "src", "run.sh"), "#!/bin/sh\necho '{}'\n")
    writeFileSync(
      join(root, "std", "extension.json"),
      JSON.stringify({
        schema: "nulya.extension/v2",
        id: "std",
        runtime: { entry: "src/run.sh", interpreter: "sh" },
        contributes: {
          tools: [
            { name: "read", input: {}, readonly: true },
            { name: "edit", input: {} },
            // A driver tool a future std might grow: it must not be pinned, and
            // no edit to this file is needed for that to hold.
            { name: "reindex", input: {}, audience: "driver" },
          ],
        },
      }),
    )
    const built = await extSync(store)
    const line = built.lines.find((entry) => entry.id === "std")!
    const what = (await builtContributions(store, root, "std", line.version!))!
    expect(what.driverTools).toEqual(["reindex"])
    expect(pinsOf(what)).toEqual(["ext:std/read", "ext:std/edit"])

    // The literal is still the answer when no manifest can be read at all — and
    // it is still what the one-time `edit` migration is about, which is a claim
    // about pin lists people wrote, not about what std declares today.
    expect(await builtContributions(store, root, "std", "v-nosuchversion")).toBeNull()
    expect(std_pins).toContain("ext:std/edit")
  } finally {
    store.cleanup()
  }
})

test("session_with replaces two per-package booleans, and still reads them", async () => {
  expect(default_settings.extensions.session_with).toEqual(["handoff", "agent"])

  const layer = tempWorkspace()
  try {
    mkdirSync(join(layer.dir, ".nulya"), { recursive: true })
    // The old key, off: that id leaves the list and nothing else moves.
    writeFileSync(join(layer.dir, ".nulya", "tui.toml"), "[extensions]\nhandoff = false\n")
    expect((await loadSettings(layer.dir, {})).extensions.session_with).toEqual(["agent"])

    // The old key, on, for a layer that had turned it off in the list: the
    // boolean is read after the list, so it is the nearer statement.
    writeFileSync(
      join(layer.dir, ".nulya", "tui.toml"),
      '[extensions]\nsession_with = ["handoff"]\nagent = true\n',
    )
    expect((await loadSettings(layer.dir, {})).extensions.session_with).toEqual(["handoff", "agent"])

    // The list alone, replacing rather than merging: a nearer layer must be able
    // to ask for FEWER packages, which a union could never express.
    writeFileSync(join(layer.dir, ".nulya", "tui.toml"), "[extensions]\nsession_with = []\n")
    expect((await loadSettings(layer.dir, {})).extensions.session_with).toEqual([])
  } finally {
    layer.cleanup()
  }
})

test("withPackage adds, removes, and never reorders what it leaves", () => {
  expect(withPackage(["handoff", "agent"], "handoff", false)).toEqual(["agent"])
  expect(withPackage(["handoff", "agent"], "handoff", true)).toEqual(["agent", "handoff"])
  expect(withPackage(["agent"], "handoff", false)).toEqual(["agent"])
})
