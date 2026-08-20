import { useStyle } from "../theme.ts"
import { CardFrame, sizeNote } from "./CardFrame.tsx"
import { PluginSurface } from "../../plugins/surface.tsx"
import type { PluginCard } from "../../plugins/host.ts"
import type { ToolItem } from "../../state/session.ts"
import type { ToolPresentation } from "../registry.ts"

/**
 * A tool call drawn by the package that owns the tool (tui-plugin U3,
 * `api.registerCard`).
 *
 * The FRAME is the host's — glyph, head line, chip, folding, spill pointer —
 * exactly as `ExtToolCard`'s is, so a plugin card cannot invent a second visual
 * language for the transcript and cannot make a call look like something other
 * than a tool call. What the plugin supplies is the BODY: the place where
 * `render: "checklist"` was a fixed word from a fixed vocabulary (D12) and a
 * code plugin can instead draw whatever its own arguments mean.
 *
 * Registration is restricted to the package's own tools (D11, enforced in
 * `host.ts`), so a card here is always the tool's author speaking about the
 * tool's author's call.
 */
export function PluginToolCard(props: {
  item: ToolItem
  presentation: ToolPresentation
  card: PluginCard
  revision: number
}) {
  const style = useStyle()
  const chip = () => {
    if (props.item.state === "pending") return "…"
    if (props.item.state === "running") return "running"
    const size = sizeNote(props.item.output)
    if (props.item.ok === false) return size.length > 0 ? `${size} · failed` : "failed"
    return size
  }
  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={props.presentation.glyph}
      accent={style.theme.accent.tool}
      head={props.presentation.head}
      chip={chip()}
      chipTone={props.item.ok === false ? "err" : "dim"}
      defaultOpen={style.settings.transcript.tool_output === "expanded"}
      // Always foldable: a plugin card draws from the ARGUMENTS as well as the
      // output, so there is something to reveal before a call has returned —
      // which is the case the streaming half of a plan card exists for.
      foldable
      spillPath={props.item.spillPath}
    >
      <PluginSurface
        pkg={props.card.pkg}
        revision={props.revision}
        indent={0}
        render={(width) =>
          props.card.renderer.render(
            {
              tool: props.item.tool,
              args: props.item.args,
              output: props.item.output,
              ok: props.item.ok,
              state: props.item.state,
            },
            width,
          )
        }
      />
    </CardFrame>
  )
}
