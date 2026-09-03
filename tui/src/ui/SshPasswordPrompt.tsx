/**
 * Host-owned secret entry, drawn where the composer was.
 *
 * It used to be three unbordered lines stacked above a composer that kept its
 * border, its cursor and its "message nulya" placeholder — so the one box on
 * screen that said "type here" was the one box that would not take the
 * password. This takes the composer's place instead: same width, same border,
 * same prompt column, a different colour and a title that names what is being
 * asked. The person types into the only input box there is.
 *
 * The actual bytes never become a text renderable — the field draws a mask of
 * its own, and its width is the byte count it is told, nothing more.
 */
import { useScreen, useStyle } from "../render/theme.ts"
import { ascii_border } from "./Composer.tsx"
import { DialogHint, DialogTitle } from "./Dialog.tsx"

export function SshPasswordPrompt(props: { spec: string; bytes: number }) {
  const style = useStyle()
  const screen = useScreen()
  const ascii = () => style.settings.transcript.ascii
  /** Border, padding and the prompt glyph, so the mask cannot overrun the row. */
  const room = () => Math.max(1, screen().width - 6)
  const mask = () => (ascii() ? "*" : "•").repeat(Math.min(props.bytes, room()))
  return (
    <box flexDirection="column" width="100%" flexShrink={0}>
      <box flexDirection="column" width="100%" paddingLeft={2} paddingRight={1}>
        {/* No glyph: `◈` is the mark of choosing what a session runs as, and
            this is not a choice — the coloured border below is what says the
            box in front of you has changed job. */}
        <DialogTitle name="SSH password" caption={props.spec} tone={style.theme.accent.evolve} />
      </box>
      <box
        flexDirection="row"
        width="100%"
        flexShrink={0}
        border
        borderStyle={ascii() ? "single" : "rounded"}
        customBorderChars={ascii() ? ascii_border : undefined}
        borderColor={style.theme.accent.evolve}
        paddingLeft={1}
        paddingRight={1}
      >
        <text fg={style.theme.accent.evolve} flexShrink={0}>
          {style.glyphs.user}{" "}
        </text>
        <text fg={style.theme.fg} flexShrink={1}>
          {mask()}
        </text>
        {/* The caret the textarea would have drawn, in its own `<text>` because
            `<span fg>` is dropped by this renderer: without it an empty field is
            an empty box, which is the state a person is most likely to read as
            "not waiting for me". */}
        <text fg={style.theme.accent.evolve} flexShrink={0}>
          {style.glyphs.meter[0]}
        </text>
      </box>
      <box flexDirection="column" width="100%" paddingLeft={2} paddingRight={1}>
        <DialogHint
          text="Enter connects · Esc cancels · password stays in memory only"
          width={screen().width}
        />
      </box>
    </box>
  )
}
