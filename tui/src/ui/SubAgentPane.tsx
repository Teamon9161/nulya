/**
 * A delegation, watched inside the conversation that made it
 * (goals/tui-shell.md §5.3c, tui.md §5.5, T72).
 *
 * The whole surface is three things: a line saying whose work this is, the
 * hairline that attaches it to the pane it split off from, and the same
 * `Transcript` the tab itself draws. Nothing here is a second way of showing a
 * session — it is the observer view this front end already had (tui.md §5.6),
 * put in a pane instead of a tab.
 *
 * WHY IT SAYS SO IN A LINE OF ITS OWN. Two transcripts on one screen is the
 * first time this front end has ever been ambiguous about whose words are
 * whose, and position alone does not answer it: which half is the delegation
 * depends on a terminal's width. So the pane leads with attribution — the
 * sub-session glyph, the persona, the delegation's own id, and the one word
 * that says this half cannot be typed into.
 *
 * WHY THE RULE. §6.1 keeps box-drawing for when ownership has to be said out
 * loud, and this is that case: the sidebar's boundary separates two independent
 * places (air is enough, T69), while this one says CONTAINED IN. It is one
 * side, never four — a frame would make the pane look like a control, and this
 * front end still has exactly one bordered object (the composer).
 */
import { Show, createMemo, createSignal } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { ScrollBoxRenderable } from "@opentui/core"
import { Transcript } from "./Transcript.tsx"
import { BodyWidthContext, useStyle } from "../render/theme.ts"
import { onClick } from "./rows.ts"
import { fit } from "./columns.ts"
import { personaOf } from "../agents.ts"
import { TasksContext } from "../state/tasks.ts"
import type { SplitDirection } from "../pane/tree.ts"
import type { SubView } from "../state/tabs.ts"

/** The ascii border set, one side of it. The composer's discipline (T4). */
const ascii_border = {
  topLeft: "+",
  topRight: "+",
  bottomLeft: "+",
  bottomRight: "+",
  horizontal: "-",
  vertical: "|",
  topT: "+",
  bottomT: "+",
  leftT: "+",
  rightT: "+",
  cross: "+",
}

/**
 * The attribution line, as text (T72).
 *
 * A pure function so the one sentence this pane makes can be asserted without a
 * terminal: `⤷ explore · find the writers · observing`. The persona comes from
 * the watched session's own frozen header through `personaOf` — the SAME
 * reading the sessions list filters delegated conversations by (T70) — so a
 * pane and a row cannot disagree about which agent a session is; `label` is
 * `SubSessionCard`'s task excerpt, not the delegation's `d-…` id (id-vs-task
 * readability pass) — the persona already says which agent, so the label says
 * what for instead of repeating it.
 */
export function attributionOf(input: { persona: string | null; label: string }): string {
  // The glyph is not in here: it is the line's gutter (§6.5, "content from
  // column 3"), and what this function is for is the sentence.
  //
  // `observing` is CONSTANT, and that is a decision rather than an omission.
  // It describes THIS PANE — read-only by construction, with no composer under
  // it and nothing here that can say a word to the conversation it is watching
  // — not the writer lease, which is a fact about the world that comes and
  // goes (`state/attach.ts`). A line that turned into `driving` the moment the
  // background task finished would be answering a question nobody asked here,
  // with a word that reads as permission.
  const parts = [input.persona, input.label, "observing"]
  return parts.filter((part): part is string => typeof part === "string" && part.length > 0).join(" · ")
}

