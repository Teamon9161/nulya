import { Show, createMemo } from "solid-js"
import { useStyle } from "../theme.ts"
import { capabilitySummary } from "../../nulya/ledger.ts"
import type { CapabilityItem } from "../../state/session.ts"

/**
 * A `capability_note`: the agent gained a capability mid-session (DESIGN §5.3).
 * Expanded by default and in the evolution accent — this is the moment nulya is
 * built to make visible (tui.md §5.2).
 *
 * The head line names what arrived; the body is the note the model itself was
 * given, verbatim. Nothing is summarised or reworded: the transcript shows what
 * is in the ledger (tui.md §0.2).
 */
export function CapabilityBanner(props: { item: CapabilityItem }) {
  const style = useStyle()
  const summary = createMemo(() => capabilitySummary(props.item.text))
  const names = () => {
    const { tools, skills } = summary()
    const parts: string[] = []
    if (tools.length > 0) parts.push(`tools: ${tools.join(" ")}`)
    if (skills.length > 0) parts.push(`skills: ${skills.join(" ")}`)
    return parts.join(" · ")
  }

  return (
    <box flexDirection="column" width="100%" marginTop={1}>
      <box flexDirection="row" width="100%">
        <text fg={style.theme.accent.evolve}>{style.glyphs.capability} capability · </text>
        <text fg={style.theme.fg}>
          {props.item.id}@{props.item.version}
        </text>
        <Show when={names().length > 0}>
          <text fg={style.theme.dim}> · {names()}</text>
        </Show>
      </box>
      <box paddingLeft={2}>
        <text fg={style.theme.dim}>{props.item.text}</text>
      </box>
    </box>
  )
}
