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
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
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
  activateUnattended,
  adoptBundled,
  answerFor,
  builtContributions,
  checkoutFollowUp,
  wearCommand,
  describeDrafts,
  draftColumn,
  failedIds,
  needsZigIds,
  adoptInstalled,
  pinsOf,
  planCheckout,
  planProjectStore,
  promptText,
  std_pins,
  summarize,
  syncRoot,
  type CheckoutAction,
} from "../src/extensions.ts"
import { planProjectAgents } from "../src/agents.ts"
import { modelTools, readHeader, type PackageCommand } from "../src/nulya/files.ts"
import { rememberSessionPins } from "../src/state/tui_state.ts"
import { default_settings, loadSettings } from "../src/state/settings.ts"
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
  expect(draftColumn(one, null)).toBe("not built")

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
  // The column follows `current` from the listing, not the plan's own word for
  // what this pass did: "moved it here" and "was already here" are the same
  // answer to "is this build the one that runs".
  expect(draftColumn(one, one.version!)).toBe("active")
  // No pointer at all and a pointer somewhere else are two states, not one:
  // the first is a package that is off, the second is one that runs at another
  // build. `Enter` fixes the first, `a` on a version line the second.
  expect(draftColumn(one, null)).toBe("inactive")
  expect(draftColumn(one, "v-000000000000")).toBe("not current")
  // A package with no source in its store directory — built from a path
  // elsewhere, or copied in — still has a pointer, and the pointer is what this
  // column is for. Saying nothing left those rows as the only ones in `/ext`
  // with no state word at all.
  expect(draftColumn(null, one.version!)).toBe("active")
  expect(draftColumn(null, null)).toBe("inactive")

  // Already the current one: a second pass has nothing to move.
  const settled = await extSync(ws, { activate: true })
  expect(settled.lines.find((line) => line.id === "one.mode")!.activation).toBe("active")
  const settledOne = settled.lines.find((line) => line.id === "one.mode")!
  expect(draftColumn(settledOne, settledOne.version!)).toBe("active")
  expect(draftColumn(settledOne, "v-000000000000")).toBe("not current")

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
  // A built source whose version is not the pointer: not a fault, and its
  // repair is the one key neither `b` nor Enter covers.
  const behind = draftHelp(parseSyncLine("guide: v-abc123456789 already built"), "v-000000000000")[0]!
  expect(behind).toContain("not the one in use")
  expect(behind).toContain("`a`")
  // The same line while it IS the pointer says nothing at all.
  expect(draftHelp(parseSyncLine("guide: v-abc123456789 already built"), "v-abc123456789")).toEqual([])
})