export function SubAgentPane(props: {
  view: SubView
  /** What the delegation calls itself (`d-…`), when the card knew it. */
  label?: string
  /** Which way the split that holds this pane divides (`state/subpanes.ts`). */
  direction: SplitDirection
  focused: boolean
  onClose: () => void
  width: number
}) {
  const style = useStyle()
  const [hovered, setHovered] = createSignal(false)
  let scroll: ScrollBoxRenderable | null = null

  const persona = createMemo(() => personaOf(props.view.state.snapshot.header?.composition.prompts ?? []))
  const attribution = () => attributionOf({ persona: persona(), label: props.label ?? props.view.id })

  const close = onClick(() => props.onClose(), true)

  /**
   * The keys, only while this pane holds them.
   *
   * `useKeyboard` is global, so a surface that listens unconditionally fires
   * alongside every other one on screen — the rule T69 wrote down for the
   * docked rail, and the same one a package's T2 face will have to follow.
   * Read-only: the vocabulary is scrolling and leaving, and nothing here can
   * say anything to the conversation it is watching.
   */
  useKeyboard((key) => {
    if (!props.focused) return
    if (key.name === "escape") return props.onClose()
    const page = Math.max(1, (scroll?.viewport?.height ?? 10) - 2)
    if (key.name === "j" || key.name === "down") return void scroll?.scrollBy({ x: 0, y: 1 })
    if (key.name === "k" || key.name === "up") return void scroll?.scrollBy({ x: 0, y: -1 })
    if (key.name === "pagedown") return void scroll?.scrollBy({ x: 0, y: page })
    if (key.name === "pageup") return void scroll?.scrollBy({ x: 0, y: -page })
    if (key.name === "end") return void scroll?.scrollTo({ x: 0, y: scroll.scrollHeight })
  })

  // Cells the rule and the padding take, so the line is cut to what is left
  // rather than wrapped (§6.1 rule 7).
  const room = () => Math.max(8, props.width - 4)

  return (
    <box
      flexDirection="column"
      flexGrow={1}
      flexShrink={1}
      width="100%"
      // One side, on the side the seam is: a row split puts the neighbour to
      // the left of this pane, a column split puts it above.
      border={props.direction === "row" ? ["left"] : ["top"]}
      borderColor={style.theme.hairline}
      customBorderChars={style.settings.transcript.ascii ? ascii_border : undefined}
      // One cell of air after a vertical rule, and none after a horizontal
      // one: stacked, the two transcripts must share a left edge (§6.5's "one
      // left edge per box" read across the seam — a one-column offset between
      // two lists of the same shape is the ragged edge that rule exists for).
      paddingLeft={props.direction === "row" ? 1 : 0}
    >
      <box
        flexDirection="row"
        width="100%"
        height={1}
        flexShrink={0}
        onMouseOver={() => setHovered(true)}
        onMouseOut={() => setHovered(false)}
      >
        {/* `accent.evolve` on the glyph alone, `dim` on the words: this line is
            ABOUT the pane rather than anything that happened in it (§6.2), and
            the transcript under it keeps the brightest text on screen. */}
        <text fg={style.theme.accent.evolve} flexShrink={0}>
          {style.glyphs.subSession}{" "}
        </text>
        <text fg={style.theme.dim} flexShrink={0}>
          {fit(attribution(), room())}
        </text>
        <box flexGrow={1} />
        {/* The same word the tab strip uses for the same act (T70): a button
            named after what it does. `faint` until the pointer is on it —
            the only control in this pane that loses something. */}
        <text
          fg={hovered() ? style.theme.err : style.theme.faint}
          flexShrink={0}
          onMouseDown={close.onMouseDown}
          onMouseUp={close.onMouseUp}
        >
          {style.glyphs.closeTab}
        </text>
      </box>

      {/* THIS session's background tasks, not the parent's. A card asking how
          long a background command has been going looks the task up by full
          name (`<sid>/tN`), so the parent's projection would simply never
          match and every such card would fall back to the ledger — honest, but
          a poll running for nobody. The pane is a session view like any other,
          so it brings its own (tui.md §5.9). */}
      <TasksContext.Provider value={props.view.tasks.tasks}>
        {/* No `onCommand`, no `cwd`, no `plan`: this transcript has no composer
            under it, so it makes no offers. The welcome screen is the
            composer's invitation and stays out of here by that fact alone
            (`Transcript`). Cards wrap at THIS pane's width, not the
            terminal's (`BodyWidthContext`, BUGS.md #17). */}
        <BodyWidthContext.Provider value={() => props.width}>
          <Transcript
            items={props.view.state.snapshot.items}
            header={props.view.state.snapshot.header}
            contributions={props.view.contributions()}
            highlightedCallId={props.view.state.snapshot.highlightedToolCallId}
            error={props.view.state.snapshot.error}
            ref={(box) => (scroll = box)}
          />
        </BodyWidthContext.Provider>
      </TasksContext.Provider>

      {/* One dim line of "what can I do here", like every other face (§6.1
          rule 8) — and only while the keys it names are true. */}
      <Show when={props.focused}>
        <text fg={style.theme.dim} height={1} flexShrink={0}>
          {fit("j/k · PgUp/PgDn · Esc closes", room())}
        </text>
      </Show>
    </box>
  )
}
