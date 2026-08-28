import { ErrorBoundary, Index, Match, Show, Switch, createMemo } from "solid-js"
import type { ScrollBoxRenderable } from "@opentui/core"
import { Card } from "../render/cards/index.tsx"
import { RunCard } from "../render/cards/RunCard.tsx"
import { describeTool } from "../render/registry.ts"
import { foldsIntoRun, groupRuns, type TranscriptRow } from "../render/runs.ts"
import { usePlugins } from "../plugins/context.ts"
import { CompositionCard } from "../render/cards/CompositionCard.tsx"
import { ErrorNotice } from "../render/cards/ErrorNotice.tsx"
import { Welcome, type NextSession } from "./Welcome.tsx"
import { useStyle, type Style } from "../render/theme.ts"
import { renderHintOf, type Contributions } from "../nulya/files.ts"
import type { SessionHeader } from "../nulya/ledger.ts"
import type { ToolItem, TranscriptItem } from "../state/session.ts"
import type { ThinkingDefault } from "../state/settings.ts"

/**
 * The transcript: a sticky-bottom scrollbox, no borders, content capped at
 * `max_width` and left aligned (tui.md §1.2 D1/D9, §6). Cards are keyed by the
 * item key so a streaming turn updates in place instead of being rebuilt.
 *
 * The composition card leads because it is the frame everything else happened
 * inside (tui.md §5.1); it comes from the header, which is not an event, so it
 * sits outside the item list rather than being faked into it.
 */
/**
 * The tail that gets mounted. `viewportCulling` skips the RENDER of offscreen
 * children, but every mounted card still costs layout on every frame, so a
 * 5k-event session would pay for 5000 boxes to draw one screenful. The ledger
 * file keeps the whole history either way, and `history_window = 0` mounts all
 * of it (tui.md §11, T4).
 */
export function windowItems(items: readonly TranscriptItem[], window: number): TranscriptItem[] {
  if (window <= 0 || items.length <= window) return items as TranscriptItem[]
  return items.slice(-window)
}

/**
 * What is on screen at all (T43). `thinking = "hidden"` — the default — is not
 * "draw an empty card": an item that draws nothing still takes its place in the
 * rhythm, and it would leave the blank row `gapBefore` puts in front of it. So
 * the item leaves the LIST, and everything downstream — the gaps, the browse
 * selection, the `N earlier items` count — is computed over what is actually
 * drawn.
 */
export function visibleItems(items: readonly TranscriptItem[], thinking: ThinkingDefault): TranscriptItem[] {
  if (thinking !== "hidden") return items as TranscriptItem[]
  return items.filter((item) => item.kind !== "thinking")
}

/**
 * Blank rows before an item — the transcript's whole vertical rhythm, in one
 * pure function (T26).
 *
 * A turn is not a list of events, it is a handful of BEATS: the person says
 * something, the model thinks and answers, the model does a run of things, the
 * kernel reports. Between visible records there is exactly one blank row, with
 * one extra row before a new user message so the exchange boundary is louder.
 * Before this, `marginTop` lived on two cards and tool cards had none, so a
 * run of edit calls was welded into one slab and the screen had no grain at
 * all.
 *
 * Thinking used to be welded to the answer under it — same beat, no gap. On
 * screen that was two CARDS with nothing between them (T43): a head line with
 * its own glyph and fold marker, and then a markdown body starting on the very
 * next row. "Belongs to" is already said by the order and by the dim; a beat
 * boundary is what a blank row means everywhere else on this screen, and
 * thinking is one. When it is hidden — the default since T43 — there is no
 * second card and nothing to separate.
 */
export function gapBefore(previous: TranscriptItem | undefined, item: TranscriptItem): number {
  // The first item follows the composition card or the welcome screen; one row
  // of air separates it from either.
  if (!previous) return 1
  if (previous.kind === "tool" && item.kind === "tool") return 1
  // A person speaking starts a new exchange, not just a new beat: two rows, so
  // the grain of the screen says where one question ended and the next began.
  if (item.kind === "user") return 2
  return 1
}

/**
 * ITEMS → ROWS, the whole projection: what is on screen, how much of it is
 * mounted, and which calls have been gathered into a run (T43).
 *
 * One implementation, two callers — the transcript draws these rows and browse
 * mode walks them. Two would be two answers to "is that call on screen", and
 * browse would put its cursor on a card nobody can see.
 */
