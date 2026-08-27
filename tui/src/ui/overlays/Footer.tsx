/**
 * The one line at the bottom of every overlay (tui.md §11, T18).
 *
 * It used to be two or three full sentences of key list, permanently. Three
 * rows of the same dim grey under every panel is both the largest single block
 * of text on those screens and the least often read one — and in `/ext` it was
 * pushing the thing being explained off the bottom. So: the two or three keys
 * that are the point stay visible, everything else is one `?` away, and every
 * overlay does it the same way so that `?` means one thing.
 *
 * `notice` and `warning` sit above the keys because they are about what just
 * happened or about what this panel cannot do, and both outrank a reminder of
 * which letter moves the cursor.
 */
import { For, Show, createSignal, type Accessor } from "solid-js"
import type { KeyEvent } from "@opentui/core"
import { useStyle } from "../../render/theme.ts"
import { wrapWords } from "../columns.ts"

export interface KeyHelp {
  open: Accessor<boolean>
  /** True when the key was ours; the overlay returns without acting on it. */
  consume(key: KeyEvent): boolean
}

/**
 * `?` opens the full key list, `?` or Esc closes it again. Held by the overlay
 * rather than by the footer so that a panel with a text field in it (the
 * `/model` forms) can keep `?` as an ordinary character while the field is up.
 */
export function createKeyHelp(): KeyHelp {
  const [open, setOpen] = createSignal(false)
  return {
    open,
    consume(key: KeyEvent): boolean {
      if (key.name === "?" || key.sequence === "?") {
        setOpen(!open())
        return true
      }
      if (open() && key.name === "escape") {
        setOpen(false)
        return true
      }
      return false
    },
  }
}

export function OverlayFooter(props: {
  width: number
  /** The keys that are the point of this panel, already ` · ` jointed. */
  brief: string
  /** Everything else, one sentence per line, shown while `?` is open. */
  more?: string[]
  /** A standing fact about the panel (drift, "the next session"), always shown. */
  warning?: string
  /** The result of the last action, if any. */
  notice?: string | null
  /** Absent on a panel with no second page of keys (`/help` is its own key list). */
  help?: KeyHelp
}) {
  const style = useStyle()
  const lines = (text: string) => wrapWords(text, props.width)
  return (
    <box flexDirection="column" width="100%" flexShrink={0}>
      <Show when={props.notice}>
        <For each={lines(props.notice!)}>
          {(line) => (
            <text fg={style.theme.muted} height={1}>
              {line}
            </text>
          )}
        </For>
      </Show>
      <Show when={props.warning}>
        <For each={lines(props.warning!)}>
          {(line) => (
            <text fg={style.theme.warn} height={1}>
              {line}
            </text>
          )}
        </For>
      </Show>
      {/* `? keys` is only offered where there is something behind it: a panel
          with two keys that advertises a way to see more keys is a lie the
          first time somebody presses it. */}
      <Show
        when={props.help?.open() && (props.more ?? []).length > 0}
        fallback={
          <For each={lines((props.more ?? []).length > 0 ? `${props.brief} · ? keys` : props.brief)}>
            {(line) => (
              <text fg={style.theme.dim} height={1}>
                {line}
              </text>
            )}
          </For>
        }
      >
        <For each={[props.brief, ...(props.more ?? [])].flatMap(lines)}>
          {(line) => (
            <text fg={style.theme.dim} height={1}>
              {line}
            </text>
          )}
        </For>
      </Show>
    </box>
  )
}