test("the binary's bundled drafts seed into a store — dry-run counts them, a second pass leaves them alone", async () => {
  const ws = tempWorkspace()
  const home = join(ws.dir, "home")
  const env = { NULYA_HOME: home }
  try {
    const plan = await extSeed(ws, { user: true, dryRun: true, env })
    // Deliberately neither the count nor the roster: how many drafts this
    // binary ships is not what a plan is about, and pinning either here taxes
    // every package the repository adds. What an empty root has to say is that
    // every id it names is new, and that the id this test goes on to use is
    // among them.
    expect(plan.seeded).toBeGreaterThan(0)
    expect(plan.seeded).toBe(plan.ids.length)
    expect(plan.already).toBe(0)
    expect(plan.ids).toContain("guide")

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

test("bundled ask, handoff, and plan expose member-scoped tools without writing pins", async () => {
  const store = tempWorkspace()
  try {
    await extSeed(store, { ids: ["ask", "handoff", "plan"] })
    const built = await extSync(store, { activate: true })
    const root = syncRoot(store, false)
    const askLine = built.lines.find((entry) => entry.id === "ask")!
    const handoffLine = built.lines.find((entry) => entry.id === "handoff")!
    const planLine = built.lines.find((entry) => entry.id === "plan")!
    expect(askLine.state).not.toBe("failed")
    expect(handoffLine.state).not.toBe("failed")
    expect(planLine.state).not.toBe("failed")
    expect(askLine.version).toBeTruthy()
    expect(handoffLine.version).toBeTruthy()
    expect(planLine.version).toBeTruthy()

    const ask = (await builtContributions(store, root, "ask", askLine.version!))!
    const handoff = (await builtContributions(store, root, "handoff", handoffLine.version!))!
    const plan = (await builtContributions(store, root, "plan", planLine.version!))!
    expect(ask.autoTools).toEqual(["ask"])
    expect(handoff.autoTools).toEqual(["handoff"])
    expect(plan.autoTools).toEqual(["propose", "todo"])
    expect(plan.internalTools).toEqual(["approve"])
    expect(pinsOf(ask)).toEqual([])
    expect(pinsOf(handoff)).toEqual([])
    expect(pinsOf(plan)).toEqual([])
    // None of the three asks to be in every session, so the start-up pass may
    // point `current` at all of them without deciding anything for anybody —
    // including `plan`, which contributes a system prompt (T52).
    expect(ask.apply).toBe("manual")
    expect(handoff.apply).toBe("manual")
    expect(plan.apply).toBe("manual")
  } finally {
    store.cleanup()
  }
}, 120_000)

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
 * The guard that used to live here is gone, and what it was for is worth
 * keeping written down.
 *
 * `autoActivatable` / `safeToActivateUnattended` refused to let a background
 * pass activate an `apply: "auto"` package, because of T31: `evolution` was
 * activated on the way in and every model on the machine then believed it was
 * the slow loop. But the thing that made that possible was DISCOVERY —
 * activation implying membership — and discovery went away with `activation`
 * (ext-review-2 Lane K). `evolution` is `apply: "manual"` today and shaped like
 * `plan`: activating it composes it into nothing.
 *
 * So the guard ended up holding exactly one bundled package — `guide`, whose
 * whole contribution is a line in the skill catalog — while the shape it was
 * written against (`apply: "auto"` plus a system prompt) is what the field is
 * FOR, and only ever arrives because somebody installed it. What replaces it is
 * saying so: the pass names what now reaches every session.
 */
test("a first install is activated, pinned as the package asks, and named for what it now reaches", async () => {
  const store = tempWorkspace()
  try {
    const root = syncRoot(store, false)
    const dir = join(root, "kong")
    mkdirSync(join(dir, "skills", "demo"), { recursive: true })
    writeFileSync(
      join(dir, "extension.json"),
      JSON.stringify({
        schema: "nulya.extension/v2",
        id: "kong",
        apply: "auto",
        runtime: { entry: "src/run.sh", interpreter: "sh" },
        contributes: {
          skills: ["skills/demo"],
          tools: [
            { name: "core", input: {}, surface: "manual" },
            { name: "extra", input: {}, surface: "manual", recommended: false },
          ],
        },
      }),
    )
    mkdirSync(join(dir, "src"), { recursive: true })
    writeFileSync(join(dir, "src", "run.sh"), "#!/bin/sh\necho '{}'\n")
    writeFileSync(join(dir, "skills", "demo", "SKILL.md"), "---\nname: demo\ndescription: a standing mode\n---\nbody\n")

    const built = await extSync(store)
    const line = built.lines.find((entry) => entry.id === "kong")!
    const { outcome, built: what } = await activateUnattended(store, {
      id: "kong",
      version: line.version!,
      root,
      user: false,
    })
    // `apply: "auto"` is no longer a refusal: nothing got here without a person.
    expect(outcome).toBe("activated")
    expect((await extList(store)).find((entry) => entry.id === "kong")!.current).toBe(line.version)

    const statePath = join(store.dir, "adopt-state.json")
    const said = await adoptInstalled(store, [what!], statePath)
    // The recommended tool is pinned; the extra the package declined is not.
    const pins = JSON.parse(readFileSync(statePath, "utf8")).session_pins as string[]
    expect(pins).toEqual(["ext:kong/core"])
    // And the reach is SAID, which is what stands in for refusing.
    expect(said.join(" · ")).toContain("kong")
    expect(said.some((part) => part.includes("every session"))).toBe(true)
  } finally {
    store.cleanup()
  }
}, 120_000)

/**
 * The other half of the same rule: after the first install, the pin list is the
 * person's. A later pass may move `current` forward, and must not put back a
 * tool they took off — a switch that undoes itself is not a switch. So writing
 * pins is keyed on "this package had no `current`", never on "a pointer moved".
 */
test("a package that is merely rebuilt gets no pins written for it", async () => {
  const store = tempWorkspace()
  try {
    const statePath = join(store.dir, "rebuild-state.json")
    const root = syncRoot(store, false)
    const dir = join(root, "kit")
    mkdirSync(join(dir, "src"), { recursive: true })
    const manifest = (body: string) => ({
      schema: "nulya.extension/v2",
      id: "kit",
      runtime: { entry: "src/run.sh", interpreter: "sh" },
      contributes: { tools: [{ name: body, input: {}, surface: "manual" }] },
    })
    writeFileSync(join(dir, "src", "run.sh"), "#!/bin/sh\necho '{}'\n")
    writeFileSync(join(dir, "extension.json"), JSON.stringify(manifest("core")))
    const first = await extSync(store)
    const v1 = first.lines.find((entry) => entry.id === "kit")!.version!
    await extSetCurrent(store, "activate", "kit", v1)

    // Somebody takes the one tool off in `/ext`.
    rememberSessionPins([], statePath)

    writeFileSync(join(dir, "extension.json"), JSON.stringify(manifest("core2")))
    const second = await extSync(store)
    const v2 = second.lines.find((entry) => entry.id === "kit")!.version!
    expect(v2).not.toBe(v1)
    const { built: what } = await activateUnattended(store, { id: "kit", version: v2, root, user: false })
    // The caller is what decides this is not an install — `kit` already had a
    // `current` — so nothing is handed to `adoptInstalled` and nothing is written.
    expect(await adoptInstalled(store, [], statePath)).toEqual([])
    expect(JSON.parse(readFileSync(statePath, "utf8")).session_pins).toEqual([])
    expect(what?.recommendedTools).toEqual(["core2"])
  } finally {
    store.cleanup()
  }
}, 120_000)

/**
 * …and the same rule for a candidate whose own manifest cannot be read (T56).
 *
 * `builtContributions` returning null used to SKIP the guard: the caller asked
 * `if (built && !safe(built))`, so a version this front end could not read at
 * all was activated without anything having answered the reach question. The
 * pointer must stay where it is, against a real store because the claim is
 * about the pointer.
 */
test("a candidate whose manifest cannot be read is held, and current does not move", async () => {
  const store = tempWorkspace()
  try {
    const root = syncRoot(store, false)
    const dir = join(root, "house.rule")
    mkdirSync(join(dir, "skills", "demo"), { recursive: true })
    writeFileSync(
      join(dir, "extension.json"),
      JSON.stringify({ schema: "nulya.extension/v2", id: "house.rule", contributes: { skills: ["skills/demo"] } }),
    )
    writeFileSync(join(dir, "skills", "demo", "SKILL.md"), "---\nname: demo\ndescription: ordinary\n---\nbody\n")
    const built = await extSync(store)
    const version = built.lines.find((entry) => entry.id === "house.rule")!.version!
    await extSetCurrent(store, "activate", "house.rule", version)

    const held = await activateUnattended(store, {
      id: "house.rule",
      version: "v-nothingbuiltthis",
      root,
      user: false,
    })
    expect(held.built).toBeNull()
    expect(held.outcome).toBe("held")
    expect((await extList(store)).find((entry) => entry.id === "house.rule")!.current).toBe(version)
  } finally {
    store.cleanup()
  }
}, 120_000)

/**
 * The bundled path goes through the same door, and knows the same one thing
 * about each id: is this an INSTALL?
 *
 * `ext seed` calls an id "arrived" when its DRAFT was missing, and `<id>/current`
 * outlives a deleted draft perfectly well — so "arrived" says nothing about
 * whether anybody has already made a decision about this package. Both ids here
 * are arrived; only one of them is new. The one with a pointer already set gets
 * moved forward and nothing written on its behalf, because by then the pin list
 * belongs to whoever has been using it.
 */
test("an arrived id that is new is installed; an arrived id that already had a current only moves forward", async () => {
  const store = tempWorkspace()
  const home = mkdtempSync(join(tmpdir(), "nulya-tui-adopt-"))
  const previous = process.env["NULYA_HOME"]
  // `adoptBundled` targets the USER store, and both this test and the binary
  // it spawns resolve that from `NULYA_HOME`.
  process.env["NULYA_HOME"] = home
  try {
    const root = syncRoot(store, true)
    const draft = (id: string, apply: "auto" | "manual") => {
      mkdirSync(join(root, id, "skills", "demo"), { recursive: true })
      writeFileSync(
        join(root, id, "extension.json"),
        JSON.stringify({ schema: "nulya.extension/v2", id, apply, contributes: { skills: ["skills/demo"] } }),
      )
      writeFileSync(join(root, id, "skills", "demo", "SKILL.md"), `---\nname: demo\ndescription: ${id}\n---\nbody\n`)
    }

    draft("kong", "auto")
    const first = await extSync(store, { user: true })
    const standing = first.lines.find((entry) => entry.id === "kong")!.version!
    await extSetCurrent(store, "activate", "kong", standing, { user: true })

    // The new source `ext seed` would drop for the same id, turning `manual`.
    // Whether a draft was there a moment ago is what makes seed call this id
    // "arrived"; it says nothing about what the pointer is doing today.
    draft("kong", "manual")
    draft("house.rule", "manual")
    const report = await extSync(store, { user: true })
    const candidate = report.lines.find((entry) => entry.id === "kong")!.version!
    const ordinary = report.lines.find((entry) => entry.id === "house.rule")!.version!
    expect(candidate).not.toBe(standing)

    const parts = await adoptBundled(
      store,
      ["kong", "house.rule"],
      report,
      join(store.dir, "adopt-guard.json"),
      new Set(["kong"]),
    )
    expect(parts.some((part) => part.includes("house.rule active"))).toBe(true)
    // `house.rule` is the install, so it is the one named for its reach; `kong`
    // was already somebody's, so moving it forward is not news of that kind.
    expect(parts.some((part) => part.includes("kong") && part.includes("every session"))).toBe(false)
    const listed = await extList(store)
    // Both pointers followed their newest build — the pass no longer refuses.
    expect(listed.find((entry) => entry.id === "kong")!.current).toBe(candidate)
    expect(listed.find((entry) => entry.id === "house.rule")!.current).toBe(ordinary)
  } finally {
    if (previous === undefined) delete process.env["NULYA_HOME"]
    else process.env["NULYA_HOME"] = previous
    rmSync(home, { recursive: true, force: true })
    store.cleanup()
  }
}, 120_000)

/**
 * How a package is worn: only through a command it DECLARED. Nothing is
 * derived — `/<id>` used to be handed to every prompt package for free, which
 * had the front end inventing names the manifest never claimed.
 */
test("a slash command exists exactly when the manifest declares it; wearCommand finds the declared way in", () => {
  const what = (commands: PackageCommand[] = []) => ({ commands })

  // No declaration, no command — a prompt package included; `/with <id>` is
  // still there.
  expect(wearCommand(what())).toBeNull()
  // The declared `{with: true}` entry is the answer, whatever its name.
  const evolve = { name: "evolve", description: "", action: { with: true } }
  expect(wearCommand(what([evolve]))).toEqual(evolve)
  // A command with another verb is not a way to wear the package.
  expect(wearCommand(what([{ name: "review", description: "", action: { run: "propose" } }]))).toBeNull()
})

/**
 * `planCheckout` merges the workspace store question (DESIGN §9) and the
 * agent-definitions question (tui.md §5.10) into the one this screen actually
 * asks (T2, ext-review-2 §3b): nothing when neither needs a look, today's own
 * question unchanged when only one does, and a new three-answer question when
 * both do — never two prompts stacked on the same terminal.
 */
test("planCheckout: neither, one, or both — and one merged question replaces two stacked ones", () => {
  const store = "/repo/.nulya/extensions"
  const drafts = { drafts: report(["a.mode: v-a1 not built"]), holds: [] as string[] }
  const dir = "/repo/.nulya/agents"

  const storeReady = planProjectStore(store, drafts, true, [])
  const storeAsk = planProjectStore(store, drafts, false, [])
  const storeNone = planProjectStore(store, inventoryOf([]), false, [])
  const agentsReady = planProjectAgents(dir, ["explore.md"], true, [], (a, b) => a === b)
  const agentsAsk = planProjectAgents(dir, ["explore.md"], false, [], (a, b) => a === b)
  const agentsNone = planProjectAgents(dir, [], false, [], (a, b) => a === b)

  // Neither side has anything to ask: silence, whatever "ready" either one is.
  expect(planCheckout(storeNone, agentsNone).kind).toBe("none")
  expect(planCheckout(storeReady, agentsReady).kind).toBe("none")
  expect(planCheckout(storeReady, agentsNone).kind).toBe("none")

  // Only the store needs a look: today's question, byte for byte — same text
  // `promptText` would produce, same three keys, `apply` behaving exactly like
  // `answerFor`/`actionFor` and touching the agents side not at all.
  if (storeAsk.kind !== "ask") throw new Error("unreachable")
  const onlyStore = planCheckout(storeAsk, agentsReady)
  if (onlyStore.kind !== "ask") throw new Error("unreachable")
  expect(onlyStore.text).toBe(promptText(storeAsk))
  expect(onlyStore.choices.map(([key]) => key)).toEqual(["t", "s", "n"])
  expect(onlyStore.apply("t")).toEqual({ store: { trust: true, sync: true, activate: true }, agentsTrust: false })
  expect(onlyStore.apply("n")).toEqual({ store: { trust: false, sync: false, activate: false }, agentsTrust: false })
  expect(onlyStore.apply("q")).toBeNull()

  // Only the agents side needs a look: two keys, not three — there is nothing
  // to install here, and the store action is always a no-op.
  const onlyAgents = planCheckout(storeNone, agentsAsk)
  if (onlyAgents.kind !== "ask") throw new Error("unreachable")
  expect(onlyAgents.choices.map(([key]) => key)).toEqual(["t", "n"])
  expect(onlyAgents.text).toContain(dir)
  expect(onlyAgents.text).toContain("explore.md")
  expect(onlyAgents.apply("t")).toEqual({ store: { trust: false, sync: false, activate: false }, agentsTrust: true })
  expect(onlyAgents.apply("n")).toEqual({ store: { trust: false, sync: false, activate: false }, agentsTrust: false })
  expect(onlyAgents.apply("s")).toBeNull() // not one of this question's two keys

  // Both need a look: one paragraph naming both, three answers that now speak
  // for both sides at once.
  const both = planCheckout(storeAsk, agentsAsk)
  if (both.kind !== "ask") throw new Error("unreachable")
  expect(both.text).toContain(store)
  expect(both.text).toContain("a.mode")
  expect(both.text).toContain(dir)
  expect(both.text).toContain("explore.md")
  expect(both.choices.map(([key]) => key)).toEqual(["t", "s", "n"])
  // t: trust and install everything, on both sides.
  expect(both.apply("t")).toEqual({ store: { trust: true, sync: true, activate: true }, agentsTrust: true })
  // s: build the extensions only, and trust neither side.
  expect(both.apply("s")).toEqual({ store: { trust: false, sync: true, activate: false }, agentsTrust: false })
  // n: leave both alone.
  expect(both.apply("n")).toEqual({ store: { trust: false, sync: false, activate: false }, agentsTrust: false })
  expect(both.apply("q")).toBeNull()
})

/**
 * `checkoutFollowUp` is what used to be printed inline by the two separate
 * `askAbout*` functions — kept, byte for byte, but only for a side this run
 * actually asked about: a checkout whose agents question never appeared must
 * not be told its (nonexistent) agents question was declined.
 */
test("checkoutFollowUp: the two 'left alone' sentences, each only for a side that was actually asked", () => {
  const nothing: CheckoutAction = { store: { trust: false, sync: false, activate: false }, agentsTrust: false }
  const both: CheckoutAction = { store: { trust: true, sync: true, activate: true }, agentsTrust: true }

  // Store-only question, declined: its own sentence, and nothing about agents
  // (which this question never mentioned).
  expect(checkoutFollowUp(nothing, true, false)).toEqual(["left alone · `nulya ext trust` whenever you mean to"])
  // Agents-only question, declined.
  expect(checkoutFollowUp(nothing, false, true)).toEqual(["left alone · /agent still lists them, and starts none"])
  // The merged question, "n": both sentences, because both were actually asked.
  expect(checkoutFollowUp(nothing, true, true)).toEqual([
    "left alone · `nulya ext trust` whenever you mean to",
    "left alone · /agent still lists them, and starts none",
  ])
  // Everything trusted and installed: nothing left to say.
  expect(checkoutFollowUp(both, true, true)).toEqual([])
  // Neither side was even part of the question (the "none"/"ready" case never
  // reaches this function in `main.tsx`, but the function itself stays honest
  // about it): no side asked, no line, even though nothing happened.
  expect(checkoutFollowUp(nothing, false, false)).toEqual([])
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
    // A manifest that says nothing about `apply` means `manual`, exactly as the
    // kernel reads it — so contributing a prompt does not by itself keep this
    // package off the start-up pass (T52).
    expect(what!.apply).toBe("manual")
  } finally {
    store.cleanup()
  }
})

/**
 * The four hard-coded lists this file used to hold are gone (tui.md §11, T34):
 * which of a package's tools belong on the model's face is the package's own
 * word (`surface`, DESIGN §7.2.1), read out of the frozen manifest.
 */
test("the pins an activation writes come from the manifest, per tool, for a package nobody here has heard of", () => {
  const pkg = (id: string, manualTools: string[], internalTools: string[] = []) => ({
    id,
    tools: [...manualTools, ...internalTools],
    manualTools,
    // Every manual tool, which is what `recommended` defaults to.
    recommendedTools: manualTools,
    internalTools,
  })

  // The only tools a pin is the way in for: `surface: "manual"`.
  expect(pinsOf(pkg("std", ["read", "edit"]))).toEqual(["ext:std/read", "ext:std/edit"])
  expect(modelTools(pkg("std", ["read", "edit"]))).toEqual(["read", "edit"])

  // One package, both answers: the delegation entry point is pinned, the three
  // commands `ext run` calls are not. A per-PACKAGE list could not say this.
  expect(pinsOf(pkg("agent", ["agent"], ["list", "render", "run"]))).toEqual(["ext:agent/agent"])

  // All internal: the switch is membership alone, and that is not half-anything
  // — `nulya ext run` reaches the tool without a pin.
  expect(pinsOf(pkg("compact", [], ["compact"]))).toEqual([])

  // And a package this repository never heard of gets the same answer, which is
  // the whole point of asking the manifest instead of a list of bundled ids.
  expect(pinsOf(pkg("acme.patrol", ["watch"], ["sweep"]))).toEqual(["ext:acme.patrol/watch"])
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
test("the switch pins every pinnable tool a package declares, whatever kind of package it is", () => {
  const pkg = (id: string, tools: string[], manualTools = tools) => ({
    id,
    tools,
    manualTools,
    recommendedTools: manualTools,
  })

  expect(pinsOf(pkg("std", ["read", "edit"]))).toEqual(["ext:std/read", "ext:std/edit"])
  // `surface:"auto"` tools are model-facing, but membership exposes them and a
  // pin naming one is refused outright — so the switch writes none.
  expect(pinsOf(pkg("plan", ["propose", "todo"], []))).toEqual([])
  expect(pinsOf(pkg("ask", ["ask"], []))).toEqual([])
})

/**
 * The one thing `recommended` exists to let a package say (DESIGN §5.1).
 *
 * `manual` means on-once-installed and closable one tool at a time — that is
 * the whole difference from `auto`, where the tool is on because the package is
 * and there is no separate switch. So the default is ON, and a package that
 * says nothing gets every manual tool pinned, exactly as before the field.
 *
 * What it buys is the mixed package: the tools it is FOR are `auto`, the extras
 * only some sessions want are `manual` with `recommended: false`. Before this,
 * a front end pinning every manual tool turned on precisely the half the author
 * had marked to keep off.
 */
test("turning a package on writes the pins it recommends, and an extra it does not is left for a keypress", () => {
  const kit = {
    id: "acme.kit",
    manualTools: ["patrol", "sweep", "demolish"],
    recommendedTools: ["patrol", "sweep"],
  }
  expect(pinsOf(kit)).toEqual(["ext:acme.kit/patrol", "ext:acme.kit/sweep"])
  // Still pinnable, just not by the switch: the tools pane can name it.
  expect(kit.manualTools).toContain("demolish")

  // Every manual tool declining leaves the switch writing nothing at all — an
  // ordinary answer, like a package of `internal` tools.
  expect(pinsOf({ id: "acme.kit", recommendedTools: [] })).toEqual([])
})

/**
 * The three surface words, off a real built manifest — including the one a
 * manifest does not write (T52).
 *
 * The default matters more than the words do. It used to be `pin`, so a tool
 * that said nothing landed in the pinnable half; it is `auto` now, because a
 * package somebody deliberately composed means its tools to be usable. A front
 * end that kept the old default would offer a checkbox for a tool the model can
 * already call — and, worse, write a pin the kernel refuses outright
 * (`PinToolNotPinnable`), which is the whole session.
 */
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
            { name: "read", input: {}, surface: "manual", readonly: true },
            { name: "edit", input: {}, surface: "manual" },
            // An extra: pinnable, but not something turning the package on
            // should switch on for everybody (`recommended`, DESIGN §5.1).
            { name: "demolish", input: {}, surface: "manual", recommended: false },
            // An internal tool a future std might grow: it must not be pinned,
            // and no edit to this file is needed for that to hold.
            { name: "reindex", input: {}, surface: "internal" },
            // …and one that says nothing at all: `auto`, the kernel's default,
            // so it is model-facing through membership and never pinnable.
            { name: "watch", input: {} },
          ],
        },
      }),
    )
    const built = await extSync(store)
    const line = built.lines.find((entry) => entry.id === "std")!
    const what = (await builtContributions(store, root, "std", line.version!))!
    expect(what.manualTools).toEqual(["read", "edit", "demolish"])
    expect(what.internalTools).toEqual(["reindex"])
    expect(what.autoTools).toEqual(["watch"])
    // The switch writes the recommended ones; `demolish` stays pinnable and off.
    expect(what.recommendedTools).toEqual(["read", "edit"])
    expect(pinsOf(what)).toEqual(["ext:std/read", "ext:std/edit"])
    // Nothing said about `apply` either: `manual`, so activating it composes
    // nothing by itself.
    expect(what.apply).toBe("manual")

    // The literal is still the answer when no manifest can be read at all.
    expect(await builtContributions(store, root, "std", "v-nosuchversion")).toBeNull()
    expect(std_pins).toContain("ext:std/edit")
  } finally {
    store.cleanup()
  }
})

