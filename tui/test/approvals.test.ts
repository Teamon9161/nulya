/**
 * The approval policy (tui.md §5.7): the pure decision behind every gated tool
 * call. The kernel has one semantic — allow, or deny with a note (DESIGN §14) —
 * so everything a person would call "permissions" is here, and it is a function.
 */
import { expect, test } from "bun:test"
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  alwaysKey,
  decide,
  default_rules,
  describeKey,
  isMode,
  modes,
  normalizeMode,
  poolPolicy,
  shellCommand,
  summarize,
  withPolicy,
  type ApprovalContext,
  type GateRequest,
} from "../src/approvals.ts"
import type { Contributions } from "../src/nulya/files.ts"
import { loadTuiState, rememberMode, saveTuiState } from "../src/state/tui_state.ts"
import { initialChoice, mode_choices, modeAt, moveChoice } from "../src/ui/ModePicker.tsx"

const shell = (command: string): GateRequest => ({
  call_id: "c1",
  tool: "shell",
  args: JSON.stringify({ command }),
})

const read: GateRequest = { call_id: "c2", tool: "read", args: JSON.stringify({ path: "src/loop.zig" }) }

function context(over: Partial<ApprovalContext> = {}): ApprovalContext {
  return {
    mode: "ask",
    rules: { ...default_rules },
    always: new Set(),
    idOf: (tool) => (tool === "read" ? "ext:std/read" : undefined),
    readonlyOf: () => undefined,
    ...over,
  }
}

/**
 * The rename (tui.md §11, T31). `auto` promised a judgement — tcode's `Auto` is
 * a classifier reviewing each action — where this mode makes none at all, so it
 * is `unsafe`, tcode's own name for the same stance. The old word survives in
 * exactly one place: reading what an older build wrote.
 */
test("`unsafe` is the mode's name, and `auto` is still readable as it", () => {
  expect(modes).toEqual(["ask", "unsafe"])
  expect(isMode("auto")).toBe(false)
  // …but a word arriving from a file or a command line is normalized, so
  // yesterday's state file and yesterday's tui.toml keep meaning what they said.
  expect(normalizeMode("auto")).toBe("unsafe")
  expect(normalizeMode("unsafe")).toBe("unsafe")
  expect(normalizeMode(" ask ")).toBe("ask")
  expect(normalizeMode("accept-edits")).toBeNull()
  expect(normalizeMode("")).toBeNull()
})

test("a state file written as `auto` comes back as `unsafe`, and is written back that way", () => {
  const path = join(mkdtempSync(join(tmpdir(), "nulya-tui-mode-")), "tui-state.json")
  writeFileSync(path, JSON.stringify({ mode: "auto", model: { profile: "deepseek" } }))
  // Migrated on the way in — and the model pick beside it is untouched: a
  // rename must not cost the other thing this file remembers.
  expect(loadTuiState(path).mode).toBe("unsafe")
  expect(loadTuiState(path).model).toEqual({ profile: "deepseek" })

  // …and the next write says the new word in the file itself, so the old one
  // fades out on its own rather than being migrated forever.
  rememberMode("unsafe", path)
  expect(readFileSync(path, "utf8")).toContain(`"mode": "unsafe"`)
  expect(readFileSync(path, "utf8")).not.toContain("auto")

  // A word that names no mode at all is not remembered as one.
  saveTuiState({ mode: "accept-edits" as never }, path)
  expect(loadTuiState(path).mode).toBeUndefined()
})

/**
 * The picker's selection logic (T31), without a terminal. It opens on the mode
 * in force and CLAMPS rather than wraps: with two rows a wrap makes ↑ and ↓ the
 * same key, and "press down twice to be sure" would land back where it started.
 */
