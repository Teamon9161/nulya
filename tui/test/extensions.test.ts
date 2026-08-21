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
import { extSeed, extSync, parseSyncLine, parseSyncReport, type SyncReport } from "../src/nulya/cli.ts"
import {
  actionFor,
  activePromptPackages,
  adoptBundled,
  answerFor,
  autoActivatable,
  builtContributions,
  describeDrafts,
  draftColumn,
  failedIds,
  pinsOf,
  planProjectStore,
  promptConsequence,
  promptPackageWarning,
  promptText,
  std_pins,
  stdEditPinDecision,
  summarize,
  syncRoot,
} from "../src/extensions.ts"
import { modelTools } from "../src/nulya/files.ts"
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
  expect(summarize("this checkout", report(["0 built, 0 already built, 2 failed"]))).toBe("this checkout: 0 built · 2 failed")

  // A count is not news anybody can act on. `std: needs zig` scrolling past as
  // "3 failed" is how it stayed invisible (tui.md §11, T22).
  const failed = report([
    "std: needs zig (compiled draft; set NULYA_ZIG or use the embedded toolchain)",
    "guide: v-abc123456789 already built",
    "broken: failed: ManifestUnreadable",
    "1 built, 1 already built, 2 failed",
  ])
  expect(failedIds(failed)).toEqual(["std", "broken"])
  expect(failedIds(report(["1 built, 0 already built, 0 failed"]))).toEqual([])
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
 * run is turned on. Everything below is that rule, with no binary in sight —
 * each case returns before it would spawn anything.
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

  // Arrived and built, but a MODE: `evolution` contributes a system prompt, so
  // no background pass turns it on however it arrived (`autoActivatable`). It
  // is the only bundled id that rule still refuses — and it needs no list of
  // names to be refused (T34).
  expect(await adoptBundled(ws, ["evolution"], built, join(ws.dir, "adopt-mode.json"))).toEqual([])
})

/**
 * The guard the `evolution` bug named (tui.md §11, T31), under T37's sharper
 * question. A background pass must never be the one that puts a system prompt
 * in front of every model this machine runs — but whether activation DOES that
 * is now something the package answers itself (DESIGN §7.2.1).
 */
test("a background pass never activates a mode, and never guesses when it cannot tell", () => {
  const what = (systemPrompts: string[], activation: "always" | "on_request" = "always") => ({
    systemPrompts,
    activation,
  })

  // A prompt that would reach every session: a person's decision, not a
  // start-up side effect. Whoever wrote the package.
  expect(autoActivatable(what(["prompts/identity.md"]))).toBe(false)
  expect(autoActivatable(what([]))).toBe(true)

  // The same package, saying activation only REGISTERS it: switching it on
  // changes no session, so the pass may. This is what makes the `/with` route
  // to a bundled mode appear without anybody deciding anything (T37).
  expect(autoActivatable(what(["prompts/evolution.md"], "on_request"))).toBe(true)

  // The four bundled ids the list used to name are no longer special (T34):
  // `compact` / `handoff` / `agent` declare no prompt, so they are ordinary
  // membership and the pass may switch them on; their DRIVER tools stay off the
  // model's face because their manifests say so, not because this file knows
  // them.
  expect(autoActivatable(what([]))).toBe(true)

  // An unreadable manifest is "don't know", and don't-know is a no: a pass that
  // cannot tell what a package does has not learnt that it does nothing.
  // Leaving it off costs one keypress in `/ext`; the other direction costs
  // every session on the machine.
  expect(autoActivatable(null)).toBe(false)
})

test("what a mode's switch says, in both directions and for the package that named the bug", () => {
  const on = promptConsequence("evolution", true)
  expect(on).toContain("EVERY new session on this machine")
  expect(on).toContain("/with evolution")
  expect(on).toContain("Enter again to turn it off")
  // A mode nobody wrote a command for still gets the per-session way in.
  expect(promptConsequence("house.style", true)).toContain("/with house.style")
  expect(promptConsequence("evolution", false)).toContain("no longer enters new sessions")

  // The same package saying activation only REGISTERS it (T37): the switch is
  // nearly free, and the frightening sentence would be a lie about it.
  const registered = promptConsequence("evolution", true, "on_request")
  expect(registered).not.toContain("EVERY new session")
  expect(registered).toContain("no session changed")
  expect(registered).toContain("/with evolution")
  expect(promptConsequence("evolution", false, "on_request")).toContain("unregistered")
})

test("the start-up check names the modes that are active, and says nothing when none are", () => {
  const entry = (
    id: string,
    over: Partial<{
      current: string | null
      shadowed: boolean
      systemPrompts: string[]
      activation: "always" | "on_request"
    }>,
  ) => ({
    id,
    current: "v-abc" as string | null,
    shadowed: false,
    systemPrompts: [] as string[],
    activation: "always" as "always" | "on_request",
    ...over,
  })
  const listed = [
    entry("std", {}),
    entry("evolution", { systemPrompts: ["prompts/identity.md"] }),
    // Built but switched off: nothing is in front of any model.
    entry("house.style", { current: null, systemPrompts: ["prompts/style.md"] }),
    // Active here, but an earlier root already has this id: this copy never runs.
    entry("shadow.mode", { shadowed: true, systemPrompts: ["prompts/x.md"] }),
    // Active AND a prompt, but it joins only the sessions that name it (T37):
    // warning about this one would teach people to ignore the line.
    entry("opt.in", { systemPrompts: ["prompts/lens.md"], activation: "on_request" }),
  ]
  expect(activePromptPackages(listed)).toEqual(["evolution"])
  expect(activePromptPackages([entry("std", {})])).toEqual([])

  const said = promptPackageWarning(["evolution"])
  expect(said).toContain("evolution active")
  expect(said).toContain("/ext")
  // Nothing to say is said as nothing: a status line that reports the absence
  // of a mode on every start is one more line nobody reads.
  expect(promptPackageWarning([])).toBeNull()
})

test("what a built version contributes is read from the root that sync wrote it to, and null when absent", async () => {
  const store = tempWorkspace()
  try {
    const root = syncRoot(store, false)
    expect(root).toBe(join(store.dir, ".nulya", "extensions"))
    // Nothing built: the honest answer is "don't know", which `autoActivatable`
    // then reads as a refusal.
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
    // It did not say when activation brings it in, so it means what every
    // manifest written before that field meant: every session on this machine.
    expect(what?.activation).toBe("always")
    expect(autoActivatable(what)).toBe(false)
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