/**
 * A package that asks for standing membership, read off a real built manifest
 * (T52). It is the one declaration that keeps the start-up pass from pointing
 * `current` at it, so the fixture is a whole build rather than a literal.
 */
test("a manifest that says `apply: auto` is read as such, and kept off the unattended pass", async () => {
  const store = tempWorkspace()
  try {
    const root = join(store.dir, ".nulya", "extensions")
    writeDraft(store.dir, "house.mode", "the house style")
    writeFileSync(
      join(root, "house.mode", "extension.json"),
      JSON.stringify({
        schema: "nulya.extension/v2",
        id: "house.mode",
        apply: "auto",
        contributes: { system_prompts: ["prompts/identity.md"] },
      }),
    )
    mkdirSync(join(root, "house.mode", "prompts"), { recursive: true })
    writeFileSync(join(root, "house.mode", "prompts", "identity.md"), "write like the house\n")

    const built = await extSync(store)
    const line = built.lines.find((entry) => entry.id === "house.mode")!
    const what = (await builtContributions(store, root, "house.mode", line.version!))!
    expect(what.apply).toBe("auto")
  } finally {
    store.cleanup()
  }
})

test("session_with is one list, replaced rather than merged by a nearer layer", async () => {
  expect(default_settings.extensions.session_with).toEqual(["handoff", "agent"])

  const layer = tempWorkspace()
  try {
    mkdirSync(join(layer.dir, ".nulya"), { recursive: true })
    writeFileSync(join(layer.dir, ".nulya", "tui.toml"), '[extensions]\nsession_with = ["handoff"]\n')
    expect((await loadSettings(layer.dir, {})).extensions.session_with).toEqual(["handoff"])

    // Replacing rather than merging: a nearer layer must be able to ask for
    // FEWER packages, which a union could never express.
    writeFileSync(join(layer.dir, ".nulya", "tui.toml"), "[extensions]\nsession_with = []\n")
    expect((await loadSettings(layer.dir, {})).extensions.session_with).toEqual([])
  } finally {
    layer.cleanup()
  }
})
