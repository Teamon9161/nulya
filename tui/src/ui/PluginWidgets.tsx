import { For, Show, createMemo, createSignal } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { useFolds } from "../state/folds.ts"
import { lifted, onClick } from "./rows.ts"
import { PluginSurface, surfaceWidth, tokenColor } from "../plugins/surface.tsx"
import type { PluginWidget } from "../plugins/host.ts"

/**
 * A plugin's persistent row above the composer (tui-plugin U3,
 * `api.registerWidget`) — the same place the declaration layer's `panel: true`
 * projection sits (T39's `PanelStrip`), and above it, because a package that
 * ships CODE has superseded its own JSON: the ceiling covers the floor. `App`
 * drops a `panel: true` row whose package registered a widget, so the two
 * never say the same thing twice.
 *
 * The FIRST line a widget returns is its head and is always on screen; the
 * rest folds under it. That is the contract's `render(width) -> Line[]`:
 * widgets are rows only, no extra field to declare a title, no second entry
 * point.
 * The head is drawn with the plugin's own spans (a progress widget's colours
 * are half of what it is saying), which is why this is its own small frame
 * rather than `CardFrame`, whose head is a string.
 *
 * The attribution glyph is the host's, as on a panel: a row above the composer
 * that a person did not put there says whose it is.
 */
export function PluginWidgets(props: { widgets: readonly PluginWidget[]; revision: number }) {
  return (
    <Show when={props.widgets.length > 0}>
      <box flexDirection="column" width="100%" flexShrink={0}>
        <For each={props.widgets}>{(widget) => <Widget widget={widget} revision={props.revision} />}</For>
      </box>
    </Show>
  )
}

function Widget(props: { widget: PluginWidget; revision: number }) {
  const style = useStyle()
  const screen = useScreen()
  const folds = useFolds()
  const [hovered, setHovered] = createSignal(false)
  const key = `plugin:${props.widget.pkg}`

  const rows = createMemo(() => {
    void props.revision
    try {
      const drawn = props.widget.renderer.render(surfaceWidth(style, screen().width, 4))
      return Array.isArray(drawn) ? drawn : []
    } catch (error) {
      // Same discipline as `PluginSurface`: a renderer that throws says so on
      // its own row and takes nothing else with it (D10).
      return [[{ text: `could not draw · ${error instanceof Error ? error.message : String(error)}`, token: "dim" as const }]]
    }
  })
  const head = () => rows()[0] ?? []
  const body = () => rows().slice(1)
  const foldable = () => body().length > 0
  const open = () => foldable() && folds.isOpen(key, false)
  const click = onClick(() => {
    if (foldable()) folds.toggle(key, false)
  })
  /** Only a head line that IS a handle lights up under the pointer. */
  const lift = (base: string) => lifted(style, foldable() && hovered(), base)

  return (
    <box flexDirection="column" width="100%" flexShrink={0}>
      <box
        flexDirection="row"
        width="100%"
        height={1}
        flexShrink={0}
        onMouseDown={click.onMouseDown}
        onMouseUp={click.onMouseUp}
        onMouseOver={() => setHovered(true)}
        onMouseOut={() => setHovered(false)}
      >
        <text fg={lift(style.theme.accent.evolve)} flexShrink={0}>
          {`  ${style.glyphs.picker} `}
        </text>
        <For each={head()}>
          {(span) => (
            <text fg={lift(tokenColor(style, span.token))} flexShrink={0}>
              {typeof span?.text === "string" ? span.text.replace(/[\r\n\t]/g, " ") : ""}
            </text>
          )}
        </For>
        <Show when={foldable()}>
          <text fg={style.theme.faint} flexShrink={0}>
            {` ${open() ? style.glyphs.foldOpen : style.glyphs.foldClosed}`}
          </text>
        </Show>
      </box>
      <Show when={open()}>
        {/* A quarter of the screen, opened deliberately: a widget's body is
            behind a fold, so this only ever bounds what somebody asked to see
            (`PluginPanel` has the same guard and the same reason). */}
        <PluginSurface
          pkg={props.widget.pkg}
          revision={props.revision}
          indent={4}
          maxRows={Math.max(2, Math.floor(screen().height / 4))}
          render={() => body()}
        />
      </Show>
    </box>
  )
}
