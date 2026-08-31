import { For, Index, createMemo } from "solid-js"
import { useScreen, useStyle, type Style } from "../render/theme.ts"
import type { DiffSurface, Line, Surface, ThemeToken } from "nulya-tui/plugin-api"

/**
 * Drawing what a plugin returned (tui-plugin D9): rows of coloured spans, and
 * the transcript-card-only diff primitive.
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

export interface DiffStat {
  added: number
  removed: number
}

export function diffSurfaceOf(value: unknown): DiffSurface | null {
  if (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    (value as { kind?: unknown }).kind === "diff" &&
    typeof (value as { patch?: unknown }).patch === "string"
  ) {
    const record = value as Record<string, unknown>
    return {
      kind: "diff",
      patch: record["patch"] as string,
      ...(typeof record["path"] === "string" ? { path: record["path"] } : {}),
      ...(typeof record["filetype"] === "string" ? { filetype: record["filetype"] } : {}),
      ...(typeof record["added"] === "number" && Number.isFinite(record["added"])
        ? { added: Math.max(0, Math.trunc(record["added"])) }
        : {}),
      ...(typeof record["removed"] === "number" && Number.isFinite(record["removed"])
        ? { removed: Math.max(0, Math.trunc(record["removed"])) }
        : {}),
    }
  }
  return null
}

export function diffStat(surface: DiffSurface): DiffStat {
  if (typeof surface.added === "number" && typeof surface.removed === "number") {
    return { added: Math.max(0, Math.trunc(surface.added)), removed: Math.max(0, Math.trunc(surface.removed)) }
  }
  let added = 0
  let removed = 0
  let inHunk = false
  for (const line of surface.patch.split("\n")) {
    if (line.startsWith("@@")) {
      inHunk = true
      continue
    }
    if (!inHunk) continue
    if (line.startsWith("+")) added += 1
    else if (line.startsWith("-")) removed += 1
  }
  return { added, removed }
}

export function diffFiletype(surface: DiffSurface): string {
  if (surface.filetype) return surface.filetype
  const path = surface.path
  if (!path) return "diff"
  const ext = path.split(/[\\/]/).pop()?.split(".").pop()?.toLowerCase()
  switch (ext) {
    case "ts":
      return "typescript"
    case "js":
      return "javascript"
    case "rs":
      return "rust"
    case "py":
      return "python"
    case "md":
      return "markdown"
    case "zig":
    case "tsx":
    case "jsx":
    case "json":
    case "toml":
      return ext
    default:
      return ext || "diff"
  }
}

/**
 * One ordinary plugin row surface. `revision` is read so the memo re-runs when
 * the host says a plugin's answer may have changed (`PluginHost.revision`) — a
 * plain function has no signals of its own to depend on.
 */
export function PluginSurface(props: {
  /** Called with the width it has; must not throw, but may. */
  render: (width: number) => Line[]
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
  return <PluginRows {...props} />
}

/** A transcript card body: rows by default, diff primitive when the card returns one. */
export function PluginCardSurface(props: {
  render: (width: number) => Surface
  revision: number
  indent?: number
  maxRows?: number
  pkg: string
}) {
  const style = useStyle()
  const screen = useScreen()
  const indent = () => props.indent ?? 2

  const drawn = createMemo((): { rows: Line[]; diff: DiffSurface | null; cut: number; failed: string | null } => {
    void props.revision
    try {
      const value = props.render(surfaceWidth(style, screen().width, indent()))
      const diff = diffSurfaceOf(value)
      if (diff) return { rows: [], diff, cut: 0, failed: null }
      const rows = Array.isArray(value) ? value : []
      const cap = props.maxRows ?? rows.length
      return { rows: rows.slice(0, cap), diff: null, cut: Math.max(0, rows.length - cap), failed: null }
    } catch (error) {
      return { rows: [], diff: null, cut: 0, failed: error instanceof Error ? error.message : String(error) }
    }
  })

  return (
    <box flexDirection="column" width="100%" paddingLeft={indent()} flexShrink={0}>
      {drawn().diff ? (
        <diff
          diff={drawn().diff!.patch}
          filetype={diffFiletype(drawn().diff!)}
          syntaxStyle={style.syntax}
          fg={style.theme.fg}
          width="100%"
          // Source lines are content, not table rows: keep every byte visible
          // on narrow panes instead of clipping the right-hand side.
          wrapMode="char"
        />
      ) : null}
      <Rows rows={drawn().rows} />
      <Cut rows={drawn().cut} pkg={props.pkg} />
      <Failure failed={drawn().failed} pkg={props.pkg} />
    </box>
  )
}

function PluginRows(props: {
  render: (width: number) => Line[]
  revision: number
  indent?: number
  maxRows?: number
  pkg: string
}) {
  const style = useStyle()
  const screen = useScreen()
  const indent = () => props.indent ?? 2

  const drawn = createMemo((): { rows: Line[]; cut: number; failed: string | null } => {
    void props.revision
    try {
      const rows = props.render(surfaceWidth(style, screen().width, indent()))
      const cap = props.maxRows ?? rows.length
      return { rows: rows.slice(0, cap), cut: Math.max(0, rows.length - cap), failed: null }
    } catch (error) {
      return { rows: [], cut: 0, failed: error instanceof Error ? error.message : String(error) }
    }
  })

  return (
    <box flexDirection="column" width="100%" paddingLeft={indent()} flexShrink={0}>
      <Rows rows={drawn().rows} />
      <Cut rows={drawn().cut} pkg={props.pkg} />
      <Failure failed={drawn().failed} pkg={props.pkg} />
    </box>
  )
}

function Rows(props: { rows: Line[] }) {
  const style = useStyle()
  return (
    <Index each={props.rows}>
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
  )
}

function Cut(props: { rows: number; pkg: string }) {
  const style = useStyle()
  return props.rows > 0 ? (
    <text fg={style.theme.faint} height={1}>
      {`+${props.rows} more row${props.rows === 1 ? "" : "s"} · ${props.pkg} drew more than fits here`}
    </text>
  ) : null
}

function Failure(props: { failed: string | null; pkg: string }) {
  const style = useStyle()
  return props.failed !== null ? (
    <text fg={style.theme.dim} height={1}>
      {`${props.pkg} could not draw this · ${props.failed}`}
    </text>
  ) : null
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
