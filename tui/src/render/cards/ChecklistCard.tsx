import { For } from "solid-js"
import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import type { ToolItem } from "../../state/session.ts"
import { checklistChip, checklistMarker, type ToolPresentation } from "../registry.ts"

/**
 * `render: "checklist"` (DESIGN §7.2.1, tui-plugin D12): a package's own tool
 * call, drawn as a plan instead of raw output — `render/registry.ts` has
 * already done the one thing that matters here, matching the call's `items:
 * [{text, state}]` convention, so this card only has to lay the rows out.
 */
export function ChecklistCard(props: { item: ToolItem; presentation: ToolPresentation }) {
  const style = useStyle()
  const items = () => props.presentation.checklist ?? []
  const chip = () => (props.item.state === "pending" ? "…" : checklistChip(items()))
  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={props.presentation.glyph}
      accent={style.theme.accent.tool}
      head={props.presentation.head}
      chip={chip()}
      chipTone="dim"
      defaultOpen={style.settings.transcript.tool_output === "expanded"}
      foldable={items().length > 0}
      spillPath={props.item.spillPath}
    >
      <For each={items()}>
        {(entry) => (
          <text fg={entry.state === "done" ? style.theme.dim : style.theme.fg}>
            {checklistMarker(entry.state)} {entry.text}
          </text>
        )}
      </For>
    </CardFrame>
  )
}