test("the mode picker opens on the mode in force and clamps at both ends", () => {
  expect(mode_choices.map((choice) => choice.mode)).toEqual(["ask", "unsafe"])
  expect(initialChoice("ask")).toBe(0)
  expect(initialChoice("unsafe")).toBe(1)

  expect(moveChoice(0, -1)).toBe(0)
  expect(moveChoice(0, 1)).toBe(1)
  expect(moveChoice(1, 1)).toBe(1)
  expect(moveChoice(1, -1)).toBe(0)

  expect(modeAt(0)).toBe("ask")
  expect(modeAt(1)).toBe("unsafe")
  expect(modeAt(2)).toBeNull()
  // Every row says what its mode does: a picker that only listed two words
  // would be the toggle it replaced, one press further away.
  for (const choice of mode_choices) expect(choice.what.length).toBeGreaterThan(20)
})

test("the mode is the fallback and only the fallback", () => {
  expect(decide(shell("git status"), context({ mode: "ask" }))).toBe("ask")
  expect(decide(shell("git status"), context({ mode: "unsafe" }))).toBe("allow")
})

test("deny outranks everything; ask outranks the mode; allow only settles what nothing else claimed", () => {
  const rules = { ...default_rules, deny: ["shell:rm"], ask: ["shell:git push"], allow: ["shell:git"] }
  // Denied by rule: never asked, so it can never have reached the always-list —
  // which is why deny may be read before it without contradicting the order.
  expect(decide(shell("rm -rf build"), context({ rules, mode: "unsafe" }))).toBe("deny")
  expect(decide(shell("rm -rf build"), context({ rules, always: new Set(["shell:rm"]) }))).toBe("deny")
  // An explicit checkpoint reaches a person even in unsafe.
  expect(decide(shell("git push origin main"), context({ rules, mode: "unsafe" }))).toBe("ask")
  // …and the broader allow still covers the rest of git in ask mode.
  expect(decide(shell("git status"), context({ rules, mode: "ask" }))).toBe("allow")
})

test("an entry is a tool id, a tool name, or a shell command prefix", () => {
  expect(decide(read, context({ rules: { ...default_rules, allow: ["ext:std/read"] } }))).toBe("allow")
  expect(decide(read, context({ rules: { ...default_rules, allow: ["read"] } }))).toBe("allow")
  // A prefix, not a glob, and it only ever matches shell.
  expect(decide(shell("git status --short"), context({ rules: { ...default_rules, allow: ["shell:git status"] } }))).toBe(
    "allow",
  )
  expect(decide(shell("gitk"), context({ rules: { ...default_rules, allow: ["shell:git status"] } }))).toBe("ask")
  expect(decide(read, context({ rules: { ...default_rules, allow: ["shell:read"] } }))).toBe("ask")
})

test("a manifest's readonly claim allows, and the switch stops believing it", () => {
  const readonlyOf = (tool: string) => tool === "read"
  expect(decide(read, context({ readonlyOf }))).toBe("allow")
  expect(decide(read, context({ readonlyOf, rules: { ...default_rules, manifest_readonly: false } }))).toBe("ask")
  // A claim is not a boundary: an explicit `ask` entry still wins over it.
  expect(decide(read, context({ readonlyOf, rules: { ...default_rules, ask: ["ext:std/read"] } }))).toBe("ask")
  // Saying nothing is not saying false, and it is not saying true either.
  expect(decide(read, context({ readonlyOf: () => undefined }))).toBe("ask")
})

test("`always` remembers a tool whole, and shell by its first word only", () => {
  expect(alwaysKey(read, (tool) => (tool === "read" ? "ext:std/read" : undefined))).toBe("ext:std/read")
  expect(alwaysKey(shell("git push origin main"))).toBe("shell:git")
  // The whole point: saying yes once to `git` must not say yes to `rm`.
  const always = new Set(["shell:git"])
  expect(decide(shell("git log"), context({ always }))).toBe("allow")
  expect(decide(shell("rm -rf ."), context({ always }))).toBe("ask")
  expect(describeKey("shell:git")).toBe("shell git")
  expect(describeKey("ext:std/read")).toBe("ext:std/read")
})

