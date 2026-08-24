/**
 * Visual tokens (tui.md §6). Restraint is the rule: one colour means one thing,
 * role colour only ever touches a glyph or a head line, body text stays `fg`,
 * metadata is `dim`, and success/failure is a short chip rather than a colour
 * wash over a whole card.
 *
 * FOUR levels of brightness, because two were not enough to read a table by
 * (tui.md §11, T18). They are a hierarchy, not a palette — a token is chosen by
 * what a piece of text IS, never by how it should look:
 *
 *   fg     the thing itself: a card's head line, a selected row, a value
 *   muted  what the thing is made of: an id beside its label, a count, a state
 *   dim    what is written about it: captions, hints, footers, labels
 *   faint  furniture: the hover marker, an empty gutter, a disabled cell
 *
 * `selection` and `hover` are the two row backgrounds, and hover is always the
 * quieter of the two: one says where the keyboard is, the other only that the
 * mouse is passing through.
 */
import { createContext, useContext, type Accessor } from "solid-js"
import { RGBA, SyntaxStyle } from "@opentui/core"
import { useTerminalDimensions } from "@opentui/solid"
import { default_settings, type Settings } from "../state/settings.ts"

export interface Theme {
  fg: string
  /** One step down from `fg`: the parts of a row that are not its subject. */
  muted: string
  dim: string
  /** Furniture — visible only when you look for it. */
  faint: string
  accent: {
    user: string
    assistant: string
    tool: string
    evolve: string
  }
  ok: string
  err: string
  warn: string
  diff: { add: string; del: string; addBg: string; delBg: string }
  hairline: string
  selection: string
  /** The quieter of the two row backgrounds: the pointer is merely here. */
  hover: string
  /**
   * Where a cell goes when the running highlight passes over it (T38).
   *
   * "Brighter" is not a direction a colour has on its own — on a light theme
   * the way to stand out is DOWN, toward ink. So each theme names its own end
   * of the lift, and `shimmerColor` only interpolates. Monochrome names `fg`,
   * which makes the sweep a no-op rather than a flicker in a terminal that was
   * asked for no colour at all.
   */
  lift: string
}

const nulya_dark: Theme = {
  fg: "#d6dae4",
  muted: "#9aa2b2",
  dim: "#6a7180",
  faint: "#4b5263",
  accent: { user: "#8fb3ff", assistant: "#9ad5b0", tool: "#c8cdd8", evolve: "#e0b978" },
  ok: "#7fbf8a",
  err: "#e08a86",
  warn: "#e0b978",
  diff: { add: "#7fbf8a", del: "#e08a86", addBg: "#1f3a2d", delBg: "#432624" },
  hairline: "#2c3140",
  selection: "#2f3550",
  hover: "#242937",
  lift: "#f2f5fb",
}

const nulya_light: Theme = {
  fg: "#22262e",
  muted: "#4d5462",
  dim: "#767d8b",
  faint: "#a2a8b4",
  accent: { user: "#2f5fb8", assistant: "#1f7a45", tool: "#3d434f", evolve: "#9a6b12" },
  ok: "#1f7a45",
  err: "#b03a35",
  warn: "#9a6b12",
  diff: { add: "#1f7a45", del: "#b03a35", addBg: "#dcefe1", delBg: "#f5dddd" },
  hairline: "#d3d7de",
  selection: "#dfe4f0",
  hover: "#eef1f7",
  lift: "#0b0e14",
}

