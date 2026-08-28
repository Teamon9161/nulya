/**
 * What shape the MOUSE POINTER is, over which part of the screen.
 *
 * Terminals draw their own default pointer over the whole window, and for most
 * of them that default is a text beam — so the pointer said "there is text to
 * select here" over the transcript, the tab bar, every clickable row, and the
 * composer alike. The one place it was telling the truth was the composer.
 *
 * The lever is OSC 22 (`ESC ] 22 ; <css-pointer-name> ST`), the sequence kitty
 * introduced and ghostty and wezterm follow; an EMPTY name means "back to your
 * own default". OpenTUI has an API for this (`renderer.setMousePointer`), but on
 * 0.5.3 — and on 0.5.9, checked — calling it emits nothing: the sequence is
 * written once at teardown and never for a request. So the bytes are written
 * here. They are three of them, they do not touch the cursor or any colour, and
 * a terminal that does not know OSC 22 ignores the whole string; landing
 * between two of OpenTUI's frames is therefore harmless.
 *
 * Nothing here asks whether the terminal supports it, because there is nothing
 * to do with the answer — and the last word is the person's terminal config
 * either way (kitty's `pointer_shape_when_grabbed`, ghostty's equivalent).
 */

/** CSS pointer names, the vocabulary OSC 22 speaks. */
export type Pointer = "default" | "text"

/**
 * The shape currently asked for. A pointer moving across a row of cells fires
 * over/out on every cell it crosses, and re-asking for the shape it already has
 * would put a sequence on the wire at mouse-move rate.
 */
let current: Pointer | null = null

/** Where the bytes go. Swapped in tests; `process.stdout` everywhere else. */
let sink: { write(bytes: string): unknown } = process.stdout

export function setPointerSink(next: { write(bytes: string): unknown }): void {
  sink = next
  current = null
}

export function pointer(shape: Pointer): void {
  if (shape === current) return
  current = shape
  write(shape)
}

/**
 * Hand the pointer back on the way out — the shape is the terminal's, not ours,
 * and a nulya that exited leaving every window with an arrow would be a nulya
 * that changed a setting it was only borrowing.
 */
export function releasePointer(): void {
  if (current === null) return
  current = null
  write("")
}

function write(name: string): void {
  // Only ever to a terminal: under `bun test` stdout is a pipe reading the
  // reporter's output, and a pointer shape has nothing to say to it.
  if (sink === process.stdout && !process.stdout.isTTY) return
  try {
    sink.write(`\x1b]22;${name}\x1b\\`)
  } catch {
    // A closed stdout is the shutdown path, and a pointer shape is not worth
    // a crash on the way out.
  }
}
