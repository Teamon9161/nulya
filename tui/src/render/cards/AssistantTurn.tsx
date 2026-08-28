import { For, Show, createEffect, createMemo, createSignal, onCleanup, untrack } from "solid-js"
import { useBodyWidth, useStyle } from "../theme.ts"
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
 *
 * THE BODY'S WIDTH IS A DERIVED NUMBER (`useBodyWidth`, BUGS.md #17): the
 * pane's width minus the glyph column and padding, minus ONE COLUMN ALWAYS
 * RESERVED for the scrollbox's scrollbar. Reserving it unconditionally is what
 * removes the last feedback path — a width that depends on whether the content
 * overflows is a width the content gets a vote on, and that vote is the T73
 * flicker. Measuring the box instead of deriving the number was tried twice
 * (T73, T76) and both endings are in the bug log.
 */
export function AssistantTurn(props: { item: AssistantItem }) {
  const style = useStyle()
  const body = useBodyWidth()
  const live = () => props.item.text
  const plain = () => isPlainProse(live())
  // − 2 the glyph column, − 2 the transcript's padding, − 1 the scrollbar's.
  const room = () => Math.max(12, Math.min(body(), style.maxWidth) - 5)
  const lines = createMemo(() => hardWrapLines(stripInlineMarkdown(live()), room()))
  // ONLY the markdown branch is sampled. The plain branch above is already
  // stable under append — one more character rewrites the last row and nothing
  // else — so slowing it down would buy nothing and cost the smoothness it
  // already has. The markdown branch re-lays-out its trailing block on every
  // change, which is the flicker (`sampled`, BUGS.md #21).
  const stream = sampled(
    live,
    () => props.item.streaming,
    () => style.settings.transcript.stream_interval_ms,
  )
  return (
    <box flexDirection="row" width="100%">
      <text fg={style.theme.accent.assistant}>{style.glyphs.assistant} </text>
      <box flexDirection="column" flexGrow={1}>
        <Show
          when={plain()}
          fallback={
            <markdown
              content={stream.text()}
              syntaxStyle={style.syntax}
              fg={style.theme.fg}
              streaming={!stream.done()}
              width={room()}
            />
          }
        >
          <For each={lines()}>{(line) => <text fg={style.theme.fg} height={1}>{line}</text>}</For>
        </Show>
      </box>
    </box>
  )
}

/**
 * Follow `source`, but while `live` is true report it at most once per
 * `interval` milliseconds.
 *
 * WHY A CLOCK AND NOT A PARSER. A markdown document is re-parsed and re-laid-out
 * whole on every content change, and OpenTUI keeps the TRAILING block unstable
 * for as long as `streaming` is set — only the blocks before it are reused
 * (`Markdown.d.ts`, `parseMarkdownIncremental`'s stable count). An answer that
 * has not reached its first blank line yet IS that one trailing block, so every
 * delta re-lays-out all of it, and in a sticky-bottom scrollbox a height that
 * changes moves the whole screen. The instability is upstream and correct — a
 * half-written fence really is not a fence yet. What was ours was looking at it
 * thirty times a second.
 *
 * The alternative was to split the text at the last CLOSED block ourselves and
 * hand markdown only the settled part. That is a second markdown parser living
 * here, maintained against a first one, for a problem whose actual shape is
 * frequency.
 *
 * THE LAST DELTA IS NEVER HELD BACK. `live` going false flushes at once, so what
 * settles on screen is the whole turn — a sampler that could drop the tail
 * would be trading a flicker for a lie. `interval <= 0` means follow every
 * change, which is what this did before.
 */
export function sampled(
  source: () => string,
  live: () => boolean,
  interval: () => number,
): { text: () => string; done: () => boolean } {
  const [shown, setShown] = createSignal(untrack(source))
  const [done, setDone] = createSignal(!untrack(live))
  let timer: ReturnType<typeof setTimeout> | null = null
  const stop = () => {
    if (timer === null) return
    clearTimeout(timer)
    timer = null
  }
  createEffect(() => {
    const next = source()
    const ms = interval()
    if (live()) {
      setDone(false)
      if (ms <= 0) {
        stop()
        setShown(next)
      } else if (next !== untrack(shown) && timer === null) {
        // A timer already running will pick up whatever `source` says WHEN IT
        // FIRES, so the deltas that arrive inside the window cost nothing at
        // all — not a render, not a re-parse, not another timer.
        timer = setTimeout(() => {
          timer = null
          setShown(untrack(source))
        }, ms)
      }
      return
    }
    stop()
    setShown(next)
    // FINALISATION IS DELIBERATELY ONE UPDATE LATE. OpenTUI's markdown stops
    // taking content the moment `streaming` goes false — that is what
    // finalising the trailing token means to it — so a final text that arrived
    // in the SAME update as the flag was simply dropped, and the last words of
    // an answer stayed off the screen (measured: with the flag and the text
    // changing together, the renderable kept showing the text from two deltas
    // earlier). Handing the content over first and the flag on the next tick is
    // the whole ordering this needs, and it is why `done` exists instead of the
    // card reading `item.streaming` straight.
    if (!untrack(done)) queueMicrotask(() => setDone(true))
  })
  onCleanup(stop)
  return { text: shown, done }
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
