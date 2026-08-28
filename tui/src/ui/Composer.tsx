import { For, Show, createEffect, createMemo, createSignal, onMount } from "solid-js"
import type { KeyEvent, PasteEvent, TextareaRenderable } from "@opentui/core"
import { SyntaxStyle } from "@opentui/core"
import { useScreen, useStyle } from "../render/theme.ts"
import { columnWidth, displayWidth, fit, squeeze, wrapWords } from "./columns.ts"
import { pointer } from "./pointer.ts"
import { builtin_names, completions } from "../commands.ts"
import {
  activeReference,
  knownReferenceRanges,
  referenceCompletions,
  type ProjectIndex,
  type ReferenceMatch,
} from "../references.ts"
import {
  describeAttachment,
  expandPastes,
  measure,
  pasteShouldFold,
  placeholderBefore,
  placeholderFor,
  placeholderRanges,
  referenced,
  type PasteAttachment,
} from "../paste.ts"
import { skillCompletions, type SkillTable } from "../skills.ts"
import { packageCompletions, resolve as resolvePackageCommands, type PackageCommandTable } from "../packageCommands.ts"
import { clipboardImage } from "../clipboard.ts"
import type { ImageInput } from "../nulya/cli.ts"

/**
 * The composer's border in ascii mode: the one bordered object on screen still
 * has to draw on a font without the box-drawing set (tui.md §6).
 */
const ascii_border = {
  topLeft: "+", topRight: "+", bottomLeft: "+", bottomRight: "+",
  horizontal: "-", vertical: "|",
  topT: "+", bottomT: "+", leftT: "+", rightT: "+", cross: "+",
}

/**
 * Rows a soft-wrapped buffer needs at `width` columns: greedy word wrap, a word
 * longer than the line broken across rows, and a trailing newline counted (the
 * cursor is on the row it opened). Ours rather than the textarea's because the
 * box is sized before the text inside it is laid out.
 */
export function wrappedRows(text: string, width: number): number {
  if (width <= 0) return 1
  let rows = 0
  for (const logical of text.split("\n")) {
    if (logical.length === 0) {
      rows += 1
      continue
    }
    let used = 0
    for (const word of logical.split(" ")) {
      const w = displayWidth(word)
      if (used === 0) {
        rows += 1
        used = w
      } else if (used + 1 + w <= width) {
        used += 1 + w
      } else {
        rows += 1
        used = w
      }
      while (used > width) {
        rows += 1
        used -= width
      }
    }
  }
  return Math.max(1, rows)
}

/**
 * The composer. Enter sends, Shift+Enter (or Ctrl+J, for terminals without the
 * Kitty protocol) makes a newline, Up on an empty buffer walks the history.
 * Sending while a step runs is allowed and does not interrupt it — the turn is
 * queued and the kernel drains it at its next step boundary (tui.md §4.4).
 *
 * A step ALREADY running can also be interrupted (agent-runner ar-t1): `App`
 * claims Ctrl+J for that at the screen level, but only while there is
 * something to interrupt or already queued — otherwise the key is left alone
 * and reaches the textarea's own newline binding above unchanged. That gesture
 * calls `ComposerApi.triggerInterrupt()` rather than reading the buffer itself,
 * so it goes through the exact same clear/history/paste-expansion path Enter
 * does; `onSubmit`'s second argument is the only thing that tells them apart.
 *

 * Two menus can appear above the box, and neither ever changes what Enter
 * means. A line beginning with `/` lists the matching commands; an `@` at a word
 * boundary lists project paths (tui.md §11, T13), where `↑↓` move the selection
 * and `Tab` accepts. Enter always sends exactly what is written, which is the
 * one promise an input box must not break — a menu that stole Enter would make
 * every message a gamble on what was highlighted.
 *
 * Both menus are tables, so both obey the list discipline: a path and a skill
 * description are as long as somebody else made them, and a menu row that wraps
 * repaints the transcript line above it through its own blanks
 * (`ui/columns.ts`). One row per candidate, cut to its column.
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
  /**
   * Throw away what is in the box. Ctrl+C's first meaning (tui.md §4.4): a
   * draft the user has decided against is a thing to cancel, and cancelling it
   * must not also be the thing that quits the program.
   */
  clear(): void
  /**
   * Put a submitted line back in the box, when the send could not happen at all
   * — a session that would not start (tui.md §11, T22). Never for a turn the
   * kernel accepted: that one is in the ledger, and a second copy in the
   * composer would invite it to be sent twice.
   */
  restore(text: string): void
  /**
   * Submit whatever is typed, flagged as the interrupt-and-deliver gesture
   * (agent-runner ar-t1). Goes through the exact same path Enter does — paste
   * expansion, history, clearing — so the only difference `onSubmit` sees is
   * the second argument; a global key handler outside the composer has no
   * other way to reach that path without duplicating it.
   */
  triggerInterrupt(): void
}

