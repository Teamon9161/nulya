/**
 * The first screen of an empty session.
 *
 * A session with no events has nothing to show, and a blank rectangle above a
 * blank composer is the moment a person decides a tool is unfinished. So the
 * space says the three things that are true and useful right then: what nulya
 * is, where it is working, and the handful of keys that lead everywhere else.
 * It disappears the instant the first turn lands — it is a starting point, not
 * a panel.
 *
 * It is not a card: nothing here came from the ledger, and giving it a card
 * frame would put something in the transcript that no event backs. It
 * also carries what the NEXT session will freeze. Two reasons it lives here
 * rather than on a composition card of its own:
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
import { useScreen, useStyle, type Glyphs } from "../render/theme.ts"
import { lifted, onClick } from "./rows.ts"
import { Fact, label_width } from "./Fact.tsx"
import { fit, wrapWords } from "./columns.ts"

/**
 * What the NEXT session will be told, on a tab that has not started one
 *. It is not a header and it is not frozen — that is the
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
 * One of these shows per launch, picked at random (tcode's `TIPS`).
 *
 * This is where a keyboard hint belongs. The row under the composer used to
 * carry `Esc cancel · Ctrl+O fold · /help` at all times, which is the worst of
 * both: a reminder that is always there stops being read after the first hour,
 * and it spent the busiest line on the screen to do it. A tip is read once, on
 * the screen that exists precisely because there is nothing else to look at.
 *
 * Every entry must describe behaviour that is real TODAY — a stale tip is worse
 * than no tip, because it is the one line a newcomer believes.
 *
 * Built from the glyph set rather than written out, because one of them names a
 * glyph and this front end has a byte-for-byte ascii fallback for every
 * one of those (§6.3). A tip that printed `◧` on a terminal that draws `[` would
 * be pointing at a control that is not there.
 */
function tipsOf(glyphs: Glyphs): string[] {
  return [
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
    "/env runs the next session's shell in WSL, or moves the whole workspace elsewhere with remote:… · bare /env lists what this machine can reach",
    "the settings screen names every key tui.toml takes, and what each one accepts",
    // Alt+V is named FIRST on purpose: Ctrl+V reaches this application only on
    // terminals that do not paste on it themselves, and the people who most
    // need to know a picture can be pasted are the ones whose terminal quietly
    // took that key. A right click needs no key at all, and is named beside
    // the two that do for the same reason (`ui/Composer.tsx` onMouseDown).
    "Alt+V (or Ctrl+V, or right-click the box) pastes what is on the desktop clipboard, a picture included",
    // The route that needs no key at all, and therefore the one that works on
    // the terminals where the tip above cannot help.
    "paste or drag the path of a .png or .jpg and the picture goes in, not the path",
    // Three ways into one pane, in one line. The handle is named as well
    // as pointed at: it is the only one of the three that can be seen without
    // already knowing it is there, and the only one that needs teaching.
    `/sidebar or F8 docks the session list down the left edge · so does the ${glyphs.sidebar} at the start of the line below`,
    "in the session list a click goes to that session here · a double click gives it a tab of its own",
  ]
}

/**
 * The tip for this launch. Picked once by the caller, never during a render.
 *
 * The glyph set is required rather than defaulted to the unicode one: a default
 * here would be a second place that decides what `◧` is drawn as, and the whole
 * point of taking the argument is that there is only one.
 */
export function pickTip(glyphs: Glyphs, random: () => number = Math.random): string {
  const all = tipsOf(glyphs)
  return all[Math.min(all.length - 1, Math.floor(random() * all.length))]!
}

