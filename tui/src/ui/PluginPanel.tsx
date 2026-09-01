import { useScreen, useStyle } from "../render/theme.ts"
import { PluginSurface } from "../plugins/surface.tsx"
import type { OpenPanel } from "../plugins/host.ts"

/**
 * A plugin's panel, in the composer area (tui-plugin D6) — the same place the
 * approval dialog (`ApprovalPanel`), the mode picker and the agent/with
 * pickers live, and for the same reason: what is being decided is about the
 * conversation right there, and the transcript above it has to stay readable
 * while the decision is made. A full-screen overlay would hide exactly the
 * context a plan review or a question needs.
 *
 * Two things here are the HOST's and never the plugin's:
 *
 *  - the attribution row. `◈ <pkg>` in the picker glyph and the evolve accent
 *    — the same mark the status line uses for a package a session is wearing
 *    — so a panel can never present itself as the screen speaking. This
 *    is the whole of D4's answer to in-process code: the risk was never new
 *    authority, it was a surface that lies about whose it is.
 *  - the hint row. `Esc close` is true whatever the plugin does with keys
 *    (`PluginHost.handleKey` takes `escape` back if the plugin declines it),
 *    so the way out is stated by the side that guarantees it.
 *
 * Everything between them is the plugin's rows, drawn by `PluginSurface`. This
 * is deliberately NOT a refactor of `ApprovalPanel` / `ModePicker` into a
 * shared base: those two are hard-coded surfaces with their own semantics
 * (tui-plugin fact #8 — abstract FROM them, do not rewrite them), and a
 * plugin panel has no rows, no cursor and no note field of its own to share.
 */
export function PluginPanel(props: { panel: OpenPanel; revision: number }) {
  const style = useStyle()
  const screen = useScreen()
  /**
   * Half the screen, and never fewer than three rows. A plugin is told its
   * width and not its height, so a long panel is not misbehaviour — but the
   * whole reason this is a composer-area panel rather than an overlay (D6) is
   * that the transcript stays readable, and a panel that grew until the
   * conversation was off screen would have quietly become the overlay we did
   * not build. `PluginSurface` says how many rows it had to leave out.
   */
  const maxRows = () => Math.max(3, Math.floor(screen().height / 2))
  return (
    <box flexDirection="column" width="100%" maxWidth={style.maxWidth} paddingLeft={1} paddingRight={1} flexShrink={0}>
      <box flexDirection="row" width="100%" height={1}>
        <text fg={style.theme.accent.evolve} flexShrink={0}>
          {style.glyphs.picker} {props.panel.pkg}
        </text>
        <text fg={style.theme.dim} flexShrink={0}>
          {" · this panel is an extension's"}
        </text>
      </box>
      <PluginSurface
        pkg={props.panel.pkg}
        revision={props.revision}
        maxRows={maxRows()}
        render={(width) => props.panel.spec.render(width)}
      />
      <text fg={style.theme.dim} height={1}>
        {"  Esc close"}
      </text>
    </box>
  )
}