export function transcriptRows(
  items: readonly TranscriptItem[],
  style: Style,
  contributions: readonly Contributions[],
  drawnByPlugin?: (tool: string) => boolean,
): TranscriptRow[] {
  const shown = windowItems(visibleItems(items, style.settings.transcript.thinking), style.historyWindow)
  const folds = (item: ToolItem) => {
    const render = renderHintOf(contributions, item.tool)
    return foldsIntoRun({
      item,
      kind: describeTool({ tool: item.tool, args: item.args, output: item.output }, style.glyphs, { render }).kind,
      render,
      drawnByPlugin: drawnByPlugin?.(item.tool) ?? false,
    })
  }
  return groupRuns(shown, folds, style.settings.transcript.run_summary)
}

/**
 * The item a row's rhythm is computed from. A run stands in for the calls it
 * holds — it IS those calls — so a run next to a call the summary would not
 * take (a failure, an edit) still reads as one block, which is what it is.
 */
function rowSubject(row: TranscriptRow | undefined): TranscriptItem | undefined {
  if (!row) return undefined
  return row.kind === "item" ? row.item : row.items[0]
}

/** An item row's item, for prop getters — read where the getter runs. */
function itemOf(row: TranscriptRow): TranscriptItem {
  return (row as Extract<TranscriptRow, { kind: "item" }>).item
}

export function capabilityPreviousVersions(
  items: readonly TranscriptItem[],
  header?: SessionHeader | null,
): Map<string, string | null> {
  const current = new Map<string, string>()
  for (const entry of header?.composition.active ?? []) current.set(entry.id, entry.version)
  const previous = new Map<string, string | null>()
  for (const item of items) {
    if (item.kind !== "capability") continue
    previous.set(item.key, current.get(item.id) ?? null)
    current.set(item.id, item.version)
  }
  return previous
}

/**
 * How far the scrollbox is from the live end, in rows. Zero means the newest
 * card is on screen; anything else is "somebody is reading back", which is the
 * one thing the status bar has to say differently (tui.md §4.5).
 */
export function rowsBelow(box: ScrollBoxRenderable | null): number {
  if (!box) return 0
  const viewport = box.viewport?.height ?? 0
  return Math.max(0, Math.round(box.scrollHeight - viewport - box.scrollTop))
}

