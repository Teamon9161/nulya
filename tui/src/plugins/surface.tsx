import { For, Index, createMemo } from "solid-js"
import { useScreen, useStyle, type Style } from "../render/theme.ts"
import type { DiffSurface, Line, Surface, ThemeToken } from "nulya-tui/plugin-api"

/**
 * Drawing what a plugin returned (tui-plugin D9): rows of coloured spans, and
 * nothing else.
 *
 * The whole reason the contract is LINES rather than components is here — this
 * file is the entire distance between a plugin and the screen. There is no
 * component tree to keep in sync, no second copy of Solid to go wrong, no
 * version skew with OpenTUI, and a plugin's renderer is a pure function that a
 * test can call without a terminal. The host keeps every decision a plugin
 * should not be making: which colours the tokens are (so `NO_COLOR` is free
 * and a light theme is free), how wide the surface is, where it sits, who has
 * the keyboard, and whether the rows fold.
 *
 * A renderer that THROWS draws one dim line saying so and nothing else. A
 * plugin is code somebody else wrote running inside a render pass; letting an
 * exception out of here would take the screen down, which is exactly what D10
 * says must never happen for a bad plugin.
 */
export function tokenColor(style: Style, token: ThemeToken | undefined): string {
  switch (token) {
    case "muted":
      return style.theme.muted
    case "dim":
      return style.theme.dim
    case "faint":
      return style.theme.faint
    case "accent.user":
      return style.theme.accent.user
    case "accent.assistant":
      return style.theme.accent.assistant
    case "accent.tool":
      return style.theme.accent.tool
    case "accent.evolve":
      return style.theme.accent.evolve
    case "ok":
      return style.theme.ok
    case "err":
      return style.theme.err
    case "warn":
      return style.theme.warn
    default:
      // Absent, and anything a later contract adds that this build predates:
      // ordinary foreground rather than a guess (the same reading `render`
      // hints get in `registry.ts`).
      return style.theme.fg
  }
}

/**
 * How many columns a surface has, given the indent it is drawn at. The same
 * `maxWidth` clamp every card obeys, so a plugin's rows line up with the
 * transcript's rather than running to the edge of a wide terminal.
 */
export function surfaceWidth(style: Style, screenWidth: number, indent: number): number {
  return Math.max(8, Math.min(screenWidth, style.maxWidth) - indent)
}

/**
 * One plugin surface. `revision` is read so the memo re-runs when the host
 * says a plugin's answer may have changed (`PluginHost.revision`) — a plain
 * function has no signals of its own to depend on.
 */
export function PluginSurface(props: {
  /** Called with the width it has; must not throw, but may. */
  render: (width: number) => Surface
  /** The host's repaint counter; read to make this memo depend on it. */
  revision: number
  /** Left padding, in columns. */
  indent?: number
  /**
   * The most rows this surface may take. A plugin is told its width and not
   * its height (`render(width)`), so a renderer that returns three hundred
   * rows is not misbehaving — it simply cannot know. The host caps it, because
   * the alternative is a surface above the composer that pushes the transcript
   * it is about off the screen. What is cut is said, never silently dropped.
   */
  maxRows?: number
  /** Named in the message if `render` throws. */
  pkg: string
}) {
  const style = useStyle()
  const screen = useScreen()
  const indent = () => props.indent ?? 2

  const lines = createMemo((): { rows: Line[]; diff: DiffSurface | null; cut: number; failed: string | null } => {
    // Depend on the host's counter: a plugin's memory is invisible to Solid.
    void props.revision
    try {
      const drawn = props.render(surfaceWidth(style, screen().width, indent()))
      if (isDiffSurface(drawn)) return { rows: [], diff: drawn, cut: 0, failed: null }
      const rows = Array.isArray(drawn) ? drawn : []
      const cap = props.maxRows ?? rows.length
      return { rows: rows.slice(0, cap), diff: null, cut: Math.max(0, rows.length - cap), failed: null }
    } catch (error) {
      return { rows: [], diff: null, cut: 0, failed: error instanceof Error ? error.message : String(error) }
    }
  })

  return (
    <box flexDirection="column" width="100%" paddingLeft={indent()} flexShrink={0}>
      {lines().diff ? (
        <diff
          diff={lines().diff!.patch}
          filetype={lines().diff!.filetype ?? "diff"}
          syntaxStyle={style.syntax}
          fg={style.theme.fg}
          width="100%"
        />
      ) : null}
      <Index each={lines().rows}>
        {(line) => (
          <box flexDirection="row" width="100%" height={1} flexShrink={0}>
            <For each={spansOf(line())}>
              {(span) => (
                <text fg={tokenColor(style, span.token)} flexShrink={0}>
                  {span.text}
                </text>
              )}
            </For>
          </box>
        )}
      </Index>
      {/* What did not fit, counted rather than dropped in silence. */}
      {lines().cut > 0 ? (
        <text fg={style.theme.faint} height={1}>
          {`+${lines().cut} more row${lines().cut === 1 ? "" : "s"} · ${props.pkg} drew more than fits here`}
        </text>
      ) : null}
      {/* The failure, where the rows would have been. Said in the plugin's own
          place rather than on the status line: this is what that surface is
          doing right now, and it is not news that goes away. */}
      {lines().failed !== null ? (
        <text fg={style.theme.dim} height={1}>
          {`${props.pkg} could not draw this · ${lines().failed}`}
        </text>
      ) : null}
    </box>
  )
}

function isDiffSurface(value: Surface): value is DiffSurface {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    (value as { kind?: unknown }).kind === "diff" &&
    typeof (value as { patch?: unknown }).patch === "string"
  )
}

/**
 * A row's spans, made safe to draw: a line that is not an array is no row, a
 * span whose `text` is not a string contributes nothing, and an empty row
 * still occupies its line (a blank span), because a plugin that returned one
 * meant a blank line.
 */
function spansOf(line: Line): { text: string; token?: ThemeToken }[] {
  if (!Array.isArray(line)) return [{ text: "" }]
  const out: { text: string; token?: ThemeToken }[] = []
  for (const span of line) {
    if (typeof span?.text !== "string" || span.text.length === 0) continue
    // Newlines are not rows (the contract says so): a span that smuggles one
    // would push everything below it out of the layout the host computed.
    out.push({ text: span.text.replace(/[\r\n\t]/g, " "), ...(span.token ? { token: span.token } : {}) })
  }
  return out.length > 0 ? out : [{ text: "" }]
}
