import { createMemo } from "solid-js"
import { useBodyWidth, useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import { PluginSurface, surfaceWidth } from "../../plugins/surface.tsx"
import type { PluginUserTurn } from "../../plugins/host.ts"
import type { UserItem } from "../../state/session.ts"

/**
 * A machine-authored user turn interpreted by the package that owns its
 * sentinel.
 *
 * Its width is THIS PANE's (`useBodyWidth`, BUGS.md #10/#17), and here that
 * matters more than anywhere else: this is the card a `/compact` or a handoff
 * carries its context forward in — a long stretch of text nobody can afford to
 * lose the right-hand half of. The number goes to the package's own renderer,
 * so it decides where the package wraps as well as where the host clips.
 */
export function PluginUserTurnCard(props: {
  item: UserItem
  registration: PluginUserTurn
  revision: number
}) {
  const style = useStyle()
  const body = useBodyWidth()
  const view = () => ({ text: props.item.text, queued: props.item.queued })
  const rendered = createMemo(() => {
    void props.revision
    return props.registration.renderer.render(view(), surfaceWidth(style, body(), 4))
  })
  const head = () => props.registration.renderer.head?.(view()) ?? props.registration.pkg
  const defaultOpen = () => props.registration.renderer.defaultOpen?.(view()) ?? false

  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={style.glyphs.subSession}
      accent={style.theme.accent.user}
      head={head()}
      chip={props.item.queued ? "queued" : undefined}
      chipTone="dim"
      defaultOpen={defaultOpen()}
      foldable
    >
      <PluginSurface
        pkg={props.registration.pkg}
        revision={props.revision}
        indent={0}
        render={() => rendered()}
      />
    </CardFrame>
  )
}
