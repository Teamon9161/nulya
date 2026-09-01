/**
 * What CODE is coloured with, as a choice of its own.
 *
 * The syntax style used to be derived from the interface's own tokens, on the
 * reasoning that highlighted code then could not drift from the theme. It could
 * not — and that was the problem: a fenced block came out in the same two
 * accents as every card frame, glyph and status chip around it, so the one
 * region on screen that is a different KIND of text read as more of the same.
 * Code earns its own palette for the reason terminals and editors have always
 * given it one: the colours are not decoration, they are the only structure a
 * block of code has before you read it.
 *
 * WHAT A CODE THEME OWNS, AND WHAT IT DOES NOT. Only the code roles below. The
 * `markup.*` styles — headings, lists, links, inline spans in an assistant's
 * prose — go on coming from the interface theme, because that text is the
 * document this front end is drawing and not a foreign language quoted inside
 * it. `default` stays the theme's foreground for the same reason: it is what
 * uncaptured prose falls back to. So switching code themes changes fenced
 * blocks and nothing else, which is exactly what somebody asking for one wants
 * to happen.
 *
 * The scoped capture names a grammar actually emits (`keyword.control`,
 * `string.special`, `punctuation.bracket`) are not listed: OpenTUI's
 * `getStyleId` falls back to the name before the first dot, so the base roles
 * cover every variant a grammar can invent — and a table that tried to list
 * them would be a per-language table maintained against grammars nobody here
 * controls.
 */
import { RGBA, SyntaxStyle } from "@opentui/core"
import type { Theme } from "./theme.ts"

/**
 * The roles a code palette answers for. One entry per role, no optionals: a
 * palette that forgets `operator` should not silently inherit somebody else's,
 * and a role nobody has an opinion about is spelled by repeating a colour.
 */
export interface CodePalette {
  comment: string
  string: string
  number: string
  boolean: string
  constant: string
  keyword: string
  function: string
  type: string
  variable: string
  property: string
  operator: string
  punctuation: string
  tag: string
  attribute: string
}

/**
 * The names a person can write in `tui.toml`.
 *
 * `auto` is the default and is not a palette: it is "the one that goes with the
 * interface theme", which is the only answer that stays right when somebody
 * switches to the light theme — a dark code palette on a light background is
 * not a preference, it is unreadable.
 *
 * `theme` is what this front end did before there was a choice, kept because
 * somebody may genuinely want code to sit inside the interface rather than
 * stand out from it.
 */
export type CodeThemeName = "auto" | "theme" | "one-dark" | "github-dark" | "github-light"

export const code_theme_names: readonly CodeThemeName[] = [
  "auto",
  "theme",
  "one-dark",
  "github-dark",
  "github-light",
]

/** Atom's One Dark, the palette most people mean by "a dark editor". */
const one_dark: CodePalette = {
  comment: "#5c6370",
  string: "#98c379",
  number: "#d19a66",
  boolean: "#d19a66",
  constant: "#d19a66",
  keyword: "#c678dd",
  function: "#61afef",
  type: "#e5c07b",
  variable: "#e06c75",
  property: "#e06c75",
  operator: "#56b6c2",
  punctuation: "#abb2bf",
  tag: "#e06c75",
  attribute: "#d19a66",
}

/** GitHub's dark default — the colours most diffs and code reviews are read in. */
const github_dark: CodePalette = {
  comment: "#8b949e",
  string: "#a5d6ff",
  number: "#79c0ff",
  boolean: "#79c0ff",
  constant: "#79c0ff",
  keyword: "#ff7b72",
  function: "#d2a8ff",
  type: "#ffa657",
  variable: "#ffa657",
  property: "#79c0ff",
  operator: "#ff7b72",
  punctuation: "#c9d1d9",
  tag: "#7ee787",
  attribute: "#79c0ff",
}

/** …and its light counterpart, which is what `auto` picks under `nulya-light`. */
const github_light: CodePalette = {
  comment: "#6e7781",
  string: "#0a3069",
  number: "#0550ae",
  boolean: "#0550ae",
  constant: "#0550ae",
  keyword: "#cf222e",
  function: "#8250df",
  type: "#953800",
  variable: "#953800",
  property: "#0550ae",
  operator: "#cf222e",
  punctuation: "#1f2328",
  tag: "#116329",
  attribute: "#0550ae",
}

/**
 * The old behaviour, as a palette: every code role taken from an interface
 * token. Written out rather than special-cased so that "code follows the
 * interface" is one more entry in the same table and not a second code path.
 */
export function themePalette(theme: Theme): CodePalette {
  return {
    comment: theme.dim,
    string: theme.accent.assistant,
    number: theme.accent.evolve,
    boolean: theme.accent.evolve,
    constant: theme.accent.evolve,
    keyword: theme.accent.user,
    function: theme.accent.user,
    type: theme.accent.evolve,
    variable: theme.fg,
    property: theme.fg,
    operator: theme.muted,
    punctuation: theme.muted,
    tag: theme.accent.user,
    attribute: theme.accent.evolve,
  }
}

/**
 * Which palette a name means, for this interface theme.
 *
 * `dark` rather than the theme's own name, because what makes a code palette
 * legible is the background it is drawn on and nothing else; a third interface
 * theme would arrive here already answered.
 */
export function paletteFor(name: CodeThemeName, theme: Theme, dark: boolean): CodePalette {
  switch (name) {
    case "theme":
      return themePalette(theme)
    case "one-dark":
      return one_dark
    case "github-dark":
      return github_dark
    case "github-light":
      return github_light
    default:
      return dark ? one_dark : github_light
  }
}

/**
 * The style handed to every `<markdown>` in the transcript.
 *
 * `noColor` is not a palette choice: `NO_COLOR` means the whole screen is one
 * colour, and a code theme that still painted keywords purple would be reading
 * that variable as a suggestion.
 */
export function syntaxStyleFor(
  name: CodeThemeName,
  theme: Theme,
  options: { dark: boolean; noColor: boolean },
): SyntaxStyle {
  const code = options.noColor ? themePalette(theme) : paletteFor(name, theme, options.dark)
  const fg = (hex: string) => ({ fg: RGBA.fromHex(hex) })
  return SyntaxStyle.fromStyles({
    // The document's own text, not the code's: prose falls back to this.
    default: fg(theme.fg),
    comment: fg(code.comment),
    string: fg(code.string),
    number: fg(code.number),
    boolean: fg(code.boolean),
    constant: fg(code.constant),
    keyword: fg(code.keyword),
    function: fg(code.function),
    type: fg(code.type),
    variable: fg(code.variable),
    property: fg(code.property),
    operator: fg(code.operator),
    punctuation: fg(code.punctuation),
    tag: fg(code.tag),
    attribute: fg(code.attribute),
    // Prose markup, from the interface theme in every code theme.
    "markup.heading": { fg: RGBA.fromHex(theme.accent.assistant), bold: true },
    "markup.heading.1": { fg: RGBA.fromHex(theme.accent.assistant), bold: true },
    "markup.list": fg(theme.dim),
    "markup.raw": fg(theme.accent.evolve),
    "markup.link": { fg: RGBA.fromHex(theme.accent.user), underline: true },
  })
}