test("a shell call with unreadable arguments is not a command anybody can judge", () => {
  const torn: GateRequest = { call_id: "c3", tool: "shell", args: '{"command":"rm -' }
  expect(shellCommand(torn)).toBeNull()
  // So no prefix rule matches it, and it goes to the person in ask mode.
  expect(decide(torn, context({ rules: { ...default_rules, allow: ["shell:rm"] } }))).toBe("ask")
})

// --- tui-plugin U2 D2/D3: a package's own `contributes.policy` ------------

function member(id: string, policy: Contributions["policy"]): Pick<Contributions, "id" | "policy"> {
  return { id, policy }
}

test("poolPolicy: a member with no policy at all contributes nothing", () => {
  expect(poolPolicy([member("std", null)])).toEqual({ deny: [], ask: [], readonlyBy: [] })
  // An explicit `{}` is still a policy declaration (D3's own distinction), but
  // an empty one narrows nothing and claims no readonly.
  expect(poolPolicy([member("plan", { readonly: null, deny: [], ask: [] })])).toEqual({
    deny: [],
    ask: [],
    readonlyBy: [],
  })
})

test("poolPolicy: several members' deny/ask entries pool together, de-duplicated", () => {
  const policy = poolPolicy([
    member("guard", { readonly: null, deny: ["shell"], ask: ["ext:std/write"] }),
    member("rules", { readonly: null, deny: ["shell", "ext:std/edit"], ask: [] }),
  ])
  expect(policy.deny).toEqual(["shell", "ext:std/edit"])
  expect(policy.ask).toEqual(["ext:std/write"])
  expect(policy.readonlyBy).toEqual([])
})

test("poolPolicy: `readonlyBy` names every member that claimed it, in composition order", () => {
  const policy = poolPolicy([
    member("plan", { readonly: true, deny: [], ask: [] }),
    member("std", { readonly: false, deny: [], ask: [] }),
    member("guard", { readonly: true, deny: [], ask: [] }),
  ])
  expect(policy.readonlyBy).toEqual(["plan", "guard"])
})

test("withPolicy: merges a composition's deny/ask into tui.toml's own tables, never touching `allow`", () => {
  const rules = { ...default_rules, allow: ["shell:git"], deny: ["shell:rm"], ask: [] }
  const merged = withPolicy(rules, { deny: ["shell"], ask: ["ext:std/write"], readonlyBy: [] })
  expect(merged.deny).toEqual(["shell:rm", "shell"])
  expect(merged.ask).toEqual(["ext:std/write"])
  expect(merged.allow).toEqual(["shell:git"])
  // No policy entries at all: the same rules object comes back, not a copy —
  // `decide` sees identical behaviour either way.
  expect(withPolicy(rules, { deny: [], ask: [], readonlyBy: [] })).toBe(rules)
})

test("a pooled policy deny actually decides `shell` — the same table `decide` already reads", () => {
  const rules = withPolicy(default_rules, { deny: ["shell"], ask: [], readonlyBy: [] })
  expect(decide(shell("git status"), context({ rules, mode: "unsafe" }))).toBe("deny")
})

test("a pooled policy ask reaches a person even in unsafe mode", () => {
  const rules = withPolicy(default_rules, { deny: [], ask: ["ext:std/write"], readonlyBy: [] })
  const write: GateRequest = { call_id: "c9", tool: "write", args: "{}" }
  const idOf = () => "ext:std/write"
  expect(decide(write, context({ rules, mode: "unsafe", idOf }))).toBe("ask")
})

test("the summary is what the call would actually do", () => {
  expect(summarize(shell("zig build test"))).toBe("zig build test")
  expect(summarize(read)).toContain("src/loop.zig")
  expect(summarize({ call_id: "c", tool: "noop", args: "{}" })).toBe("")
})