/** The `/` commands worth knowing before you have typed anything. */
const openings: Array<[string, string]> = [
  ["/model", "pick what the next session runs on"],
  ["/provider", "endpoints and their keys · add a compatible one"],
  // Two ways into one list, on the row that is about that list. The rail
  // does not get a row of its own: it would be the same content twice on a
  // screen whose whole job is to be short, and this is the row a person reads
  // when they are looking for their other conversations anyway.
  ["/sessions", "every session here · /sidebar docks the same list on the left"],
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
  /**
   * The `cwd` row is a control: clicking it opens the directory browser
   * (goals/tui-shell.md §5.3b point 2). It is here rather than anywhere else
   * because this is the screen a tab shows while its directory is still a
   * DECISION — the row was already saying which directory, and the only thing
   * it was missing was that you can change it.
   *
   * Without the callback — a card rendered on its own, a test — it is the
   * plain fact it always was and does not light up, exactly as the `/` rows
   * below behave without `onCommand`.
   */
  onPickCwd?: () => void
  /**
   * Where this session's `shell` commands would run — always a
   * value, `this machine` included, because on THIS screen that is a decision
   * and not a fact. The status line under it is the opposite case and stays
   * silent about the ordinary answer: there the target is frozen, and a chip
   * that always said the same thing would not be information.
   *
   * It is the second half of the pair the `cwd` row starts: where the files
   * are, and where the commands go. A click opens the picker, exactly as the
   * `cwd` row above opens the directory browser.
   */
  shell?: string
  onPickEnv?: () => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const wide = () => screen().width >= 60
  const [hovered, setHovered] = createSignal(-1)
  /**
   * The `cwd` row's slot in the same hover signal the command rows use. A
   * negative index because those are 0..n over `openings` and this row is not
   * one of them — one signal, so two rows can never be lit at once.
   */
  const cwd_row = -2
  const shell_row = -3
  /** The width a value has beside its label, less the box's own left pad. */
  const valueWidth = () => Math.max(8, screen().width - 2 - label_width - 1)

  /**
   * The face the next session would carry. The one builtin is always there and
   * always first; the pinned ones are the interesting half,
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
        {(() => {
          const click = onClick(() => props.onPickCwd?.())
          const live = () => props.onPickCwd !== undefined
          return (
            <box
              flexDirection="column"
              width="100%"
              onMouseDown={live() ? click.onMouseDown : undefined}
              onMouseUp={live() ? click.onMouseUp : undefined}
              onMouseOver={() => setHovered(cwd_row)}
              onMouseOut={() => setHovered((now) => (now === cwd_row ? -1 : now))}
            >
              <Fact
                label="cwd"
                value={props.cwd!}
                width={valueWidth()}
                fg={lifted(style, live() && hovered() === cwd_row, style.theme.muted)}
              />
            </box>
          )
        })()}
      </Show>
      <Show when={props.shell}>
        {(() => {
          const click = onClick(() => props.onPickEnv?.())
          const live = () => props.onPickEnv !== undefined
          return (
            <box
              flexDirection="column"
              width="100%"
              onMouseDown={live() ? click.onMouseDown : undefined}
              onMouseUp={live() ? click.onMouseUp : undefined}
              onMouseOver={() => setHovered(shell_row)}
              onMouseOut={() => setHovered((now) => (now === shell_row ? -1 : now))}
            >
              {/* Warn-coloured when it is not this machine, the same as the chip
                  that reports it once this screen is gone: it is the fact that
                  makes `rm -rf build` two different acts. */}
              <Fact
                label="shell"
                value={props.shell!}
                width={valueWidth()}
                fg={lifted(
                  style,
                  live() && hovered() === shell_row,
                  props.shell === "this machine" ? style.theme.muted : style.theme.warn,
                )}
              />
            </box>
          )
        })()}
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
      <Show when={props.cwd || props.shell || props.plan}>
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
              onMouseDown={live() ? click.onMouseDown : undefined}
              onMouseUp={live() ? click.onMouseUp : undefined}
              onMouseOver={() => setHovered(index())}
              onMouseOut={() => setHovered((now) => (now === index() ? -1 : now))}
            >
              <box width={label_width} flexShrink={0}>
                <text fg={lifted(style, live() && hovered() === index(), style.theme.accent.evolve)}>{command}</text>
              </box>
              {/* Cut, never wrapped: a one-row box clips a second line, and a
                  caption that wraps re-lays itself under the pointer (`ui/columns.ts`). */}
              <text fg={lifted(style, live() && hovered() === index(), style.theme.dim)}>
                {fit(what, valueWidth())}
              </text>
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
          living forever on the status line. */}
      <box flexDirection="row" width="100%">
        <text fg={style.theme.accent.evolve} flexShrink={0}>
          {`${style.glyphs.tip} `}
        </text>
        <text fg={style.theme.dim}>{fit(`tip: ${props.tip ?? tipsOf(style.glyphs)[0]!}`, Math.max(10, screen().width - 5))}</text>
      </box>
    </box>
  )
}
