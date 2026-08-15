import { useStyle } from "../theme.ts"
import type { CapabilityItem } from "../../state/session.ts"

/**
 * A `capability_note`: the agent gained a capability mid-session (DESIGN §5.3).
 * Expanded by default and in the evolution accent — this is the moment nulya is
 * built to make visible (tui.md §5.2).
 */
export function CapabilityBanner(props: { item: CapabilityItem }) {
  const style = useStyle()
  return (
    <box flexDirection="column" width="100%" marginTop={1}>
      <box flexDirection="row" width="100%">
        <text fg={style.theme.accent.evolve}>{style.glyphs.capability} capability · </text>
        <text fg={style.theme.fg}>
          {props.item.id}@{props.item.version}
        </text>
      </box>
      <box paddingLeft={2}>
        <text fg={style.theme.dim}>{props.item.text}</text>
      </box>
    </box>
  )
}
