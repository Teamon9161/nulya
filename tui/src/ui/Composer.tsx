import { For, Show, createSignal, onMount } from "solid-js"
import type { KeyEvent, TextareaRenderable } from "@opentui/core"
import { useStyle } from "../render/theme.ts"
import { completions } from "../commands.ts"

/**
 * The composer. Enter sends, Shift+Enter (or Ctrl+J, for terminals without the
 * Kitty protocol) makes a newline, Up on an empty buffer walks the history.
 * Sending while a step runs is allowed and does not interrupt it — the turn is
 * queued and the kernel drains it at its next step boundary (tui.md §4.4).
 *
 * A line beginning with `/` puts the matching commands above the box and Tab
 * completes the first of them. That is the whole of it: no menu to arrow
 * through, no Enter that means "accept the highlighted thing" instead of
 * "send". Enter always sends exactly what is written, which is the one promise
 * an input box must not break.
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

  // The buffer, mirrored as a signal so the completion list can react to it.
  // The textarea owns the text; this only ever follows it.
  const [line, setLine] = createSignal("")
  const matches = () => completions(line())

  const sync = () => setLine(area?.plainText ?? "")

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
    sync()
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

  /** Tab on a half-typed command finishes it, with a space ready for arguments. */
  const complete = (): boolean => {
    const best = matches()[0]
    if (!best || best.name === line()) return false
    clear()
    area?.insertText(best.args ? `${best.name} ` : best.name)
    sync()
    return true
  }

  const onKeyDown = (event: KeyEvent) => {
    if (event.name === "tab") {
      if (complete()) event.preventDefault()
      return
    }
    if (event.name !== "up" && event.name !== "down") {
      // Every other key may have changed the text; read it back after the
      // textarea has handled it.
      queueMicrotask(sync)
      return
    }
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
    sync()
    event.preventDefault()
  }

  return (
    <box flexDirection="column" width="100%" flexShrink={0}>
      <Show when={matches().length > 0}>
        <box flexDirection="column" width="100%" paddingLeft={3} paddingRight={1}>
          <For each={matches().slice(0, 6)}>
            {(command, index) => (
              <box flexDirection="row" width="100%">
                <box width={26} flexShrink={0}>
                  <text fg={index() === 0 ? style.theme.accent.evolve : style.theme.dim}>
                    {command.name}
                    {command.args ? ` ${command.args}` : ""}
                  </text>
                </box>
                <box flexGrow={1} flexShrink={1} flexBasis={0}>
                  <text fg={style.theme.dim}>{command.what}</text>
                </box>
              </box>
            )}
          </For>
          <Show when={matches().length > 1}>
            <text fg={style.theme.dim}>{"  "}Tab completes · Enter sends what is written</text>
          </Show>
        </box>
      </Show>
      {/*
        flexShrink={0}: the composer is the one thing on screen that must never
        be squeezed. Without it a long transcript (or a long overlay list) wins
        the flex negotiation and the input box collapses to a line, then to
        nothing — the screen still works, but there is visibly nowhere to type.
      */}
      <box flexDirection="row" width="100%" flexShrink={0} paddingLeft={1} paddingRight={1}>
        <text fg={style.theme.accent.user}>{style.glyphs.user} </text>
        <textarea
          ref={area}
          flexGrow={1}
          height={3}
          wrapMode="word"
          placeholder={props.placeholder ?? "message nulya  ·  / for commands"}
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
    </box>
  )
}