export interface ImageAttachment extends ImageInput {
  id: number
}

const imagePlaceholder = (id: number) => `[Image #${id}]`

export function Composer(props: {
  onSubmit: (text: string, interrupt?: boolean, images?: readonly ImageInput[]) => void
  /** Test seam; the real path asks the desktop clipboard on Ctrl+V. */
  readClipboardImage?: () => Promise<ImageInput | null>
  onNotice?: (text: string) => void
  /**
   * Enter on an empty composer. Returns true when it meant something — the
   * take-over gesture of observer mode (tui.md §5.6) — and false when Enter on
   * nothing should stay nothing.
   */
  onEmptySubmit?: () => boolean
  /**
   * The pointer landed in the input box. The textarea focuses itself (OpenTUI
   * walks up from the click for the first focusable renderable), but the screen
   * around it may be in a mode that owns the keyboard — browse — and only the
   * screen can leave it. Clicking where you type has to mean "type here".
   */
  onActivate?: () => void
  placeholder?: string
  /** The workspace's paths, for `@` completion. Absent means no `@` menu. */
  references?: ProjectIndex
  /** The skill catalog, listed after the built-in commands. */
  skills?: SkillTable
  /**
   * The package command catalog, listed after built-ins and before skills
   * (tui-plugin D1/D8) — resolved the same way dispatch resolves it
   * (`ui/App.tsx` `runPackageCommand`: built-ins never shadowed, a same-name
   * collision between two packages settled by scan order), so what this menu
   * offers is exactly what typing the name and pressing Enter would run.
   */
  packages?: PackageCommandTable
  /**
   * The commands loaded PLUGINS registered (tui-plugin U3). Listed before the
   * declared ones because dispatch tries them first — the same package's code
   * command supersedes its own manifest entry (`ui/App.tsx`
   * `runPluginCommand`).
   */
  pluginCommands?: () => readonly { name: string; description: string }[]
  /** The input remains visible, but cannot take focus while a full-screen overlay owns the keyboard. */
  disabled?: boolean
  onReady?: (api: ComposerApi) => void
}) {
  const style = useStyle()
  const screen = useScreen()
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
  const [at, setAt] = createSignal(0)
  const [pick, setPick] = createSignal(0)
  /**
   * Built-in commands first, then packages, then skills (tui.md §11, T15;
   * tui-plugin D1/D8) — the same order dispatch uses (`ui/App.tsx`
   * `runCommand` → `runPackageCommand` → `skillTurn`), so what the menu
   * offers first is what Enter would run.
   *
   * A skill sharing a name with a declared package command (e.g. `evolution`'s
   * `evolve` skill and its `/evolve` command) is not offered a second time: the
   * dispatch chain already picks the command first (`runPackageCommand` runs
   * before `skillTurn`), so listing both would show one entry the menu could
   * never actually reach.
   */
  const matches = (): { name: string; args?: string; what: string }[] => {
    const pluginRows = props.pluginCommands?.() ?? []
    const packageRows = resolvePackageCommands(props.packages?.entries() ?? [], builtin_names).winners
    const claimed = new Set([...pluginRows, ...packageRows].map((row) => row.name))
    return [
      ...completions(line()),
      ...packageCompletions(pluginRows, line()),
      ...packageCompletions(packageRows, line()),
      ...skillCompletions((props.skills?.entries() ?? []).filter((skill) => !claimed.has(skill.name)), line()),
    ]
  }

  /**
   * Folded pastes, by the number in their placeholder (tui.md §11, T14).
   *
   * Kept for the life of the composer rather than drained on submit, for the
   * same reason the message history is: a recalled draft has to still mean what
   * it said. An attachment leaves only when its token does — one Backspace on
   * the token drops both.
   */
  const [attachments, setAttachments] = createSignal<PasteAttachment[]>([])
  const [images, setImages] = createSignal<ImageAttachment[]>([])
  /**
   * Whether the keyboard is in the box. The border is the only thing on screen
   * that says so, and it has to say it: in browse mode and under an overlay the
   * composer is still visible, still full of text, and no longer listening.
   */
  const [focused, setFocused] = createSignal(!props.disabled)
  let nextAttachment = 1
  /** The ones the draft currently refers to — what the line under the box shows. */
  const drafted = () => referenced(line(), attachments())
  const draftedImages = () => images().filter((image) => line().includes(imagePlaceholder(image.id)))

  /**
   * The `@` menu. Recomputed from the buffer and the cursor on every change
   * rather than kept as state: a menu that outlives the token it belongs to is
   * how a completion lands in the wrong place.
   */
  const reference = () => {
    const index = props.references
    if (!index) return null
    const token = activeReference(line(), at())
    if (!token) return null
    index.touch()
    const found = referenceCompletions(index.candidates(), token.query, 8, (candidate) => index.size(candidate))
    return found.length > 0 ? { token, found } : null
  }

  /** The columns a menu may draw in: its box pads three left and one right. */
  const menu = () => Math.max(20, screen().width - 4)

  /** How a command names itself in the menu: the verb and its arguments. */
  const commandLabel = (command: { name: string; args?: string }) =>
    command.args ? `${command.name} ${command.args}` : command.name

  /**
   * The `/` menu's two columns. The name column is sized from the verbs it
   * lists — a skill's `/name` is whatever the package called it — and capped so
   * that the description beside it keeps something to say. The description is
   * one line, cut: a menu is a table, and a second row for one candidate is how
   * `↑↓` stops meaning "one candidate".
   */
  const commandCols = createMemo(() => {
    const [name, what] = squeeze(
      [columnWidth(matches().slice(0, 6).map(commandLabel), 2, 30), menu()],
      [10, 12],
      menu(),
    )
    return { name: name!, what: what! }
  })

  /** The same for `@`: a path is the column with no natural limit. */
  const referenceCols = (found: readonly ReferenceMatch[]) => {
    const [label, description] = squeeze(
      [columnWidth(found.map((match) => match.label), 2, 44), menu()],
      [10, 10],
      menu(),
    )
    return { label: label!, description: description! }
  }

  // The accent for a resolved `@path`, made on first use: a SyntaxStyle is a
  // renderer-side allocation, and a composer with no index never needs one.
  let accent: { style: SyntaxStyle; id: number } | null = null
  const referenceAccent = () => {
    if (!accent) {
      const made = SyntaxStyle.fromStyles({ reference: { fg: style.theme.accent.user } })
      accent = { style: made, id: made.getStyleId("reference") ?? 0 }
    }
    return accent
  }

  /**
   * Accent the tokens that stand for something: `@markers` that resolve to a
   * real path, and folded-paste placeholders. Redrawn from scratch on every
   * change, because the ranges are character offsets into a buffer that just
   * moved and keeping the old ones would light up the wrong words. An `@` in
   * front of an unrecognised word stays ordinary prose — that is what makes the
   * accent mean "this one resolves" rather than "you typed an at-sign".
   */
  const paintTokens = () => {
    if (!area) return
    area.clearAllHighlights()
    const text = area.plainText
    const spans = [
      ...(props.references ? knownReferenceRanges(text, props.references.candidates()) : []),
      ...placeholderRanges(text),
    ]
    if (spans.length === 0) return
    const paint = referenceAccent()
    if (!area.syntaxStyle) area.syntaxStyle = paint.style
    for (const range of spans) {
      area.addHighlightByCharRange({ start: range.start, end: range.end, styleId: paint.id })
    }
  }

  /**
   * How tall the box is: exactly what is in it (T26).
   *
   * It used to be three rows always, so two of them were blank on every screen
   * anybody ever looks at, and a twelve-line paste scrolled inside a window of
   * three. The count is ours rather than the textarea's because the box has to
   * be sized BEFORE the text is laid out, and it is capped: past eight rows the
   * composer would start eating the transcript, and the textarea scrolls.
   *
   * The width is the row's own: two columns of border, two of padding, two for
   * the `›` and its space.
   */
  const rows = () => Math.min(8, Math.max(1, wrappedRows(line(), Math.max(8, screen().width - 6))))

  const sync = () => {
    setLine(area?.plainText ?? "")
    setAt(area?.cursorOffset ?? 0)
    setPick(0)
    paintTokens()
  }

  /**
   * A bracketed paste. Short ones go in as they always did; a long one becomes
   * `[Pasted text #N]` and the text is kept beside the draft, so a thousand-line
   * stack trace does not bury the screen and the draft stays editable.
   *
   * `preventDefault()` is what stops the textarea from inserting the bytes
   * itself: this listener runs first, and the default insert is skipped once
   * the event is claimed.
   */
  const onPaste = (event: PasteEvent) => {
    if (props.disabled) {
      event.preventDefault()
      return
    }
    const text = new TextDecoder().decode(event.bytes)
    const size = measure(text)
    if (!pasteShouldFold(size.chars, size.lines)) {
      // The textarea will insert it; the mirror has to follow, or the buffer and
      // everything derived from it (the menus, the box's own height) go on
      // describing what was there before the paste. Keystrokes sync through
      // `onKeyDown`, and a paste is the one way in that is not a keystroke —
      // which is also how an IME commits a phrase (T26).
      queueMicrotask(sync)
      return
    }
    event.preventDefault()
    const attachment: PasteAttachment = { id: nextAttachment++, text, ...size }
    setAttachments([...attachments(), attachment])
    area?.insertText(placeholderFor(attachment.id))
    sync()
  }

  const pasteImage = async () => {
    const image = await (props.readClipboardImage ?? clipboardImage)()
    if (!image) {
      props.onNotice?.("the clipboard has no PNG or JPEG image · text paste still uses your terminal")
      return
    }
    const attachment: ImageAttachment = { id: nextAttachment++, ...image }
    setImages([...images(), attachment])
    area?.insertText(imagePlaceholder(attachment.id))
    sync()
  }

  /**
   * Backspace right after a placeholder takes the whole token. Without this it
   * would chew the `]` off and leave a shape that no longer stands for
   * anything — visibly text, silently still an attachment.
   */
  const backspaceAttachment = (): boolean => {
    if (!area) return false
    const found = placeholderBefore(area.plainText, area.cursorOffset, attachments())
    const image = images().find((entry) => area!.plainText.slice(0, area!.cursorOffset).endsWith(imagePlaceholder(entry.id)))
    if (!found && !image) return false
    const token = found ? placeholderFor(found.id) : imagePlaceholder(image!.id)
    area.setSelection(area.cursorOffset - [...token].length, area.cursorOffset)
    area.deleteSelection()
    if (found) setAttachments(attachments().filter((entry) => entry.id !== found.id))
    if (image) setImages(images().filter((entry) => entry.id !== image.id))
    sync()
    return true
  }

  createEffect(() => {
    if (!area) return
    area.focusable = !props.disabled
    if (props.disabled) {
      area.blur()
      setFocused(false)
    }
  })

  onMount(() => {
    if (!props.disabled) area?.focus()
    props.onReady?.({
      isEmpty: () => (area?.plainText ?? "").length === 0,
      focus: () => {
        if (props.disabled) return
        area?.focus()
        setFocused(true)
      },
      blur: () => {
        area?.blur()
        setFocused(false)
      },
      clear: () => {
        clear()
        // The draft is gone, so the attachments it referred to are nobody's:
        // leaving them would keep a thousand folded lines alive behind an empty
        // box, and the next `[Pasted text #1]` would stand for the old one.
        setAttachments([])
        setImages([])
        shown = null
      },
      restore: (text: string) => {
        // Only into a box the user has not started refilling: they typed the
        // next thing while the refusal was in flight, and that is theirs.
        if (!area || area.plainText.length > 0) return
        area.insertText(text)
        sync()
      },
      triggerInterrupt: () => submit(true),
    })
  })

  const clear = () => {
    if (!area) return
    area.selectAll()
    area.deleteSelection()
    sync()
  }

  const submit = (interrupt = false) => {
    const text = area?.plainText ?? ""
    clear()
    shown = null
    const sentImages = images().filter((image) => text.includes(imagePlaceholder(image.id)))
    if (text.trim().length === 0 && sentImages.length === 0) {
      props.onEmptySubmit?.()
      return
    }
    // The history keeps the draft as it was on screen — placeholders and all —
    // so recalling it shows what was typed rather than the thousand lines it
    // stood for. The expansion happens only on the way out. Image tokens are UI
    // handles; the image blocks themselves carry that content to the model.
    history.push(text)
    cursor = history.length
    let expanded = expandPastes(text, attachments())
    for (const image of sentImages) expanded = expanded.split(imagePlaceholder(image.id)).join("")
    props.onSubmit(expanded, interrupt, sentImages)
  }

  /**
   * Put a chosen path in place of the token being typed. The `@path` is all
   * that goes in — the file's contents are the model's to fetch (D5).
   */
  const acceptReference = (match: ReferenceMatch, start: number, end: number): void => {
    if (!area) return
    area.setSelection(start, end)
    area.deleteSelection()
    area.insertText(`${match.replacement} `)
    sync()
  }

  /** Tab on a half-typed command finishes it, with a space ready for arguments. */
  const complete = (): boolean => {
    const open = reference()
    if (open) {
      const match = open.found[Math.min(pick(), open.found.length - 1)]
      if (!match) return false
      acceptReference(match, open.token.start, open.token.end)
      return true
    }
    const best = matches()[0]
    if (!best || best.name === line()) return false
    clear()
    area?.insertText(best.args ? `${best.name} ` : best.name)
    sync()
    return true
  }

  const onKeyDown = (event: KeyEvent) => {
    if (props.disabled) {
      event.preventDefault()
      return
    }
    if (event.name === "v" && event.ctrl) {
      event.preventDefault()
      void pasteImage()
      return
    }
    if (event.name === "tab") {
      if (complete()) event.preventDefault()
      return
    }
    if (event.name === "backspace") {
      if (backspaceAttachment()) event.preventDefault()
      else queueMicrotask(sync)
      return
    }
    // While the `@` menu is up, Up/Down move the selection — and only then. On
    // every other buffer they stay what a multi-line editor owes its user.
    const open = reference()
    if (open && (event.name === "up" || event.name === "down")) {
      const delta = event.name === "down" ? 1 : -1
      setPick(Math.min(Math.max(pick() + delta, 0), open.found.length - 1))
      event.preventDefault()
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
      <Show when={reference()} keyed>
        {(open: NonNullable<ReturnType<typeof reference>>) => {
          const cols = () => referenceCols(open.found)
          return (
            <box flexDirection="column" width="100%" paddingLeft={3} paddingRight={1}>
              <For each={open.found}>
                {(match, index) => (
                  <box flexDirection="row" width="100%" height={1} flexShrink={0}>
                    <box width={cols().label} flexShrink={0}>
                      <text fg={index() === pick() ? style.theme.accent.user : style.theme.muted}>
                        {fit(match.label, cols().label - 2)}
                      </text>
                    </box>
                    <text fg={style.theme.dim}>{fit(match.description, cols().description)}</text>
                  </box>
                )}
              </For>
              <For each={wrapWords("↑↓ pick · Tab inserts the path · Enter sends what is written", menu() - 2)}>
                {(line) => (
                  <text fg={style.theme.dim} height={1}>
                    {"  "}
                    {line}
                  </text>
                )}
              </For>
            </box>
          )
        }}
      </Show>
      <Show when={!reference() && matches().length > 0}>
        <box flexDirection="column" width="100%" paddingLeft={3} paddingRight={1}>
          <For each={matches().slice(0, 6)}>
            {(command, index) => (
              <box flexDirection="row" width="100%" height={1} flexShrink={0}>
                <box width={commandCols().name} flexShrink={0}>
                  <text fg={index() === 0 ? style.theme.accent.evolve : style.theme.muted}>
                    {fit(commandLabel(command), commandCols().name - 2)}
                  </text>
                </box>
                <text fg={style.theme.dim}>{fit(command.what, commandCols().what)}</text>
              </box>
            )}
          </For>
          <Show when={matches().length > 1}>
            <For each={wrapWords("Tab completes · Enter sends what is written", menu() - 2)}>
              {(line) => (
                <text fg={style.theme.dim} height={1}>
                  {"  "}
                  {line}
                </text>
              )}
            </For>
          </Show>
        </box>
      </Show>
      {/* What each placeholder in the draft stands for. A fold that did not say
          how much it folded would be a fold that hid something. */}
      <Show when={drafted().length > 0 || draftedImages().length > 0}>
        <box flexDirection="column" width="100%" paddingLeft={3} paddingRight={1}>
          <For each={drafted()}>
            {(attachment) => <text fg={style.theme.dim}>{describeAttachment(attachment)}</text>}
          </For>
          <For each={draftedImages()}>
            {(image) => <text fg={style.theme.dim}>{`${imagePlaceholder(image.id)} · ${image.mediaType} · ${Math.ceil(image.bytes.length / 1024)} KB`}</text>}
          </For>
        </box>
      </Show>
      {/*
        flexShrink={0}: the composer is the one thing on screen that must never
        be squeezed. Without it a long transcript (or a long overlay list) wins
        the flex negotiation and the input box collapses to a line, then to
        nothing — the screen still works, but there is visibly nowhere to type.

        onMouseOver/onMouseOut: the mouse pointer says which of the two things
        under it is true — text to type into here, an interface to click
        everywhere else (`ui/pointer.ts`).
      */}
      <box
        flexDirection="row"
        width="100%"
        flexShrink={0}
        border
        borderStyle={style.settings.transcript.ascii ? "single" : "rounded"}
        customBorderChars={style.settings.transcript.ascii ? ascii_border : undefined}
        borderColor={focused() ? style.theme.accent.user : style.theme.hairline}
        paddingLeft={1}
        paddingRight={1}
        onMouseDown={() => {
          if (!props.disabled) props.onActivate?.()
        }}
        onMouseOver={() => pointer("text")}
        onMouseOut={() => pointer("default")}
      >
        {/* `flexShrink={0}`, or a buffer wide enough to fill the row wins the
            flex negotiation and the prompt glyph is squeezed out of existence —
            the text then starts one column left of where its own wrapped
            continuation lines do. */}
        <text fg={style.theme.accent.user} flexShrink={0}>
          {style.glyphs.user}{" "}
        </text>
        <textarea
          ref={area}
          flexGrow={1}
          height={rows()}
          wrapMode="word"
          placeholder={props.placeholder ?? "message nulya  ·  / for commands  ·  @ for files"}
          placeholderColor={style.theme.dim}
          textColor={style.theme.fg}
          focusedTextColor={style.theme.fg}
          cursorColor={style.theme.accent.user}
          selectionBg={style.theme.selection}
          // `submit` now takes an `interrupt` flag (ar-t1); the textarea's own
          // Enter binding must not pass its `SubmitEvent` into that slot.
          onSubmit={() => submit()}
          onKeyDown={onKeyDown}
          onPaste={onPaste}
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
