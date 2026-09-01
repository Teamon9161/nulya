import { useStyle } from "../theme.ts"
import { CardFrame } from "./CardFrame.tsx"
import type { CancelMarker } from "../../nulya/ledger.ts"
import type { ToolItem } from "../../state/session.ts"
import type { ToolPresentation } from "../registry.ts"

/**
 * A call the kernel closed out instead of running to completion.
 *
 * There are four markers and each says something different about what happened
 * to the world (`loop.zig`) — "side effects unknown" is not the same
 * warning as "never started". They are recognised by the marker TEXT in the
 * ledger, never by a stream line: replay has no stream and must draw the same
 * card (reminder 4).
 */
const wording: Record<CancelMarker, string> = {
  canceled_executing: "canceled · side effects unknown",
  recording_canceled: "canceled · completed but unrecorded",
  not_executed: "canceled · not executed",
  interrupted: "interrupted · results unrecorded",
}

export function CanceledCard(props: { item: ToolItem; presentation: ToolPresentation; marker: CancelMarker }) {
  const style = useStyle()
  return (
    <CardFrame
      itemKey={props.item.key}
      glyph={style.glyphs.canceled}
      accent={style.theme.warn}
      head={props.presentation.head}
      chip={wording[props.marker]}
      chipTone="warn"
      defaultOpen={false}
      foldable={false}
      spillPath={props.item.spillPath}
    />
  )
}
