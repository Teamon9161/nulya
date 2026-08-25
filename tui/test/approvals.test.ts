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
  type ApprovalContext,
  type GateRequest,
} from "../src/approvals.ts"
import type { Contributions } from "../src/nulya/files.ts"
import { loadTuiState, rememberMode, saveTuiState } from "../src/state/tui_state.ts"
import { initialChoice, mode_choices, modeAt, moveChoice } from "../src/ui/ModePicker.tsx"

const shell = (command: string): GateRequest => ({
  call_id: "c1",
  tool: "shell",
  // The builtin: the kernel is not a package and makes no claim about itself.
  tool_id: "builtin.shell",
  readonly: null,
  args: JSON.stringify({ command }),
})

/** A pinned extension tool, as the kernel offers it: name, stable id, claim. */
const readWith = (readonly: boolean | null): GateRequest => ({
  call_id: "c2",
  tool: "read",
  tool_id: "ext:std/read",
  readonly,
  args: JSON.stringify({ path: "src/loop.zig" }),
})

/** …claiming nothing, which is what a manifest that stayed silent means. */
const read: GateRequest = readWith(null)

function context(over: Partial<ApprovalContext> = {}): ApprovalContext {
  return {
    mode: "ask",
    rules: { ...default_rules },
    always: new Set(),
    ...over,
  }
}

/**
 * The rename (tui.md §11, T31). `auto` promised a judgement — tcode's `Auto` is
 * a classifier reviewing each action — where this mode makes none at all, so it
 * is `unsafe`, tcode's own name for the same stance. The compatibility read
 * that kept `auto` meaning `unsafe` is gone with every other pre-release shim
 * (T52): there are two words, and anything else names no mode.
 */
test("there are two modes, and a word that is neither names none", () => {
  expect(modes).toEqual(["ask", "unsafe"])
  expect(isMode("auto")).toBe(false)
  expect(normalizeMode("auto")).toBeNull()
  expect(normalizeMode("unsafe")).toBe("unsafe")
  expect(normalizeMode(" ask ")).toBe("ask")
  expect(normalizeMode("accept-edits")).toBeNull()
  expect(normalizeMode("")).toBeNull()
})

test("a state file's mode survives a round trip, and a word that is no mode is not remembered as one", () => {
  const path = join(mkdtempSync(join(tmpdir(), "nulya-tui-mode-")), "tui-state.json")
  writeFileSync(path, JSON.stringify({ mode: "unsafe", model: { profile: "deepseek" } }))
  // The pick beside it is untouched: reading one key must not cost the other
  // thing this file remembers.
  expect(loadTuiState(path).mode).toBe("unsafe")
  expect(loadTuiState(path).model).toEqual({ profile: "deepseek" })

  rememberMode("ask", path)
  expect(readFileSync(path, "utf8")).toContain(`"mode": "ask"`)

  // A word that names no mode at all is not remembered as one — including the
  // one this mode used to be called.
  saveTuiState({ mode: "auto" as never }, path)
  expect(loadTuiState(path).mode).toBeUndefined()
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
  // The claim rides on the request itself now (DESIGN §4): nothing here opens a
  // manifest, and the config key still decides whether to believe what arrives.
  expect(decide(readWith(true), context())).toBe("allow")
  expect(decide(readWith(true), context({ rules: { ...default_rules, manifest_readonly: false } }))).toBe("ask")
  // A claim is not a boundary: an explicit `ask` entry still wins over it.
  expect(decide(readWith(true), context({ rules: { ...default_rules, ask: ["ext:std/read"] } }))).toBe("ask")
  // Saying nothing is not saying false, and it is not saying true either.
  expect(decide(readWith(null), context())).toBe("ask")
  expect(decide(readWith(false), context())).toBe("ask")
})

test("`always` remembers a tool whole, and shell by its first word only", () => {
  expect(alwaysKey(read)).toBe("ext:std/read")
  expect(alwaysKey(shell("git push origin main"))).toBe("shell:git")
  // The whole point: saying yes once to `git` must not say yes to `rm`.
  const always = new Set(["shell:git"])
  expect(decide(shell("git log"), context({ always }))).toBe("allow")
  expect(decide(shell("rm -rf ."), context({ always }))).toBe("ask")
  expect(describeKey("shell:git")).toBe("shell git")
  expect(describeKey("ext:std/read")).toBe("ext:std/read")
})

test("a shell call with unreadable arguments is not a command anybody can judge", () => {
  const torn: GateRequest = {
    call_id: "c3",
    tool: "shell",
    tool_id: "builtin.shell",
    readonly: null,
    args: '{"command":"rm -',
  }
  expect(shellCommand(torn)).toBeNull()
  // So no prefix rule matches it, and it goes to the person in ask mode.
  expect(decide(torn, context({ rules: { ...default_rules, allow: ["shell:rm"] } }))).toBe("ask")
})

// --- tui-plugin U2 D2/D3: a package's own `contributes.policy` ------------

function member(id: string, policy: Contributions["policy"]): Pick<Contributions, "id" | "policy"> {
  return { id, policy }
}

test("poolPolicy: a member with no policy at all contributes nothing", () => {
  expect(poolPolicy([member("std", null)])).toEqual({ readonlyBy: [] })
  // An explicit `{}` is still a policy declaration (D3's own distinction), but
  // an empty one claims no readonly.
  expect(poolPolicy([member("plan", { readonly: null })])).toEqual({ readonlyBy: [] })
})

test("poolPolicy: `readonlyBy` names every member that claimed it, in composition order", () => {
  const policy = poolPolicy([
    member("plan", { readonly: true }),
    member("std", { readonly: false }),
    member("guard", { readonly: true }),
  ])
  expect(policy.readonlyBy).toEqual(["plan", "guard"])
})

test("a package's policy never reaches the approval tables — the one thing it can ask for is the ceiling", () => {
  // `decide` takes the person's own tables and nothing else. A package used to
  // be able to pool `deny`/`ask` entries into them; the manifest no longer has
  // those fields, and `readonly` is judged before any table is read (App.tsx).
  const policy = poolPolicy([member("plan", { readonly: true })])
  expect(Object.keys(policy)).toEqual(["readonlyBy"])
  expect(decide(shell("git status"), context({ rules: default_rules, mode: "unsafe" }))).toBe("allow")
})

test("the summary is what the call would actually do", () => {
  expect(summarize(shell("zig build test"))).toBe("zig build test")
  expect(summarize(read)).toContain("src/loop.zig")
  expect(summarize({ call_id: "c", tool: "noop", tool_id: null, readonly: null, args: "{}" })).toBe("")
})
