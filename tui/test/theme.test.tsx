import { expect, test } from "bun:test"
import { For } from "solid-js"
import { testRender } from "@opentui/solid"
import { createStyle } from "../src/render/theme.ts"
import { rowBackground, rowGutter, rowText } from "../src/ui/rows.ts"
import { default_settings } from "../src/state/settings.ts"
import { settle } from "./support.ts"

const tones = [
  { selected: true, hovered: false },
  { selected: false, hovered: true },
  { selected: false, hovered: false },
]
const labels = ["selected row", "hovered row", "idle row"]

test("NO_COLOR keeps selected text visible and retains cursor and pointer marks", async () => {
  for (const theme of ["nulya-dark", "nulya-light"] as const) {
    for (const ascii of [false, true]) {
      for (const noColor of [false, true]) {
        const style = createStyle({
          ...default_settings,
          ui: { ...default_settings.ui, theme },
          transcript: { ...default_settings.transcript, ascii },
        }, noColor ? { NO_COLOR: "1" } : {})
        const setup = await testRender(() => (
          <box flexDirection="column" width="100%">
            <For each={tones}>
              {(tone, index) => (
                <box flexDirection="row" width="100%" height={1} backgroundColor={rowBackground(style, tone)}>
                  <text fg={rowGutter(style, tone).fg}>{rowGutter(style, tone).text}</text>
                  <text fg={rowText(style, tone, style.theme.fg)}>{labels[index()]}</text>
                </box>
              )}
            </For>
          </box>
        ), { width: 40, height: 4 })
        try {
          const frame = await settle(setup, 2)
          expect(frame).toContain(`${style.glyphs.foldOpen} selected row`)
          expect(frame).toContain(`${style.glyphs.pointer} hovered row`)
          expect(style.glyphs.foldOpen).not.toBe(style.glyphs.pointer)
          const lines = setup.captureSpans().lines
          const selected = lines[0]!.spans.find((span) => span.text.includes(labels[0]!))!
          const idle = lines[2]!.spans.find((span) => span.text.includes(labels[2]!))!
          const rgb = (color: { r: number; g: number; b: number }) => [color.r, color.g, color.b]
          expect(rgb(selected.fg)).not.toEqual(rgb(selected.bg))
          if (noColor) {
            expect(rgb(selected.bg)).toEqual(rgb(idle.bg))
          } else {
            expect(rgb(selected.bg)).not.toEqual(rgb(idle.bg))
          }
        } finally {
          setup.renderer.destroy()
        }
      }
    }
  }
}, 60_000)
