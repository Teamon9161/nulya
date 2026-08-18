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
import { mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { extSeed, extSync, parseSyncLine, parseSyncReport, type SyncReport } from "../src/nulya/cli.ts"
import {
  actionFor,
  answerFor,
  bundledPromptText,
  describeDrafts,
  draftColumn,
  planProjectStore,
  promptText,
  summarize,
} from "../src/extensions.ts"
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

  // Somebody edits the draft and rolls back to the older version: the sync must
  // not undo that decision.
  const old = one.version!
  writeDraft(ws.dir, "one.mode", "edited since")
  const rebuilt = await extSync(ws, { activate: true })
  const fresh = rebuilt.lines.find((line) => line.id === "one.mode")!
  expect(fresh.version).not.toBe(old)
  expect(fresh.activation).toBe("activated")

  await Bun.spawn({ cmd: [ws.bin, "ext", "rollback", "one.mode", old], cwd: ws.dir }).exited
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

test("a finished pass leaves one line worth reading", () => {
  expect(summarize("user store", report(["3 built, 1 already built, 0 failed"]))).toBe("user store: 3 built · 1 already")
  expect(summarize("this checkout", report(["0 built, 0 already built, 2 failed"]))).toBe("this checkout: 0 built · 2 failed")
})

test("the binary's bundled drafts seed into a store — dry-run counts them, a second pass leaves them alone", async () => {
  const ws = tempWorkspace()
  const home = join(ws.dir, "home")
  const env = { NULYA_HOME: home }
  try {
    const plan = await extSeed(ws, { user: true, dryRun: true, env })
    expect(plan.seeded).toBe(5)
    expect(plan.already).toBe(0)
    expect(plan.ids).toEqual(["compact", "evolution", "guide", "handoff", "std"])

    const first = await extSeed(ws, { user: true, ids: ["guide"], env })
    expect(first.seeded).toBe(1)
    const again = await extSeed(ws, { user: true, ids: ["guide"], env })
    expect(again.seeded).toBe(0)
    expect(again.already).toBe(1)
  } finally {
    ws.cleanup()
  }
})

test("the bundled question names what is missing and what installing does", () => {
  const plan = { seeded: 3, already: 2, ids: ["std", "guide", "compact"], text: "" }
  const text = bundledPromptText(plan)
  expect(text).toContain("3 bundled extensions")
  expect(text).toContain("std · read/write/append/grep/glob")
  expect(text).toContain("guide · a reference skill")
  expect(text).toContain("compact · behind /compact, built on demand")
  expect(text).toContain("\ninstall?\n  t  install + activate std & guide\n  s  install only\n  n  not now\n› ")
  expect(text.endsWith("› ")).toBe(true)
})
