import { Show } from "solid-js"
import { useStyle } from "../theme.ts"
import type { ToolItem } from "../../state/session.ts"

/**
 * The line under a tool card that is waiting for a person (tui.md §5.7).
 *
 * It sits below the card rather than replacing it, because the card already says
 * the one thing worth reading — the command, the path, the arguments the model
 * wrote — and a second rendering of the same fact in a box of its own would be a
 * different visual language for the same event.
 *
 * The keys are spelled out rather than hidden behind `?`: this is the one prompt
 * in the TUI that holds the kernel until somebody answers it. They only act on
 * an empty composer — a letter typed into a half-written line is a letter.
 */
export function ApprovalPrompt(props: { item: ToolItem; note: boolean }) {
  const style = useStyle()
  return (
    <box flexDirection="row" width="100%" paddingLeft={4}>
      <Show
        when={props.note}
        fallback={
          <>
            <text fg={style.theme.warn}>run this? </text>
            <text fg={style.theme.fg}>y</text>
            <text fg={style.theme.dim}> allow · </text>
            <text fg={style.theme.fg}>n</text>
            <text fg={style.theme.dim}> deny · </text>
            <text fg={style.theme.fg}>N</text>
            <text fg={style.theme.dim}> deny with a reason · </text>
            <text fg={style.theme.fg}>a</text>
            <text fg={style.theme.dim}> always this session</text>
          </>
        }
      >
        <text fg={style.theme.warn}>denying · </text>
        <text fg={style.theme.dim}>type a reason and </text>
        <text fg={style.theme.fg}>Enter</text>
        <text fg={style.theme.dim}> — the model reads it · </text>
        <text fg={style.theme.fg}>Esc</text>
        <text fg={style.theme.dim}> denies without one</text>
      </Show>
    </box>
  )
}
