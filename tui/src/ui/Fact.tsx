/**
 * A label and the value beside it — the two-column shape every fact in this
 * front end is written in (the welcome screen's facts, the composition card's
 * rows).
 *
 * The point is the WRAP. A flex row of `<text>` nodes wider than the terminal
 * is not wrapped by OpenTUI but SHRUNK: names cut mid-word, separating spaces
 * swallowed, so `model  codex/gpt-5.5` came out as `modecodex/gpt-5.5`. Here
 * the value is broken by us (`wrapWords`, at ` · ` joints first) into one
 * `<text>` per line, and the continuation lines sit under the value column
 * rather than under the label — so a list that grows grows downward, in line.
 */
import { For } from "solid-js"
import { useStyle } from "../render/theme.ts"
import { wrapWords } from "./columns.ts"

/** The label column the welcome screen hangs its facts off. */
export const label_width = 12

export function Fact(props: {
  label: string
  value: string
  /** Columns the value has to itself; anything wider wraps under it. */
  width: number
  fg?: string
  labelWidth?: number
  /** Repeated at the head of every line — the composition card's left rule. */
  gutter?: { text: string; fg: string }
}) {
  const style = useStyle()
  return (
    <For each={wrapWords(props.value, props.width)}>
      {(line, index) => (
        <box flexDirection="row" width="100%" height={1}>
          {props.gutter ? <text fg={props.gutter.fg}>{props.gutter.text}</text> : null}
          <box width={props.labelWidth ?? label_width} flexShrink={0}>
            <text fg={style.theme.dim}>{index() === 0 ? props.label : ""}</text>
          </box>
          <text fg={props.fg ?? style.theme.muted}>{line}</text>
        </box>
      )}
    </For>
  )
}
