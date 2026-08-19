/**
 * The approval policy (tui.md §5.7): the pure decision behind every gated tool
 * call. The kernel has one semantic — allow, or deny with a note (DESIGN §14) —
 * so everything a person would call "permissions" is here, and it is a function.
 */
import { expect, test } from "bun:test"
import {
  alwaysKey,
  decide,
  default_rules,
  describeKey,
  shellCommand,
  summarize,
  type ApprovalContext,
  type GateRequest,
} from "../src/approvals.ts"

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

test("the mode is the fallback and only the fallback", () => {
  expect(decide(shell("git status"), context({ mode: "ask" }))).toBe("ask")
  expect(decide(shell("git status"), context({ mode: "auto" }))).toBe("allow")
})

test("deny outranks everything; ask outranks the mode; allow only settles what nothing else claimed", () => {
  const rules = { ...default_rules, deny: ["shell:rm"], ask: ["shell:git push"], allow: ["shell:git"] }
  // Denied by rule: never asked, so it can never have reached the always-list —
  // which is why deny may be read before it without contradicting the order.
  expect(decide(shell("rm -rf build"), context({ rules, mode: "auto" }))).toBe("deny")
  expect(decide(shell("rm -rf build"), context({ rules, always: new Set(["shell:rm"]) }))).toBe("deny")
  // An explicit checkpoint reaches a person even in auto.
  expect(decide(shell("git push origin main"), context({ rules, mode: "auto" }))).toBe("ask")
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

test("the summary is what the call would actually do", () => {
  expect(summarize(shell("zig build test"))).toBe("zig build test")
  expect(summarize(read)).toContain("src/loop.zig")
  expect(summarize({ call_id: "c", tool: "noop", args: "{}" })).toBe("")
})
