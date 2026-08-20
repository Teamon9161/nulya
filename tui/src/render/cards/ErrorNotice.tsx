import { For, createMemo } from "solid-js"
import { useScreen, useStyle } from "../theme.ts"
import { wrapWords } from "../../ui/columns.ts"

/** The glyph column every line hangs off, so continuations line up under the text. */
const gutter = 2

/**
 * The last thing that went wrong on the driver side: a request the provider
 * never answered, a step process that died, a `session new` that was refused.
 *
 * Not a transcript ITEM. Nothing here is a ledger event — the kernel wrote no
 * line for it and a replay of this session will not produce it — so it sits
 * outside the item list, at the bottom, for the same reason the composition
 * card sits outside it at the top (`Transcript`). Its lifetime is the one
 * `SessionSnapshot.error` already had: cleared the moment the next model turn
 * starts (`session.ts`, `model started`).
 *
 * It lives here rather than on the status line because that line has one row
 * and shares it with the model, the cost and the chips: `error: model request
 * failed (Transp` was the shape of every error anyone actually read. A failure
 * is the one thing on screen that has to be readable in full.
 *
 * Wrapped by us, one `<text>` per line, for the reason `ui/Fact` is written the
 * way it is: OpenTUI does not wrap an over-wide flex row, it SHRINKS it — which
 * ate the space after the glyph and cut words mid-way.
 */
export function ErrorNotice(props: { text: string }) {
  const style = useStyle()
  const screen = useScreen()
  const room = () => Math.max(20, Math.min(screen().width, style.maxWidth) - gutter - 1)
  const lines = createMemo(() =>
    props.text
      .split("\n")
      .flatMap((line) => wrapWords(line, room()))
      .filter((line) => line.length > 0),
  )
  return (
    <box flexDirection="column" width="100%" marginTop={1}>
      <For each={lines()}>
        {(line, index) => (
          <box flexDirection="row" width="100%" height={1}>
            <box width={gutter} flexShrink={0}>
              <text fg={style.theme.err}>{index() === 0 ? style.glyphs.failed : ""}</text>
            </box>
            <text fg={style.theme.err}>{line}</text>
          </box>
        )}
      </For>
    </box>
  )
}
