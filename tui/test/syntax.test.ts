/**
 * The code palette: which one a name means, and where its reach stops.
 *
 * The colours themselves are not asserted — a hex in a test is the same hex in
 * the source with a second place to edit it. What is asserted is the shape of
 * the decision: `auto` answers by background, `theme` follows the interface,
 * `NO_COLOR` overrules every palette, and a code theme colours CODE and leaves
 * the prose around it alone.
 */
import { expect, test } from "bun:test"
import { createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { code_theme_names, paletteFor, syntaxStyleFor, themePalette } from "../src/render/syntax.ts"

// An explicit empty env, not the ambient one: a shell that exports NO_COLOR
// would collapse both themes to the monochrome palette (by design — see the
// mouse test that asks for exactly that with `{ NO_COLOR: "1" }`), and these
// tests are about what the REAL palettes do.
const dark = createStyle({ ...default_settings, ui: { ...default_settings.ui, theme: "nulya-dark" } }, {}).theme
const light = createStyle({ ...default_settings, ui: { ...default_settings.ui, theme: "nulya-light" } }, {}).theme

test("auto is answered by the background, not by the interface theme's name", () => {
  // The whole reason the default is not a palette: a dark palette on a light
  // background is not a preference, it is unreadable. Which two palettes it
  // picks is a taste that may change; that it picks DIFFERENT ones is not.
  expect(paletteFor("auto", dark, true)).not.toEqual(paletteFor("auto", light, false))
  // …and the answer comes from the background alone, so a third interface
  // theme arrives here already answered.
  expect(paletteFor("auto", light, true)).toEqual(paletteFor("auto", dark, true))
})

test("a named palette is the same whatever the interface theme is", () => {
  expect(paletteFor("one-dark", dark, true)).toEqual(paletteFor("one-dark", light, false))
})

test("`theme` is the interface's own tokens, so it moves when they do", () => {
  expect(paletteFor("theme", dark, true)).toEqual(themePalette(dark))
  expect(paletteFor("theme", dark, true)).not.toEqual(paletteFor("theme", light, false))
})

test("a code theme colours code and leaves the prose markup alone", () => {
  const own = syntaxStyleFor("one-dark", dark, { dark: true, noColor: false })
  const interfaceOnly = syntaxStyleFor("theme", dark, { dark: true, noColor: false })
  // The markdown renderable paints an assistant's headings, lists and links
  // with the same style object as the code inside them. Only the code half is
  // the code theme's to change.
  for (const prose of ["markup.heading", "markup.list", "markup.link", "default"]) {
    expect(own.getStyle(prose)).toEqual(interfaceOnly.getStyle(prose))
  }
  expect(own.getStyle("keyword")).not.toEqual(interfaceOnly.getStyle("keyword"))
})

test("NO_COLOR overrules the palette rather than being one more choice", () => {
  const off = syntaxStyleFor("one-dark", dark, { dark: true, noColor: true })
  const asTheme = syntaxStyleFor("theme", dark, { dark: true, noColor: false })
  expect(off.getStyle("keyword")).toEqual(asTheme.getStyle("keyword"))
})

test("every name the settings accept resolves to a palette", () => {
  // The list in `tui.toml` and the switch that reads it are two places one
  // name has to exist in; this is what says they agree.
  for (const name of code_theme_names) {
    expect(Object.keys(paletteFor(name, dark, true))).toHaveLength(14)
  }
})
