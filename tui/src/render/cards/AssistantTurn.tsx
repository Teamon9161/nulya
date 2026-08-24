import { For, Show, createMemo } from "solid-js"
import { useScreen, useStyle } from "../theme.ts"
import { hardWrapLines } from "../../ui/columns.ts"
import type { AssistantItem } from "../../state/session.ts"

/**
 * An assistant turn: role colour on the glyph only, body text in plain `fg`
 * (tui.md §6).
 *
 * NO TRAILING CURSOR (T43). A ` ▍` used to be appended to the content while the
 * turn streamed, and because it was appended to the CONTENT it was markdown:
 * every delta re-parsed a document one glyph longer, and at every block
 * boundary that glyph changed the answer. Text ending in a newline put the
 * cursor on a row of its own (+1 row), the next delta took it back (−1), an
 * opening fence swallowed it entirely — a measured 7 → 6 → 7 row bounce inside
 * three deltas, and every bounce moves a sticky-bottom scrollbox, which is the
 * whole screen. Without it the block count only ever grows.
 *
 * Ordinary prose is also pre-wrapped here instead of delegated to a soft wrap:
 * a transcript row is a durable record, and resume/resize must not let the
 * terminal decide a different row count between frames. Structured markdown
 * still uses OpenTUI's markdown primitive because code blocks and lists need
 * their own renderer more than they need the plain-prose fast path.
 */
export function AssistantTurn(props: { item: AssistantItem }) {
  const style = useStyle()
  const screen = useScreen()
  const plain = () => isPlainProse(props.item.text)
  const room = () => Math.max(12, Math.min(screen().width, style.maxWidth) - 4)
  const lines = createMemo(() => hardWrapLines(stripInlineMarkdown(props.item.text), room()))
  return (
    <box flexDirection="row" width="100%">
      <text fg={style.theme.accent.assistant}>{style.glyphs.assistant} </text>
      <box flexDirection="column" flexGrow={1}>
        <Show
          when={plain()}
          fallback={
            <markdown
              content={props.item.text}
              syntaxStyle={style.syntax}
              fg={style.theme.fg}
              streaming={props.item.streaming}
              width="100%"
            />
          }
        >
          <For each={lines()}>{(line) => <text fg={style.theme.fg} height={1}>{line}</text>}</For>
        </Show>
      </box>
    </box>
  )
}

function isPlainProse(text: string): boolean {
  for (const line of text.split("\n")) {
    const trimmed = line.trim()
    if (trimmed.length === 0) continue
    if (/^(```|~~~|#{1,6}\s|[-*+]\s|\d+\.\s|>\s|\|)/.test(trimmed)) return false
  }
  return true
}

function stripInlineMarkdown(text: string): string {
  return text
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/__([^_]+)__/g, "$1")
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, "$1")
}