export function Transcript(props: {
  items: TranscriptItem[]
  header?: SessionHeader | null
  contributions?: Contributions[]
  /** On a tab with no session yet: what the first message will freeze (T22). */
  plan?: NextSession
  /**
   * The driver's last failure, verbatim (`SessionSnapshot.error`). Drawn after
   * the items because that is when it happened, and here rather than in the
   * status bar because it is the one message that has to be read in full
   * (`ErrorNotice`).
   */
  error?: string | null
  /** The workspace this session's `.nulya/` lives in — the welcome screen says so. */
  cwd?: string
  /** Clicking the `cwd` row opens the directory browser (§5.3b). */
  onPickCwd?: () => void
  /** The model line of the composition card was clicked: open `/model`. */
  onPickModel?: () => void
  /** A `/command` on the welcome screen was clicked: run it as if typed. */
  onCommand?: (command: string) => void
  /** This launch's tip for the opening screen (T38), chosen once by `App`. */
  tip?: string
  /** Handed to `App` so PgUp/PgDn and the "more below" hint have something to act on. */
  ref?: (box: ScrollBoxRenderable) => void
}) {
  /**
   * THE TRANSCRIPT DOES NOT TAKE THE KEYBOARD (T70).
   *
   * `ScrollBoxRenderable` sets `focusable = true` on itself, and OpenTUI's
   * `autoFocus` walks up from whatever a mouse-down hit to the first focusable
   * ancestor and focuses it — which blurs whatever held focus before, i.e. the
   * textarea. So every click anywhere in the transcript, including the empty
   * space under the last card and the head line of a card being folded, left
   * the composer enabled, blinking, and not listening: the box was still the
   * place to type and typing went nowhere.
   *
   * Turning it off is not a workaround, it is the truth about this box. Nothing
   * here has ever been driven by the scrollbox's own key bindings — PgUp/PgDn,
   * Shift+End and browse mode all go through the host's keymap and act on this
   * ref — so the one thing focus bought was the ability to take it away from
   * the only widget on the screen that needs it.
   *
   * The other scrollboxes in this front end are not the same case: each of them
   * lives in a surface that claims the keyboard anyway (an overlay, the docked
   * rail), so there focusing IS what the person asked for.
   */
  const takeRef = (box: ScrollBoxRenderable) => {
    box.focusable = false
    props.ref?.(box)
  }
  const style = useStyle()
  const plugins = usePlugins()
  const drawable = () => visibleItems(props.items, style.settings.transcript.thinking)
  const shown = () => windowItems(drawable(), style.historyWindow)
  const hidden = () => drawable().length - shown().length
  /**
   * Memoised, and that is load-bearing (T43): the row list is read once per row
   * to find the row BEFORE it, so recomputing it inside the loop is quadratic —
   * and each pass parses every call's arguments to decide which card it is. On
   * a 5k-event session the un-memoised version cost 2.2 s for the first frame.
   */
  const rows = createMemo(() =>
    transcriptRows(props.items, style, props.contributions ?? [], (tool) => plugins?.cardFor(tool) != null),
  )
  const capabilityPrevious = createMemo(() => capabilityPreviousVersions(props.items, props.header))
  return (
    <scrollbox
      ref={takeRef}
      flexGrow={1}
      flexShrink={1}
      width="100%"
      stickyScroll
      stickyStart="bottom"
      viewportCulling
      verticalScrollbarOptions={{
        trackOptions: { foregroundColor: style.theme.hairline, backgroundColor: "transparent" },
      }}
      contentOptions={{ flexDirection: "column", width: "100%", maxWidth: style.maxWidth, paddingRight: 1 }}
    >
      {/* Only a session that has started has a frozen composition to report; a
          draft's is still a decision and belongs on the welcome screen (T24). */}
      <Show when={props.header}>
        <CompositionCard
          header={props.header ?? null}
          contributions={props.contributions}
          onPickModel={props.onPickModel}
        />
      </Show>
      <Show when={hidden() > 0}>
        <text fg={style.theme.faint}>
          {"  "}
          {style.glyphs.foldClosed} {hidden()} earlier items · in the ledger, not on screen ·
          transcript.history_window
        </text>
      </Show>
      {/* An empty session is the one screen with nothing to report; it says
          what this session is and what to do, rather than a blank rectangle.

          Only where there is a composer under it (T72). The welcome screen is
          the composer's invitation — slash commands to run, a directory to
          change, a tip about a key — and a read-only pane watching somebody
          else's delegation can act on none of it. `onCommand` is exactly the
          fact "something here can run what this offers", so it is the
          condition rather than a second prop saying the same thing. */}
      <Show when={props.items.length === 0 && props.onCommand}>
        <Welcome
          cwd={props.cwd}
          plan={props.plan}
          onCommand={props.onCommand}
          onPickCwd={props.onPickCwd}
          tip={props.tip}
        />
      </Show>
      {/* `Index` rather than `For`: the gap is a property of a row's PLACE in
          the list, so keying by identity would rebuild a card whenever the row
          before it changed kind. */}
      <Index each={rows()}>
        {(row, index) => (
          <box
            flexDirection="column"
            width="100%"
            marginTop={gapBefore(rowSubject(rows()[index - 1]), rowSubject(row())!)}
          >
            {/* One boundary per row: a card that cannot draw becomes one line
                that says so, not a poisoned reactive graph and a frozen
                screen. Four freezes in a day earned this fence (BUGS.md #17)
                — the last one died rendering the ERROR notice. */}
            <ErrorBoundary
              fallback={(error: unknown) => (
                <text fg={style.theme.err}>
                  {`✗ card failed to draw: ${error instanceof Error ? error.message : String(error)}`}
                </text>
              )}
            >
            <Switch>
              <Match when={row().kind === "run"}>
                <RunCard
                  items={(row() as Extract<TranscriptRow, { kind: "run" }>).items}
                  itemKey={row().key}
                  contributions={props.contributions}
                />
              </Match>
              {/* Props as getters, NEVER an IIFE that reads `row()` (BUGS.md
                  #17): an immediately-invoked child compiles into a reactive
                  insert, so a new row OBJECT — which every snapshot update
                  produces for every row — tore down and rebuilt the whole
                  card. Every streamed delta was recreating every visible
                  card's every <text>; destruction runs on nextTick, so one
                  burst of deltas inside a tick stacked tens of thousands of
                  live native text buffers against a pool of 65,534 — and the
                  pool running dry is the frozen screen. With getters the Card
                  mounts once per row and its content updates in place. */}
              <Match when={row().kind === "item"}>
                <Card
                  item={itemOf(row())}
                  contributions={props.contributions}
                  capabilityPreviousVersion={capabilityPrevious().get(itemOf(row()).key) ?? null}
                />
              </Match>
            </Switch>
            </ErrorBoundary>
          </box>
        )}
      </Index>
      <Show when={props.error}>
        <ErrorNotice text={props.error!} />
      </Show>
    </scrollbox>
  )
}
