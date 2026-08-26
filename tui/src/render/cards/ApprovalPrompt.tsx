import { useStyle } from "../theme.ts"

/**
 * The mark on the tool card the kernel is stopped on (tui.md §5.7).
 *
 * The question itself is asked above the composer (`ui/ApprovalPanel.tsx`),
 * because the card is usually not the last thing on screen — a turn draws its
 * whole batch before the first call runs — and a person answering should not
 * have to find which of six cards the keys belong to. This line is the other
 * half of that: from the card's side, which one is being asked about.
 *
 * One `<text>`, so there is nothing for the terminal to wrap into rubble.
 */
export function ApprovalPrompt() {
  const style = useStyle()
  return (
    <box flexDirection="row" width="100%" paddingLeft={4}>
      <text fg={style.theme.warn}>waiting for you — answer below</text>
    </box>
  )
}

/**
 * The other half of the same idea (T65): in `ask` mode this call was NOT put in
 * front of anybody, because the command it carries only reads
 * (`readonlyshell.ts`). Dim, one line, in the place the question would have
 * been — a person who expected to be asked can see both that they were not and
 * why, which is the only thing that keeps the missing dialog from reading as a
 * mode that quietly stopped working.
 */
export function AutoAllowedMark() {
  const style = useStyle()
  return (
    <box flexDirection="row" width="100%" paddingLeft={4}>
      <text fg={style.theme.dim}>auto-allowed — read-only command</text>
    </box>
  )
}