/** NO_COLOR: every token collapses to the terminal's own foreground. */
function monochrome(): Theme {
  const fg = "#ffffff"
  return {
    fg,
    muted: fg,
    dim: fg,
    faint: fg,
    accent: { user: fg, assistant: fg, tool: fg, evolve: fg },
    ok: fg,
    err: fg,
    warn: fg,
    diff: { add: fg, del: fg, addBg: "transparent", delBg: "transparent" },
    hairline: fg,
    selection: fg,
    hover: fg,
    lift: fg,
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
  /** Reasoning: three dots, because that is all anyone is being shown of it. */
  thinking: string
  subSession: string
  /**
   * A row that takes you somewhere else — today the one link a card can carry,
   * to the session a delegation opened (T43). Distinct from every fold and
   * cursor mark on this screen, because it is the one glyph that means "this is
   * not where the thing is".
   */
  open: string
  canceled: string
  /** Something the driver could not do: a failed request, a step that died. */
  failed: string
  foldClosed: string
  foldOpen: string
  /**
   * The gutter mark of a row the pointer is over. Deliberately not the same
   * shape as the cursor's: hover says "this row answers to a click", the cursor
   * says "this row answers to Enter", and one glyph for both would make the two
   * indistinguishable the moment a colour is lost (NO_COLOR, a pale terminal).
   */
  pointer: string
  hairline: string
  /** The left rule of the composition card — the one framed block (tui.md §4.1). */
  bar: string
  /** The effort dial in `/model`: ‹ auto › */
  dialLeft: string
  dialRight: string
  /**
   * The mark on a PICKER's title — `/model` and `/mode` (T31). The two are one
   * gesture at two altitudes (what the next session runs on, what happens to its
   * tool calls), and this is what says so at a glance. Panels that list a store
   * or a journal keep their bare titles: they are places, not choices.
   */
  picker: string
  /** "this is the one in force" — the current model row, a passed check. */
  check: string
  /**
   * The `/ext` switch: is this extension on for the next session (T22)? Two
   * shapes, not two colours — a terminal with no colour still has to say which
   * one it is, the same reason cursor and pointer have two glyphs.
   */
  switchOn: string
  switchOff: string
  /**
   * The opening screen's one tip (T38). Its own shape because one glyph means
   * one thing here: `capability` is what an extension gained, and a tip is not
   * an event — it is the screen talking to the person.
   */
  tip: string
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
  thinking: "⋯",
  subSession: "⤷",
  open: "↗",
  canceled: "⊘",
  failed: "✗",
  foldClosed: "▸",
  foldOpen: "▾",
  pointer: "·",
  hairline: "─",
  bar: "▎",
  dialLeft: "‹",
  dialRight: "›",
  picker: "◈",
  check: "✓",
  switchOn: "●",
  switchOff: "○",
  tip: "✻",
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
  thinking: "...",
  subSession: ">",
  open: "->",
  canceled: "x",
  failed: "!",
  foldClosed: ">",
  foldOpen: "v",
  pointer: ".",
  hairline: "-",
  bar: "|",
  dialLeft: "<",
  dialRight: ">",
  picker: "#",
  check: "*",
  switchOn: "*",
  switchOff: "-",
  tip: "*",
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

/**
 * One cell of a line that is running: a soft band sweeps left to right, rests
 * a beat past the end, and starts again (T38, ported from tcode's
 * `theme::shimmer_color`).
 *
 * The band LIFTS the cell's own colour toward `theme.lift` instead of painting
 * over it, so the line keeps its identity — amber stays amber while it moves —
 * and at rest every cell is exactly `base`. `frame` must be monotonic;
 * `width` is the painted width, so the rest between passes scales with the
 * line rather than with the terminal.
 */
export function shimmerColor(frame: number, column: number, width: number, base: string, lift: string): string {
  const speed = 1.5 // columns per frame
  const sigma = 4.0 // band half-width
  const dwell = 12.0 // off-end travel: a beat of rest between sweeps
  const span = width + dwell + 2 * sigma
  const center = ((frame * speed) % span) - sigma
  const d = column - center
  const t = Math.exp((-d * d) / (2 * sigma * sigma))
  if (t < 0.02) return base
  return mixHex(base, lift, t)
}

/** `a` moved `t` of the way to `b`, in sRGB. Both are `#rrggbb`. */
export function mixHex(a: string, b: string, t: number): string {
  const from = channels(a)
  const to = channels(b)
  if (!from || !to) return a
  const lerp = (x: number, y: number) => Math.round(x + (y - x) * t)
  return (
    "#" +
    [lerp(from[0], to[0]), lerp(from[1], to[1]), lerp(from[2], to[2])]
      .map((v) => Math.max(0, Math.min(255, v)).toString(16).padStart(2, "0"))
      .join("")
  )
}

function channels(hex: string): [number, number, number] | null {
  const raw = hex.trim().replace("#", "")
  if (raw.length !== 6) return null
  const n = Number.parseInt(raw, 16)
  if (Number.isNaN(n)) return null
  return [(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]
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

/**
 * The top-level animation clock. Consumers that are at rest deliberately do not
 * read it, so one 90 ms tick can drive the few moving rows without making every
 * mounted card repaint.
 */
export const FrameContext = createContext<Accessor<number>>()

export function useFrame(): Accessor<number> {
  return useContext(FrameContext) ?? (() => 0)
}
