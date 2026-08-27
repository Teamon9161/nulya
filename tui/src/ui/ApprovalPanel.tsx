import { For, createMemo } from "solid-js"
import type { InputRenderable } from "@opentui/core"
import { useScreen, useStyle } from "../render/theme.ts"
import { createHover, onClick, rowBackground, rowGutter } from "./rows.ts"
import { fit, wrapWords } from "./columns.ts"
import { DialogBody, DialogHint, DialogTitle, dialog_gutter } from "./Dialog.tsx"

/**
 * One answer a person can give. `tone` colours the label, not the row: the row
 * background is the cursor's, and two things claiming the same signal is how a
 * list stops saying where you are.
 */
export interface ApprovalChoice {
  label: string
  tone: "ok" | "err" | "warn"
  /** Called with the note, if one was typed. */
  run: (note: string) => void
}

/**
 * The call the kernel is holding open, asked as a DIALOG above the composer
 * (tui.md §5.7, rebuilt in T28 against tcode's `approval.rs`).
 *
 * Two rewrites got it here. It began as one more line under the tool card — a
 * row of eight text nodes that the terminal wrapped into rubble below 78
 * columns, wedged between the other cards of the same batch, because a turn
 * draws its whole batch before the first call runs. T27 moved it above the
 * composer and gave every answer its own row. What that still had was the shape
 * of a shell prompt: a list of letters to press, `[y/n/a]` with more words.
 *
 * This is the version tcode has: a LIST YOU CHOOSE FROM. The pointer moves the
 * cursor, a click answers, `↑↓` and the digits do the same from the keyboard,
 * and — the part that carries its weight every day — `Tab` opens a note that
 * rides along with WHICHEVER option is chosen. "Yes, but use the other flag"
 * and "no, because…" are the same gesture with a different row under the
 * cursor, which is the whole reason the note belongs to the dialog rather than
 * to one designated "deny with a reason" answer.
 *
 * The panel owns the keyboard while it is up (the composer is blurred): the
 * kernel is stopped on this call, so there is nothing else to type at — and
 * typing therefore has one obvious meaning, which is the note.
 */
export function ApprovalPanel(props: {
  /** The model-facing tool name (`shell`, `read`). */
  tool: string
  /** What the call would actually do; may be several lines, and is capped. */
  summary: string
  /** This call's place in the turn's batch, 1-based, and how many there are. */
  position: number
  batch: number
  choices: readonly ApprovalChoice[]
  /** Which row the cursor is on. */
  selected: number
  onSelect: (index: number) => void
  /** Whether the note field has the keyboard. */
  noteFocused: boolean
  onFocusNote: () => void
  /** Handed back so the screen can read, clear and focus the field. */
  onReady: (field: InputRenderable) => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const hover = createHover()
  const width = () => Math.min(screen().width, style.maxWidth)
  const room = () => Math.max(24, width() - 6)

  /**
   * The command, wrapped rather than cut — a long shell line is the thing being
   * judged, and judging half of one is worse than scrolling. Capped anyway: this
   * panel must never grow until the transcript it is about is off screen.
   */
  const summaryRows = createMemo(() => {
    const rows = props.summary
      .split("\n")
      .flatMap((line) => wrapWords(line, room() - dialog_gutter))
      .filter((line) => line.length > 0)
    return rows.length > 6 ? [...rows.slice(0, 6), `… +${rows.length - 6} more lines`] : rows
  })

  const toneColor = (tone: ApprovalChoice["tone"]) =>
    tone === "ok" ? style.theme.ok : tone === "err" ? style.theme.err : style.theme.warn

  const noteClick = onClick(() => props.onFocusNote())
  // The panel reads the field itself, so a MOUSE answer carries the note too. A
  // note typed and then clicked away is still what the person wrote; dropping it
  // because the last gesture was a click would be a small betrayal.
  let field: InputRenderable | null = null
  const note = () => field?.value ?? ""

  return (
    <box flexDirection="column" width="100%" maxWidth={style.maxWidth} paddingLeft={1} paddingRight={1} flexShrink={0}>
      {/* No glyph, deliberately (tui.md §6): `◈` is the mark of choosing what a
          session runs AS, and this is not that — it is one call being judged.
          The warn colour is what says so, the way an overlay's bare title says
          "this is a place". */}
      <DialogTitle
        name="approve this call"
        tone={style.theme.warn}
        caption={`${props.tool}${props.batch > 1 ? ` · ${props.position} of ${props.batch} in this batch` : ""}`}
      />
      <DialogBody lines={summaryRows()} />

      {/* The answers. Every row is a click target and the pointer moves the
          cursor onto it, so the mouse alone gets all the way through this
          dialog — the keyboard is the second way in, not the only one. */}
      <For each={props.choices}>
        {(choice, index) => {
          const click = onClick(() => choice.run(note()))
          const tone = () => ({ selected: props.selected === index(), hovered: hover.at() === index() })
          return (
            <box
              flexDirection="row"
              width="100%"
              height={1}
              flexShrink={0}
              backgroundColor={rowBackground(style, tone())}
              onMouseDown={click.onMouseDown}
              onMouseUp={click.onMouseUp}
              onMouseOver={() => {
                hover.row(index()).onMouseOver()
                // The pointer IS the cursor while it is over the list: a click
                // then answers what the eye is on, and Enter agrees with it.
                if (!props.noteFocused) props.onSelect(index())
              }}
              onMouseOut={hover.row(index()).onMouseOut}
            >
              <text fg={rowGutter(style, tone()).fg} flexShrink={0}>
                {rowGutter(style, tone()).text}
              </text>
              <text fg={style.theme.dim} flexShrink={0}>
                {`${index() + 1}  `}
              </text>
              <text fg={tone().selected ? toneColor(choice.tone) : style.theme.muted} flexShrink={0}>
                {fit(choice.label, room() - dialog_gutter - 3)}
              </text>
            </box>
          )
        }}
      </For>

      {/* The note. Always present, never a mode you have to discover: an empty
          field with its own prompt says "you may say something here" the way a
          hidden `N` key never did. */}
      <box
        flexDirection="row"
        width="100%"
        height={1}
        flexShrink={0}
        onMouseDown={noteClick.onMouseDown}
        onMouseUp={noteClick.onMouseUp}
      >
        {/* On the answers' own content column, so the note reads as one more
            thing in the same list rather than a stray field under it. */}
        <text fg={props.noteFocused ? style.theme.accent.user : style.theme.faint} flexShrink={0}>
          {`${" ".repeat(dialog_gutter)}note  `}
        </text>
        <input
          ref={(el: InputRenderable) => {
            field = el
            props.onReady(el)
          }}
          flexGrow={1}
          placeholder={props.noteFocused ? "" : "Tab to say something about this call"}
          placeholderColor={style.theme.faint}
          textColor={style.theme.fg}
          focusedTextColor={style.theme.fg}
          cursorColor={style.theme.accent.user}
        />
      </box>

      <DialogHint
        width={room()}
        text={
          props.noteFocused
            ? "Enter answers with this note · Tab back to the list · Esc clears it"
            : `↑↓ or 1-${props.choices.length} choose · click an answer · Tab writes a note · Enter answers · Esc denies`
        }
      />
    </box>
  )
}
