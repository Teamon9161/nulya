import { onMount } from "solid-js"
import type { KeyEvent, TextareaRenderable } from "@opentui/core"
import { useStyle } from "../render/theme.ts"

/**
 * The composer. Enter sends, Shift+Enter (or Ctrl+J, for terminals without the
 * Kitty protocol) makes a newline, Up on an empty buffer walks the history.
 * Sending while a step runs is allowed and does not interrupt it — the turn is
 * queued and the kernel drains it at its next step boundary (tui.md §4.4).
 */
/**
 * What the rest of the screen may do to the composer. Browse mode needs to know
 * whether the buffer is empty (Esc means "leave the composer" only when there is
 * nothing to cancel) and needs to hand the keyboard over and take it back.
 */
export interface ComposerApi {
  isEmpty(): boolean
  focus(): void
  blur(): void
}

export function Composer(props: {
  onSubmit: (text: string) => void
  /**
   * Enter on an empty composer. Returns true when it meant something — the
   * take-over gesture of observer mode (tui.md §5.6) — and false when Enter on
   * nothing should stay nothing.
   */
  onEmptySubmit?: () => boolean
  placeholder?: string
  onReady?: (api: ComposerApi) => void
}) {
  const style = useStyle()
  let area: TextareaRenderable | undefined
  const history: string[] = []
  let cursor = 0
  // The history entry currently shown, if the buffer is one. Up/Down keep
  // walking history while the buffer still IS that entry, and hand back to
  // cursor movement the moment the user edits it.
  let shown: string | null = null

  onMount(() => {
    area?.focus()
    props.onReady?.({
      isEmpty: () => (area?.plainText ?? "").length === 0,
      focus: () => area?.focus(),
      blur: () => area?.blur(),
    })
  })

  const clear = () => {
    if (!area) return
    area.selectAll()
    area.deleteSelection()
  }

  const submit = () => {
    const text = area?.plainText ?? ""
    clear()
    shown = null
    if (text.trim().length === 0) {
      props.onEmptySubmit?.()
      return
    }
    history.push(text)
    cursor = history.length
    props.onSubmit(text)
  }

  const onKeyDown = (event: KeyEvent) => {
    if (event.name !== "up" && event.name !== "down") return
    if (!area || history.length === 0) return
    // History only takes over an EMPTY composer, or one still showing the entry
    // it last recalled; otherwise Up/Down are cursor movement, which is what a
    // multi-line editor owes its user.
    const text = area.plainText
    if (text.length > 0 && text !== shown) return
    if (event.name === "up") {
      if (cursor === 0) return
      cursor -= 1
    } else {
      if (cursor >= history.length) return
      cursor += 1
    }
    clear()
    shown = cursor < history.length ? history[cursor]! : null
    if (shown !== null) area.insertText(shown)
    event.preventDefault()
  }

  return (
    <box flexDirection="row" width="100%" paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.user}>{style.glyphs.user} </text>
      <textarea
        ref={area}
        flexGrow={1}
        height={3}
        wrapMode="word"
        placeholder={props.placeholder ?? "message nulya"}
        placeholderColor={style.theme.dim}
        textColor={style.theme.fg}
        focusedTextColor={style.theme.fg}
        cursorColor={style.theme.accent.user}
        selectionBg={style.theme.selection}
        onSubmit={submit}
        onKeyDown={onKeyDown}
        keyBindings={[
          { name: "return", action: "submit" },
          { name: "return", shift: true, action: "newline" },
          { name: "j", ctrl: true, action: "newline" },
        ]}
      />
    </box>
  )
}
