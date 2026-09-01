import { For, Show, createMemo } from "solid-js"
import { useBodyWidth, useStyle } from "../theme.ts"
import { wrapWords } from "../../ui/columns.ts"
import type { RebindItem } from "../../state/session.ts"

/**
 * `model_rebind`: everything below this line was answered by a different model
 * (DESIGN §3.1, goals/model-rebind.md).
 *
 * A rule rather than a card, because it is not a turn — the kernel projects no
 * PromptIR turn for this event on purpose, so the model above the line and the
 * model below it both behave as though nothing was said. What changed is who is
 * speaking, and that is a boundary, not a message.
 *
 * `note` is the kernel's own sentences about the costs, present only on the
 * announcement that goes up the moment somebody asks for the switch
 * (`state/session.ts`, `noteRebind`). It is not re-derived on replay: those
 * words were addressed to the person making the change.
 */
export function RebindCard(props: { item: RebindItem }) {
  const style = useStyle()
  // This pane's columns, not the terminal's (`useBodyWidth`, BUGS.md #10/#17):
  // the rule and its note are `height={1}` rows, which lose their tail rather
  // than reflowing when they are laid out wider than the column they land in.
  const body = useBodyWidth()

  const where = () => {
    const { provider, model, profile } = props.item
    const who = provider || profile
    return model ? (who ? `${who}/${model}` : model) : who || "another model"
  }
  const room = () => Math.max(20, Math.min(body(), style.maxWidth) - 4)
  const head = () => {
    const label = ` model · ${where()} from here `
    const fill = Math.max(2, room() - label.length - 2)
    return `${style.glyphs.hairline.repeat(2)}${label}${style.glyphs.hairline.repeat(fill)}`
  }
  const noteLines = createMemo(() =>
    props.item.note
      .split("\n")
      .flatMap((line) => wrapWords(line, room() - 2))
      .filter((line) => line.length > 0),
  )

  return (
    <box flexDirection="column" width="100%" paddingLeft={2}>
      <text fg={style.theme.muted} height={1}>
        {head()}
      </text>
      <Show when={noteLines().length > 0}>
        <box paddingLeft={2} flexDirection="column" width="100%">
          <For each={noteLines()}>
            {(line) => (
              <text fg={style.theme.dim} height={1}>
                {line}
              </text>
            )}
          </For>
        </box>
      </Show>
    </box>
  )
}
