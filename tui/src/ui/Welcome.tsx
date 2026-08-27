/**
 * The first screen of an empty session (tui.md §4.1).
 *
 * A session with no events has nothing to show, and a blank rectangle above a
 * blank composer is the moment a person decides a tool is unfinished. So the
 * space says the three things that are true and useful right then: what nulya
 * is, where it is working, and the handful of keys that lead everywhere else.
 * It disappears the instant the first turn lands — it is a starting point, not
 * a panel.
 *
 * It is not a card: nothing here came from the ledger, and giving it a card
 * frame would put something in the transcript that no event backs. Since T24 it
 * also carries what the NEXT session will freeze, which used to be a composition
 * card in the future tense above it (T22). Two reasons it moved here:
 *
 *  - the MODEL was on that card and is also under the composer, three rows
 *    down, where the eye already is while typing. One fact, one place — and the
 *    status bar is the place that survives the first message.
 *  - the TOOLS row was a flex row of names, so a face of seven collapsed to
 *    `tools 1+6` — the same counts the status bar was already showing. Here it
 *    is a label column and the names WRAP, so a growing face grows downward
 *    instead of turning back into a number.
 *
 * The `/` lines are buttons as much as they are captions: a click runs
 * the command exactly as typing it would (`onCommand`), and the row takes the
 * same tint under the pointer as every other clickable row (`ui/rows.ts`).
 * Without the callback — a card rendered on its own — they are plain text and
 * do not light up.
 */
import { For, Show, createSignal } from "solid-js"
import { useScreen, useStyle } from "../render/theme.ts"
import { onClick } from "./rows.ts"
import { Fact, label_width } from "./Fact.tsx"
import { fit, wrapWords } from "./columns.ts"

/**
 * What the NEXT session will be told, on a tab that has not started one
 * (tui.md §11, T22/T24). It is not a header and it is not frozen — that is the
 * point of showing it: everything on it is still a decision, and `/model`,
 * `/ext` and `/with` are the three that move it.
 *
 * The model is deliberately NOT here: it is under the composer (`StatusBar`),
 * on the one line that keeps saying it once this screen is gone.
 */
export interface NextSession {
  /** The stable pin ids this TUI would pass as `--pin` (`ext:<id>/<tool>`). */
  tools: string[]
  /** `--with <id>[@<version>]`, when `/evolve` or `/with` set one. */
  bring?: string
}

/**
 * One of these shows per launch, picked at random (T38, tcode's `TIPS`).
 *
 * This is where a keyboard hint belongs. The row under the composer used to
 * carry `Esc cancel · Ctrl+O fold · /help` at all times, which is the worst of
 * both: a reminder that is always there stops being read after the first hour,
 * and it spent the busiest line on the screen to do it. A tip is read once, on
 * the screen that exists precisely because there is nothing else to look at.
 *
 * Every entry must describe behaviour that is real TODAY — a stale tip is worse
 * than no tip, because it is the one line a newcomer believes.
 */
const tips: string[] = [
  "Esc stops a running step · on an empty box it opens browse, where j/k walk the cards",
  "click a card's head line to open or close it · /fold closes all of them",
  "type while a step runs: the turn is queued and joins it at the next step boundary",
  "/model picks what the NEXT session runs on · ←→ on a row changes its effort",
  "/mode switches between asking about every tool call and not asking at all",
  "/compact hands this conversation to a fresh session with a summary in front",
  "/ext is the store: what is built, what is active, and which tools are pinned",
  "/agent delegates to a sub-agent in a tab of its own · bare /agent lists them",
  "shell {background:true} outlives the step · /tasks shows what is still running",
  "/outcome success|partial|failure records how a session went · nothing recorded is not failure",
  "Ctrl+C stops the step and never exits on the first press",
  "/sidebar docks the session list down the left edge · click a row twice to go there",
]

/** The tip for this launch. Picked once by the caller, never during a render. */
export function pickTip(random: () => number = Math.random): string {
  return tips[Math.min(tips.length - 1, Math.floor(random() * tips.length))]!
}

/** The `/` commands worth knowing before you have typed anything. */
const openings: Array<[string, string]> = [
  ["/model", "pick what the next session runs on"],
  ["/provider", "endpoints and their keys · add a compatible one"],
  ["/sessions", "everything in .nulya/sessions, and open one"],
  ["/ext", "extensions: versions, what is active, what it is used for"],
  ["/help", "every key and every command"],
]

