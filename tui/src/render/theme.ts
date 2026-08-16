/**
 * Visual tokens (tui.md §6). Restraint is the rule: one colour means one thing,
 * role colour only ever touches a glyph or a head line, body text stays `fg`,
 * metadata is `dim`, and success/failure is a short chip rather than a colour
 * wash over a whole card.
 */
import { createContext, useContext, type Accessor } from "solid-js"
import { RGBA, SyntaxStyle } from "@opentui/core"
import { useTerminalDimensions } from "@opentui/solid"
import { default_settings, type Settings } from "../state/settings.ts"

export interface Theme {
  fg: string
  dim: string
  accent: {
    user: string
    assistant: string
    tool: string
    evolve: string
  }
  ok: string
  err: string
  warn: string
  diff: { add: string; del: string }
  hairline: string
  selection: string
}

const nulya_dark: Theme = {
  fg: "#d6dae4",
  dim: "#6a7180",
  accent: { user: "#8fb3ff", assistant: "#9ad5b0", tool: "#c8cdd8", evolve: "#e0b978" },
  ok: "#7fbf8a",
  err: "#e08a86",
  warn: "#e0b978",
  diff: { add: "#7fbf8a", del: "#e08a86" },
  hairline: "#2c3140",
  selection: "#2f3550",
}

const nulya_light: Theme = {
  fg: "#22262e",
  dim: "#767d8b",
  accent: { user: "#2f5fb8", assistant: "#1f7a45", tool: "#3d434f", evolve: "#9a6b12" },
  ok: "#1f7a45",
  err: "#b03a35",
  warn: "#9a6b12",
  diff: { add: "#1f7a45", del: "#b03a35" },
  hairline: "#d3d7de",
  selection: "#dfe4f0",
}

/** NO_COLOR: every token collapses to the terminal's own foreground. */
function monochrome(): Theme {
  const fg = "#ffffff"
  return {
    fg,
    dim: fg,
    accent: { user: fg, assistant: fg, tool: fg, evolve: fg },
    ok: fg,
    err: fg,
    warn: fg,
    diff: { add: fg, del: fg },
    hairline: fg,
    selection: fg,
  }
}

export interface Glyphs {
  user: string
  assistant: string
  shell: string
  edit: string
  ext: string
  build: string
  capability: string
  rollback: string
  readKernel: string
  skill: string
  subSession: string
  canceled: string
  foldClosed: string
  foldOpen: string
  hairline: string
  /** The left rule of the composition card — the one framed block (tui.md §4.1). */
  bar: string
  /** The effort dial in `/model`: ‹ auto › */
  dialLeft: string
  dialRight: string
  /** "this is the one in force" — the current model row, a passed check. */
  check: string
}

const unicode_glyphs: Glyphs = {
  user: "›",
  assistant: "●",
  shell: "$",
  edit: "✎",
  ext: "⌘",
  build: "⚙",
  capability: "⚡",
  rollback: "↺",
  readKernel: "⌕",
  skill: "☰",
  subSession: "⤷",
  canceled: "⊘",
  foldClosed: "▸",
  foldOpen: "▾",
  hairline: "─",
  bar: "▎",
  dialLeft: "‹",
  dialRight: "›",
  check: "✓",
}

const ascii_glyphs: Glyphs = {
  user: ">",
  assistant: "*",
  shell: "$",
  edit: "~",
  ext: "#",
  build: "+",
  capability: "!",
  rollback: "<",
  readKernel: "?",
  skill: "=",
  subSession: ">",
  canceled: "x",
  foldClosed: ">",
  foldOpen: "v",
  hairline: "-",
  bar: "|",
  dialLeft: "<",
  dialRight: ">",
  check: "*",
}

export interface Style {
  theme: Theme
  glyphs: Glyphs
  settings: Settings
  maxWidth: number
  /** Items mounted at once, newest first; 0 means all of them. */
  historyWindow: number
  motion: boolean
  spinner: string[]
  /** Derived from the same tokens, so highlighted code cannot drift from the theme. */
  syntax: SyntaxStyle
}

export const spinner_frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
export const ascii_spinner_frames = ["-", "\\", "|", "/"]

function syntaxOf(theme: Theme): SyntaxStyle {
  return SyntaxStyle.fromStyles({
    default: { fg: RGBA.fromHex(theme.fg) },
    comment: { fg: RGBA.fromHex(theme.dim) },
    string: { fg: RGBA.fromHex(theme.accent.assistant) },
    number: { fg: RGBA.fromHex(theme.accent.evolve) },
    keyword: { fg: RGBA.fromHex(theme.accent.user), bold: true },
    function: { fg: RGBA.fromHex(theme.accent.user) },
    type: { fg: RGBA.fromHex(theme.accent.evolve) },
    "markup.heading": { fg: RGBA.fromHex(theme.accent.assistant), bold: true },
    "markup.heading.1": { fg: RGBA.fromHex(theme.accent.assistant), bold: true },
    "markup.list": { fg: RGBA.fromHex(theme.dim) },
    "markup.raw": { fg: RGBA.fromHex(theme.accent.evolve) },
    "markup.link": { fg: RGBA.fromHex(theme.accent.user), underline: true },
  })
}

export function createStyle(settings: Settings, env: Record<string, string | undefined> = process.env): Style {
  const no_color = typeof env["NO_COLOR"] === "string" && env["NO_COLOR"] !== ""
  const theme = no_color ? monochrome() : settings.ui.theme === "nulya-light" ? nulya_light : nulya_dark
  const ascii = settings.transcript.ascii
  return {
    theme,
    glyphs: ascii ? ascii_glyphs : unicode_glyphs,
    settings,
    maxWidth: settings.transcript.max_width,
    historyWindow: settings.transcript.history_window,
    motion: settings.ui.motion && !no_color,
    spinner: ascii ? ascii_spinner_frames : spinner_frames,
    syntax: syntaxOf(theme),
  }
}

/**
 * Cards read their tokens from context so a card is renderable on its own in a
 * test without threading a style object through every parent.
 */
export const StyleContext = createContext<Style>()

let fallback: Style | null = null

export function useStyle(): Style {
  const provided = useContext(StyleContext)
  if (provided) return provided
  fallback ??= createStyle(default_settings)
  return fallback
}

/**
 * The terminal size, read once at the top of the tree. Every card wants to know
 * whether the screen is wide enough for its right-hand chip; asking OpenTUI
 * directly from each of them registers one resize listener per card, which at
 * a few hundred mounted cards is a listener-leak warning and a resize that
 * fans out to all of them. A card rendered on its own (tests) still works: it
 * falls back to asking the renderer itself.
 */
export type ScreenSize = { width: number; height: number }

export const ScreenContext = createContext<Accessor<ScreenSize>>()

export function useScreen(): Accessor<ScreenSize> {
  return useContext(ScreenContext) ?? useTerminalDimensions()
}
