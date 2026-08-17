/**
 * The evolution table (tui.md §5.2), unit-tested where it lives: one place
 * matches on a tool name or a command prefix, so one test file can cover every
 * row of it without a renderer.
 *
 * Extraction is best effort by design — the last test pins the promise that a
 * command this table cannot read falls back to a plain shell card rather than
 * throwing.
 */
import { expect, test } from "bun:test"
import { describeTool } from "../src/render/registry.ts"
import { createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"

const glyphs = createStyle(default_settings, {}).glyphs

function shell(command: string, output = "") {
  return describeTool({ tool: "shell", args: JSON.stringify({ command }), output }, glyphs)
}

test("nulya src reads the kernel and counts lines", () => {
  const card = shell("nulya src emit.zig", "pub const head_bytes = 4096;\n[exit 0]")
  expect(card.kind).toBe("evolve")
  expect(card.head).toBe("read kernel · emit.zig")
  expect(card.countsLines).toBe(true)
  expect(shell("nulya src").head).toBe("read kernel · (tree)")
})

test("ext init names the extension and where it landed", () => {
  const card = shell("nulya ext init lint", "initialized extension 'lint' at .nulya/extensions/lint\n[exit 0]")
  expect(card.head).toBe("ext init · lint → .nulya/extensions/lint")
  // `--script` is a flag, not the id.
  expect(shell("nulya ext init --script lint").head).toBe("ext init · lint")
})

test("ext build reads the sealed version out of stdout", () => {
  const card = shell(
    "nulya ext build .nulya/extensions/lint",
    ".nulya/extensions/lint: v-3f2a91 (built)\n[exit 0]",
  )
  expect(card.head).toBe("ext build · lint → v-3f2a91")
  expect(shell("nulya ext build .nulya/extensions/lint").head).toBe("ext build · lint")
  expect(
    shell("nulya ext build .nulya/extensions/lint", ".nulya/extensions/lint: v-3f2a91 (already built)\n[exit 0]").head,
  ).toBe("ext build · lint → v-3f2a91")
})

test("activate and rollback are two different verbs with two different glyphs", () => {
  const activate = shell("nulya ext activate lint v-3f2a91")
  const rollback = shell("nulya ext rollback lint v-0011aa")
  expect(activate.head).toBe("activate · lint@v-3f2a91")
  expect(rollback.head).toBe("rollback · lint@v-0011aa")
  expect(activate.glyph).toBe(glyphs.capability)
  expect(rollback.glyph).toBe(glyphs.rollback)
})

test("ext run names the extension and the tool, past any --arg pairs", () => {
  expect(shell("nulya ext run lint lint_zig '{\"path\":\"src\"}'").head).toBe("ext run · lint/lint_zig")
  expect(shell("nulya ext run lint --arg path=src").head).toBe("ext run · lint")
  expect(shell("nulya ext run lint lint_zig --arg path=src").head).toBe("ext run · lint/lint_zig")
})

test("skill load shows the frozen ref", () => {
  expect(shell("nulya skill load evolution/zig-style").head).toBe("skill · evolution/zig-style")
})

test("session new becomes a sub-session card once it has printed its id", () => {
  const card = shell("nulya session new --model scripted", "s-1786815442964-8462dd\n[exit 0]")
  expect(card.kind).toBe("subsession")
  expect(card.head).toBe("sub-session · s-1786815442964-8462dd")
  expect(card.sessionId).toBe("s-1786815442964-8462dd")
  expect(shell("nulya session new").sessionId).toBeNull()
})

test("session step takes the id from its arguments", () => {
  const card = shell("nulya session step s-1786815442964-8462dd --max-steps 4")
  expect(card.kind).toBe("subsession")
  expect(card.head).toBe("sub-session step · s-1786815442964-8462dd")
  expect(card.sessionId).toBe("s-1786815442964-8462dd")
})

test("the slow loop's two verbs are not sub-sessions", () => {
  // Reading the store drives nothing…
  const list = shell("nulya session list --json", '{"sessions":[]}\n[exit 0]')
  expect(list.kind).toBe("evolve")
  expect(list.head).toBe("sessions")
  expect(list.sessionId).toBeNull()

  // …and judging one is a write to the outcome journal, beside the ledger.
  const judged = shell("nulya session outcome s-1786815442964-8462dd partial --note tried")
  expect(judged.head).toBe("outcome · partial · s-1786815442964-8462dd")
  expect(judged.glyph).toBe(glyphs.capability)
  // The card names a session, so Enter can still open it.
  expect(judged.sessionId).toBe("s-1786815442964-8462dd")
})

test("an unreadable nulya command falls back to a shell card instead of failing", () => {
  const card = shell("nulya toolchain zig version")
  expect(card.kind).toBe("shell")
  expect(card.head).toBe("nulya toolchain zig version")
  expect(shell("nulya ext frobnicate lint").kind).toBe("shell")
})

test("shell, edit and extension tools each get their own card", () => {
  expect(shell("zig build test").kind).toBe("shell")
  const edit = describeTool(
    { tool: "edit", args: JSON.stringify({ path: "src/emit.zig", old_string: "a", new_string: "b" }), output: "" },
    glyphs,
  )
  expect(edit.kind).toBe("edit")
  expect(edit.head).toBe("src/emit.zig")
  expect(edit.isEdit).toBe(true)
  const ext = describeTool({ tool: "lint_zig", args: JSON.stringify({ path: "src" }), output: "" }, glyphs)
  expect(ext.kind).toBe("ext")
  expect(ext.head).toBe("lint_zig · path=src")
  // A stable id (`ext:<ext>/<tool>`) resolves to the same tool name.
  expect(describeTool({ tool: "ext:lint/lint_zig", args: "{}", output: "" }, glyphs).head).toContain("lint_zig")
})

test("a still-streaming call shows its raw arguments rather than guessing", () => {
  const card = describeTool({ tool: "shell", args: '{"command":"zig bu', output: "" }, glyphs)
  expect(card.kind).toBe("shell")
  expect(card.head).toBe('{"command":"zig bu')
})
