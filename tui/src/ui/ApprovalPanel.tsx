import { For, Show } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { createHover, onClick, rowBackground } from "./rows.ts"
import { fit, wrapWords } from "./columns.ts"

/**
 * One thing a person can answer with, on its own row (tui.md §5.7).
 *
 * The key is the whole affordance: it is what is pressed and what is printed,
 * so nothing on this panel is a control whose name has to be learned somewhere
 * else. `run` is also what a click on the row does — the same decision, reached
 * with the other hand.
 */
export interface ApprovalChoice {
  key: string
  label: string
  tone: "ok" | "err" | "warn" | "dim"
  run: () => void
}

/**
 * The call the kernel is holding open, asked ABOVE THE COMPOSER instead of
 * inside the transcript (tui.md §5.7, revised in T27).
 *
 * It used to be one more line under the tool card, on the theory that the card
 * already showed the command and a second box would be a second visual language
 * for the same event. Two things were wrong with that in practice:
 *
 *  - the card the kernel stopped on is usually NOT the last one on screen. A
 *    turn emits its whole batch at once, so all of the calls are drawn before
 *    the first one runs, and the question appeared wedged between them.
 *  - it was a row of eight text nodes, which the terminal wrapped wherever it
 *    ran out of columns: `run this?` and its keys interleaved into two lines of
 *    rubble on any window narrower than 78.
 *
 * So the question moved to the one place a person is already looking — just
 * above the box they would type in — and every row is a single string cut to
 * the width, which is the only wrap-proof shape a terminal has. The card keeps a
 * quiet marker saying which call this is about.
 */
export function ApprovalPanel(props: {
  /** The model-facing tool name (`shell`, `ext:std/read`'s `read`). */
  tool: string
  /** One line of what the call would actually do; empty when there is nothing to show. */
  summary: string
  /** This call's place in the turn's batch, 1-based, and how many there are. */
  position: number
  batch: number
  choices: readonly ApprovalChoice[]
  /** True while a denial is waiting for its typed reason: the composer has the keys. */
  note: boolean
}) {
  const style = useStyle()
  const screen = useScreen()
  const hover = createHover()
  const room = () => Math.max(20, Math.min(screen().width, style.maxWidth) - 8)

  const toneColor = (tone: ApprovalChoice["tone"]) => {
    switch (tone) {
      case "ok":
        return style.theme.ok
      case "err":
        return style.theme.err
      case "warn":
        return style.theme.warn
      default:
        return style.theme.muted
    }
  }

  return (
    <box flexDirection="column" width="100%" paddingLeft={2} paddingRight={1} flexShrink={0}>
      <box flexDirection="row" width="100%" height={1}>
        <text fg={style.theme.warn} flexShrink={0}>
          {style.glyphs.bar} approve this call
        </text>
        <text fg={style.theme.dim} flexShrink={0}>
          {props.batch > 1 ? ` · ${props.position} of ${props.batch} in this batch` : ""}
        </text>
      </box>
      {/* What is being asked about, in the tool's own words. The card above says
          the same thing at length; this says enough to answer without scrolling
          back to find which card the kernel stopped on. */}
      <box flexDirection="row" width="100%" height={1}>
        <text fg={style.theme.muted} flexShrink={0}>
          {"    "}
          {fit(props.tool, Math.max(8, room()))}
        </text>
        <Show when={props.summary.length > 0}>
          <text fg={style.theme.dim} flexShrink={0}>
            {` ${fit(props.summary, Math.max(8, room() - props.tool.length - 1))}`}
          </text>
        </Show>
      </box>

      <Show
        when={!props.note}
        fallback={
          <For each={wrapWords("type the reason and press Enter — the model reads it · Esc denies without one", room())}>
            {(line) => (
              <text fg={style.theme.dim} height={1}>
                {"    "}
                {line}
              </text>
            )}
          </For>
        }
      >
        <For each={props.choices}>
          {(choice, index) => {
            const click = onClick(choice.run)
            return (
              <box
                flexDirection="row"
                width="100%"
                height={1}
                flexShrink={0}
                backgroundColor={rowBackground(style, { selected: false, hovered: hover.at() === index() })}
                onMouseDown={click.onMouseDown}
                onMouseUp={click.onMouseUp}
                {...hover.row(index())}
              >
                <text fg={style.theme.faint} flexShrink={0}>
                  {hover.at() === index() ? `  ${style.glyphs.pointer} ` : "    "}
                </text>
                <text fg={toneColor(choice.tone)} flexShrink={0}>
                  {choice.key}
                </text>
                <text fg={style.theme.dim} flexShrink={0}>
                  {`  ${fit(choice.label, Math.max(8, room() - 4))}`}
                </text>
              </box>
            )
          }}
        </For>
      </Show>
    </box>
  )
}
