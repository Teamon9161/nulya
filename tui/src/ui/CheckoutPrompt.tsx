/**
 * The checkout question, asked on screen (goals/tui-shell.md §5.3b point 6).
 *
 * A workspace store that arrived with a clone takes part in no session until
 * somebody has looked at it once (DESIGN §9), and a definition in
 * `.nulya/agents` is a system prompt that checkout wrote (tui.md §5.10). For
 * the directory the process was launched in, both are still asked by `main` on
 * the bare terminal before the alternate screen — the right place, because at
 * that moment there is no screen. For every OTHER directory a tab walks into,
 * there is one, and this is the same question inside it.
 *
 * It is a TRUSTED ZONE (§1.1): it grants authority, so it is host chrome, it
 * takes the keyboard while it is up, and no package can draw anything over it
 * (`App.dialogUp`). It wears the composer-dialog skeleton (§6.5) — title, body,
 * one dim line of keys, no blank line — and warn colour, which is what this
 * front end uses for "you are being asked to answer" everywhere else.
 *
 * NOTHING HERE DECIDES ANYTHING. The words, the keys and what each key means
 * are `planCheckout`'s (`extensions.ts`), exactly as they are for the terminal
 * question — so the two askings cannot drift into offering different bargains.
 */
import { DialogBody, DialogHint, DialogTitle } from "./Dialog.tsx"
import { useScreen, useStyle } from "../render/theme.ts"
import type { CheckoutPlan } from "../extensions.ts"

export type CheckoutAsk = Extract<CheckoutPlan, { kind: "ask" }>

/**
 * The plan's own text, minus the two things this presentation says its own way:
 * the trailing `› ` (a bare terminal echoes the keypress there; a dialog does
 * not) and the choice lines (they are the hint line below).
 */
export function promptLines(plan: CheckoutAsk): string[] {
  const choiceLines = new Set(plan.choices.map(([key, what]) => `  ${key}  ${what}`))
  return plan.text
    .split("\n")
    .filter((line) => !choiceLines.has(line))
    .map((line) => line.replace(/›\s*$/, "").trimEnd())
    .filter((line) => line.length > 0)
}

/** `t  trust + build + activate · s  build only · n  not now` */
export function choiceHint(plan: CheckoutAsk): string {
  return plan.choices.map(([key, what]) => `${key} ${what}`).join(" · ")
}

export function CheckoutPrompt(props: { where: string; plan: CheckoutAsk }) {
  const style = useStyle()
  const screen = useScreen()
  const lines = () => promptLines(props.plan)
  return (
    <box flexDirection="column" width="100%" paddingLeft={1} paddingRight={1} flexShrink={0}>
      <DialogTitle name={props.where} caption="this directory brought things of its own" tone={style.theme.warn} />
      <DialogBody lines={lines()} />
      <DialogHint text={choiceHint(props.plan)} width={Math.max(20, screen().width - 2)} />
    </box>
  )
}