export function Welcome(props: {
  /** The workspace whose `.nulya/` this session writes to. */
  cwd?: string
  /** What the first message will freeze, on a tab with no session yet. */
  plan?: NextSession
  /** A command row was clicked: run it as if it had been typed and sent. */
  onCommand?: (command: string) => void
  /**
   * The tip for this launch. Given rather than picked here so the screen does
   * not choose a different one every time it re-renders — a line that changes
   * under the eye while the eye is on it is not a tip, it is a distraction.
   */
  tip?: string
}) {
  const style = useStyle()
  const screen = useScreen()
  const wide = () => screen().width >= 60
  const [hovered, setHovered] = createSignal(-1)
  /** The width a value has beside its label, less the box's own left pad. */
  const valueWidth = () => Math.max(8, screen().width - 2 - label_width - 1)

  /**
   * The face the next session would carry. The one builtin is always there and
   * always first (DESIGN §5.1/§5.2); the pinned ones are the interesting half,
   * so only those carry the ⚡. A pin is a stable id (`ext:<ext>/<tool>`) and
   * the tool NAME is what the model calls, so that is what is drawn.
   */
  const tools = () => {
    const pinned = (props.plan?.tools ?? []).map((id) => `${style.glyphs.capability}${id.split("/").pop() ?? id}`)
    return ["shell", ...pinned].join(" ")
  }

  return (
    <box flexDirection="column" width="100%" paddingLeft={2} paddingTop={1}>
      <Show
        when={wide() && !style.settings.transcript.ascii}
        fallback={<text fg={style.theme.accent.user}>nulya</text>}
      >
        <ascii_font text="nulya" font="tiny" color={style.theme.accent.user} />
      </Show>
      <box height={1} />
      {/* The one sentence that says what this is: a level above the key list
          under it, which is a caption on the way out. */}
      <text fg={style.theme.muted}>an immutable kernel with one tool, and everything else it builds for itself</text>
      <box height={1} />

      {/* Where, and what with. The model is under the composer and stays there
          after this screen is gone, so it is not repeated here; the workspace
          and the face are the two facts nothing else on screen says at length. */}
      <Show when={props.cwd}>
        <Fact label="cwd" value={props.cwd!} width={valueWidth()} />
      </Show>
      <Show when={props.plan}>
        <Fact label="tools" value={tools()} width={valueWidth()} fg={style.theme.fg} />
        {/* A `--with` package is often nothing but a system prompt (a mode, an
            identity), and it lasts exactly one session — so the tab has to say
            it is wearing one before that session exists. */}
        <Show when={props.plan!.bring}>
          <Fact label="with" value={props.plan!.bring!} width={valueWidth()} fg={style.theme.accent.evolve} />
        </Show>
      </Show>
      <Show when={props.cwd || props.plan}>
        <box height={1} />
      </Show>

      <For each={openings}>
        {([command, what], index) => {
          const click = onClick(() => props.onCommand?.(command))
          const live = () => props.onCommand !== undefined
          return (
            <box
              flexDirection="row"
              width="100%"
              height={1}
              backgroundColor={live() && hovered() === index() ? style.theme.hover : undefined}
              onMouseDown={live() ? click.onMouseDown : undefined}
              onMouseUp={live() ? click.onMouseUp : undefined}
              onMouseOver={() => setHovered(index())}
              onMouseOut={() => setHovered((now) => (now === index() ? -1 : now))}
            >
              <box width={label_width} flexShrink={0}>
                <text fg={style.theme.accent.evolve}>{command}</text>
              </box>
              {/* Cut, never wrapped: a one-row box clips a second line, and a
                  caption that wraps re-lays itself under the pointer (`ui/columns.ts`). */}
              <text fg={style.theme.dim}>{fit(what, valueWidth())}</text>
            </box>
          )
        }}
      </For>
      <box height={1} />
      {/* Broken at its joints by us, so a narrow terminal gets two whole
          phrases rather than a line that folds mid-word. */}
      <For each={wrapWords(`${style.glyphs.user} type below and press Enter`, Math.max(20, screen().width - 3))}>
        {(line) => (
          <text fg={style.theme.dim} height={1}>
            {line}
          </text>
        )}
      </For>
      <box height={1} />
      {/* One key or command a launch, where a hint can be read once instead of
          living forever on the status line (T38). */}
      <box flexDirection="row" width="100%">
        <text fg={style.theme.accent.evolve} flexShrink={0}>
          {`${style.glyphs.tip} `}
        </text>
        <text fg={style.theme.dim}>{fit(`tip: ${props.tip ?? tips[0]!}`, Math.max(10, screen().width - 5))}</text>
      </box>
    </box>
  )
}
