/**
 * `--settings-help` is the far end of the one chain a driver has: it has no
 * manifest, so nothing else can say what its settings file takes. What these
 * guard is that the printout is DERIVED from the parser's own description
 * (`setting_fields`) rather than written out beside it — a hand-written copy
 * would pass a "does it print something" test and then rot on the next key.
 *
 * Not asserted: wording, column widths, the order of the tail. Those change
 * without anything being wrong.
 */
import { expect, test } from "bun:test"
import { acpSettingsHelp, tuiSettingsHelp } from "../src/settingshelp.ts"
import { acceptsOf, setting_fields, settingsPaths } from "../src/state/settings.ts"

test("the TUI's settings help carries every key its parser reads", () => {
  const text = tuiSettingsHelp("/ws")
  for (const field of setting_fields) {
    const at = field.key.lastIndexOf(".")
    const table = field.key.slice(0, at)
    const leaf = field.key.slice(at + 1)
    expect(text).toContain(`[${table}]`)
    // The leaf under its own table heading: `[transcript]` then `diff`, which
    // is the shape a person types into the file.
    expect(text.slice(text.indexOf(`[${table}]`))).toContain(`  ${leaf} `)
    // The vocabulary column is `acceptsOf` — the same words `/settings` prints
    // and its picker offers — so what a key takes is written once. Asserted
    // through that function rather than as literal words: which words is the
    // key's business, that both readers get the SAME ones is this test's.
    expect(text).toContain(acceptsOf(field))
  }
  // Both layers, named as paths rather than described, since "where do I write
  // it" is the question a person came with.
  for (const path of settingsPaths("/ws")) expect(text).toContain(path)
})

test("the ACP adapter prints the approvals table and nothing it does not read", () => {
  const text = acpSettingsHelp()
  const approvals = setting_fields.filter((f) => f.key.startsWith("approvals."))
  expect(approvals.length).toBeGreaterThan(0)
  for (const field of approvals) expect(text).toContain(`  ${field.key.slice("approvals.".length)} `)
  // `acp.toml` has one section. A copy of the screen's page would list these.
  for (const table of ["[transcript]", "[ui]", "[extensions]", "[driver]"]) {
    expect(text).not.toContain(table)
  }
})
