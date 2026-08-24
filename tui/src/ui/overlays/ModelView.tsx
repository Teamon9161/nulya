/**
 * `/model` (F5): pick the model the next session runs on. Nothing else.
 *
 * Four shapes, and the fourth is the one tcode had all along (tui.md §11,
 * T5 → T6 → T20 → T21). T5 was a flat table of every (profile, model): seven
 * profiles became fourteen rows, thirteen of them repeating "no key". T6 nested
 * providers over models, which shortened the list but buried the thing being
 * picked one level down. T20 kept the nesting but inverted it — models first,
 * providers behind a last row — and that is where the real fault showed: a
 * person who wanted "this provider's models" found provider-picking and
 * model-picking tangled on one screen, with `s`, `a` and `p` in the middle of a
 * list of models. So T21 cuts along the seam tcode cuts along: TWO commands.
 * `/model` is a list of models and an effort dial; `/provider` (F6) is where
 * credentials and endpoints live. Enter on a ready provider over there comes
 * back here, landed on that provider's first model — that is "pick a provider,
 * then its model", and it is two screens rather than two levels.
 *
 * What shortens the list is still the filter tcode's `build_menu` uses, not
 * nesting: a provider that cannot run is offered no model row at all
 * (`pickableRows`), plus — whatever its state — the provider of the pick in
 * force, so the row marked `current` always has somewhere to sit. The provider
 * stays a column on every row: that is how "this provider's model" reads at a
 * glance without a level to descend into.
 *
 * The list is `nulya config show --json`: the kernel's shell projects the
 * effective config chain once, so nothing here re-derives profiles or guesses
 * which key a profile needs.
 *
 * A model is frozen into a session at creation (physics #2), so "switch model"
 * is always "new session on that model" (`App` decides whether that replaces a
 * fresh untouched tab or opens a second one). Effort is not frozen — it is a
 * per-step generation option — so `/effort` can also change it in place.
 *
 * Every line on this screen is laid out by us and never by the terminal: cells
 * are cut to their column, sentences are broken at their ` · ` joints, and the
 * columns are sized from the content rather than from a number that the next
 * provider name outgrows (`ui/columns.ts`).
 */
import { For, Show, createEffect, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import { useScreen, useStyle } from "../../render/theme.ts"
import { listBudget, windowRange } from "../list.ts"
import { columnWidth, fit, squeeze, wrapWords } from "../columns.ts"
import { createHover, onClick, rowBackground, rowGutter } from "../rows.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import { blockedReason, keyable, modelIdsOf } from "./providers.ts"
import { configShow, type ConfigView, type ModelView as ModelParams, type ProfileView } from "../../nulya/cli.ts"
import type { ModelPick } from "../../state/tui_state.ts"
import type { Workspace } from "../../nulya/bin.ts"

export const AUTO = "auto"

export interface PickerRow {
  profile: ProfileView
  model: string
  /** Catalog entry, when the id is described; a bare id otherwise. */
  params: ModelParams | null
  /** Effort dial positions: `auto` (send nothing) plus the model's levels. */
  slots: string[]
}

/**
 * The models of one profile, as rows with their effort dials.
 *
 * A row's parameters come from the profile's OWN catalog first and only then
 * from the global `[[models]]` list. The same id can be two different models:
 * `gpt-5.6-sol` on a ChatGPT subscription has 258k of context and an `xhigh`
 * rung on its ladder, while the public API's entry for that id says 1.05M and
 * stops at `high`. Whoever actually serves the row is the honest source, so the
 * endpoint's own answer wins wherever it gives one (`ProfileView.catalog`).
 */
export function modelRows(config: ConfigView, profile: ProfileView): PickerRow[] {
  const own = new Map((profile.catalog ?? []).map((m) => [m.id, m]))
  const byId = new Map(config.models.map((m) => [m.id, m]))
  return modelIdsOf(profile).map((model) => {
    const params = own.get(model) ?? byId.get(model) ?? null
    return { profile, model, params, slots: [AUTO, ...(params?.efforts ?? [])] }
  })
}

/** Every (profile, model) the config offers, in config order, with its dial. */
export function pickerRows(config: ConfigView): PickerRow[] {
  return config.profiles.flatMap((profile) => modelRows(config, profile))
}

/**
 * The rows this screen offers: the models of every provider that can run,
 * plus — whatever its state — the provider of the pick in force, so the row
 * marked `current` is always on screen (and Enter on it, if it lost its key
 * since, says why rather than starting a session). Config order throughout:
 * this list does not reorder what the config chain said.
 */
export function pickableRows(config: ConfigView, current: ModelPick | null): PickerRow[] {
  return config.profiles
    .filter((profile) => profile.credential || (current !== null && current.profile === profile.name))
    .flatMap((profile) => modelRows(config, profile))
}

/** One row's stable identity across reloads: the config can change under it. */
export function rowKey(row: PickerRow): string {
  return `${row.profile.name}/${row.model}`
}

/**
 * One drawn line: a provider heading, or one of its models (tui.md §11, T31).
 *
 * The provider used to be a COLUMN, repeated on every row of the same endpoint —
 * which is how tcode's picker is not laid out, and the repetition was buying
 * nothing: `deepseek deepseek deepseek` down the left edge while the thing being
 * chosen, the model, started three cells in. As a heading it is said once,
 * everything under it belongs to it, and what a provider has to say about ITSELF
 * (no key, offline) has somewhere to sit that is not four model rows at once.
 *
 * Headings are drawn and never selected: the cursor is an index into `rows`, and
 * `j`/`k` step over models only. This is a projection of that same list, so the
 * two can never disagree about what is on screen.
 */
export type PickerLine = { kind: "provider"; profile: ProfileView } | { kind: "model"; at: number }

export function pickerLines(rows: readonly PickerRow[]): PickerLine[] {
  const out: PickerLine[] = []
  let last: string | null = null
  rows.forEach((row, at) => {
    if (row.profile.name !== last) {
      out.push({ kind: "provider", profile: row.profile })
      last = row.profile.name
    }
    out.push({ kind: "model", at })
  })
  return out
}

/**
 * What a provider's heading says about itself: its name, and the one fact that
 * decides whether anything under it can run.
 */
export function providerHeadline(profile: ProfileView): string {
  if (!profile.credential) {
    return `${profile.name} · ${blockedReason(profile)}${keyable(profile) ? " · /provider to paste a key" : ""}`
  }
  return profile.kind === "scripted" ? `${profile.name} · offline stand-in` : profile.name
}

/** Where the dial starts for a row: the live effort for the current pick, the config default elsewhere. */
export function initialSlot(row: PickerRow, current: ModelPick | null): number {
  const isCurrent = current !== null && current.profile === row.profile.name && (current.model ?? "") === row.model
  const want = isCurrent ? current?.effort : (row.profile.effort ?? row.params?.default_effort ?? undefined)
  const at = want ? row.slots.indexOf(want) : -1
  return at >= 0 ? at : 0
}

export function labelOf(row: PickerRow): string {
  return row.params && row.params.label.length > 0 ? row.params.label : row.model
}

function contextOf(params: ModelParams | null): string {
  const window = params?.context_window
  if (!window) return ""
  return window >= 1_000_000
    ? `${(window / 1_000_000).toFixed(window % 1_000_000 === 0 ? 0 : 1)}M ctx`
    : `${Math.round(window / 1000)}k ctx`
}

/** The line for a row whose provider lost (or never had) its credential. */
export function cannotRun(profile: ProfileView): string {
  const fix = keyable(profile) ? " · /provider to paste a key" : ""
  return `${profile.name} cannot run · ${blockedReason(profile)}${fix}`
}

/** What stands in for the list when no provider can run at all. */
export const nothing_runs = "no provider can run yet · /provider to paste a key or add an endpoint"

export function ModelView(props: {
  ws: Workspace
  /** What the front tab runs on, so the list can mark it and start its dial there. */
  current: ModelPick | null
  /** A line under the title: why the picker opened by itself, if it did. */
  notice?: string
  /**
   * Open on this provider's first model instead of on the pick in force: how
   * `/provider` hands a chosen provider back to the screen that picks models.
   */
  focusProfile?: string
  onPick: (pick: ModelPick) => void
  /** A line for the status bar: Enter on a row that cannot run, … */
  onNotice: (message: string) => void
  /** Where credentials and endpoints are: `/provider`, the other half of T21. */
  onOpenProviders: () => void
  onClose: () => void
  /** Test seam: the loader defaults to the real `nulya config show --json`. */
  load?: () => Promise<ConfigView>
}) {
  const style = useStyle()
  const screen = useScreen()
  const [config, setConfig] = createSignal<ConfigView | null>(null)
  const [error, setError] = createSignal<string | null>(null)
  const [at, setAt] = createSignal(0)
  /**
   * Where each row's dial has been turned to, by row key. Keyed rather than
   * indexed so a reload (a key saved next door, a provider added) that adds rows
   * above cannot hand one row's effort to another.
   */
  const [dials, setDials] = createSignal<ReadonlyMap<string, number>>(new Map())
  const hover = createHover()
  const help = createKeyHelp()

  const rows = createMemo<PickerRow[]>(() => {
    const loaded = config()
    return loaded ? pickableRows(loaded, props.current) : []
  })
  const row = () => rows()[at()] ?? null
  /** Loaded, and nothing on it: the state whose Enter is `/provider`. */
  const empty = () => config() !== null && rows().length === 0

  const isCurrentModel = (row: PickerRow) =>
    props.current !== null && props.current.profile === row.profile.name && (props.current.model ?? "") === row.model

  const slotOf = (row: PickerRow) => dials().get(rowKey(row)) ?? initialSlot(row, props.current)
  const effortOf = (row: PickerRow) => row.slots[slotOf(row)] ?? AUTO

  const dialOf = (row: PickerRow, slot: string) =>
    row.slots.length > 1 ? `${style.glyphs.dialLeft} ${slot} ${style.glyphs.dialRight}` : "no dial"
  /** The dial at its widest position: a column that fits every turn of it. */
  const widestDial = (row: PickerRow) =>
    dialOf(
      row,
      row.slots.reduce((a, b) => (b.length > a.length ? b : a), ""),
    )
  /**
   * The mark on the one in force. Everything else a row used to say here —
   * `no key`, `offline` — belongs to the provider, and is on its heading now.
   */
  const currentMark = (row: PickerRow) => (isCurrentModel(row) ? `${style.glyphs.check} current` : "")
  /** The id beside the label, only when the label is not the id already. */
  const idOf = (row: PickerRow) => (labelOf(row) === row.model ? "" : row.model)

  /** What the highlighted row's provider is, in full — its cell was cut to fit. */
  const detailOf = (chosen: ProfileView) => {
    const parts = [chosen.name, `${chosen.kind} wire`]
    if (chosen.base_url.length > 0) parts.push(chosen.base_url)
    if (chosen.api_key_env.length > 0)
      parts.push(`${chosen.api_key_env} ${chosen.credential_source === "env" ? "set" : "unset"}`)
    if (chosen.credential_source === "config") parts.push("key in the user config")
    if (chosen.kind === "codex") parts.push("~/.codex/auth.json")
    return parts.join(" · ")
  }

  /**
   * The keys, in two parts: the two or three that are the point, and the rest
   * behind `?` (tui.md §11, T18). With no rows there is one thing to do and the
   * brief says only that.
   */
  const footer = (): { brief: string; more: string[] } => {
    if (empty()) return { brief: "Enter · p opens /provider · Esc close", more: ["r reload"] }
    return {
      brief: "↑↓ model · ←→ effort · Enter starts a session · Esc close",
      more: [
        "j/k and h/l do the same · r reload · /provider (F6) is where keys and endpoints are",
        "the effort dial is per step, not frozen · click a row to select it, again to start on it",
      ],
    }
  }

  /** The columns this overlay may draw in: the box pads one on each side. */
  const inner = () => Math.max(24, screen().width - 2)

  // Every line long enough to wrap is broken here instead, one `<text>` each:
  // a `<text>` that wraps reflows, and a reflow leaves the line underneath it
  // showing through its blanks (`ui/columns.ts`).
  const noticeLines = () => (props.notice ? wrapWords(props.notice, inner()) : [])
  /** What the footer will actually draw, so the list can reserve exactly that. */
  const hintLines = () => {
    const { brief, more } = footer()
    if (brief.length === 0) return []
    if (help.open() && more.length > 0) return [brief, ...more].flatMap((line) => wrapWords(line, inner()))
    return wrapWords(more.length > 0 ? `${brief} · ? keys` : brief, inner())
  }
  const detailLines = () => {
    const chosen = row()
    return chosen ? wrapWords(detailOf(chosen.profile), inner()) : []
  }

  /**
   * The list gets what the chrome leaves — title, the notice as it actually
   * wrapped, the blank, the detail and the hint. Reserving one flat row for a
   * notice that took two is how the list claimed "2 more above" with a screen
   * full of blank rows under it.
   */
  const space = () =>
    listBudget(screen().height, 1 + noticeLines().length + 1 + detailLines().length + hintLines().length)

  /** Every drawn line, headings included: what the window is cut out of. */
  const lines = createMemo(() => pickerLines(rows()))
  /** Where the cursor's model sits among those lines. */
  const cursorLine = createMemo(() => Math.max(0, lines().findIndex((l) => l.kind === "model" && l.at === at())))

  /**
   * A window that leaves room for the "N more" lines it may need to draw, over
   * the DRAWN lines — headings take rows too, and a budget counted in models
   * would overflow a short terminal by one row per provider.
   *
   * It never starts on a model: a group whose heading has scrolled off is a list
   * of models belonging to nobody.
   */
  const range = createMemo(() => {
    const count = lines().length
    const budget = space()
    if (count <= budget) return { start: 0, end: count }
    const window = windowRange(count, cursorLine(), Math.max(3, budget - 2))
    const start = window.start > 0 && lines()[window.start]?.kind === "model" ? window.start - 1 : window.start
    return { start, end: window.end }
  })

  /**
   * Columns sized from the content: label, the id when it is not the label,
   * context, dial, and the mark on the one in force — and, when the screen is
   * narrow, the widest column giving up cells rather than any of them
   * overflowing. The id is the one that should go first: the label already names
   * the model, and the detail line under the list still says the rest — so the
   * label keeps its first twenty columns as a floor, and the id, with none,
   * yields before the label loses a letter (at 80 columns the two were the same
   * width, and "widest first" cut `DeepSeek V4 Fla…` while its id sat whole
   * beside it). There is no provider column since T31: it is the heading above
   * the group, said once.
   */
  const cols = createMemo(() => {
    const list = rows()
    const labelWant = columnWidth(list.map(labelOf), 2, 26)
    const [label, id, ctx, dial, mark] = squeeze(
      [
        labelWant,
        columnWidth(list.map(idOf), 2, 30),
        columnWidth(list.map((row) => contextOf(row.params)), 2, 10),
        columnWidth(list.map(widestDial), 2, 16),
        columnWidth(list.map(currentMark), 0, 12),
      ],
      [Math.min(labelWant, 20), 0, 0, 6, 0],
      inner() - 4,
    )
    return { label: label!, id: id!, ctx: ctx!, dial: dial!, mark: mark! }
  })

  /**
   * Re-read the config. The cursor stays on what it was on, by row key — a
   * reload after a key was saved next door must not quietly move somebody who
   * was looking at that very row. Only a first load has nobody to keep, and then
   * it opens on `focusProfile`'s first model if `/provider` named one, else on
   * the pick in force, else at the top.
   */
  const refresh = async () => {
    const keep = row() ? rowKey(row()!) : null
    try {
      const loaded = await (props.load ?? (() => configShow(props.ws)))()
      setConfig(loaded)
      setError(null)
      const list = pickableRows(loaded, props.current)
      const found = list.findIndex((entry) =>
        keep
          ? rowKey(entry) === keep
          : props.focusProfile
            ? entry.profile.name === props.focusProfile
            : props.current !== null &&
              entry.profile.name === props.current.profile &&
              (props.current.model ?? "") === entry.model,
      )
      setAt(found >= 0 ? found : 0)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  onMount(() => void refresh())

  createEffect(() => {
    if (at() >= rows().length) setAt(Math.max(0, rows().length - 1))
  })

  const move = (delta: number) => setAt(Math.min(Math.max(at() + delta, 0), Math.max(0, rows().length - 1)))

  const turn = (delta: number) => {
    const here = row()
    if (!here) return
    const size = here.slots.length
    if (size <= 1) return
    const next = new Map(dials())
    next.set(rowKey(here), (((slotOf(here) + delta) % size) + size) % size)
    setDials(next)
  }

  const pick = () => {
    const here = row()
    if (!here) return
    if (!here.profile.credential) return props.onNotice(cannotRun(here.profile))
    const slot = effortOf(here)
    props.onPick({ profile: here.profile.name, model: here.model, effort: slot === AUTO ? undefined : slot })
  }

  useKeyboard((key) => {
    if (help.consume(key)) return
    if (key.name === "escape") return props.onClose()
    if (key.name === "j" || key.name === "down") return move(1)
    if (key.name === "k" || key.name === "up") return move(-1)
    if (key.name === "h" || key.name === "left") return turn(-1)
    if (key.name === "l" || key.name === "right") return turn(1)
    if (key.name === "r") return void refresh()
    // With nothing to pick, the two keys that would do nothing lead to the one
    // screen that can change that. With rows, `p` is an ordinary miss: keys and
    // endpoints are a command of their own now, not a level of this one.
    if (empty() && (key.name === "return" || key.name === "p")) return props.onOpenProviders()
    if (key.name === "return") return pick()
  })

  return (
    <box flexDirection="column" width="100%" flexGrow={1} flexShrink={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve} height={1}>
        {fit(`${style.glyphs.picker} model · what the next session runs on`, inner())}
      </text>
      <For each={noticeLines()}>
        {(line) => (
          <text fg={style.theme.warn} height={1}>
            {line}
          </text>
        )}
      </For>
      <box height={1} />

      <box flexDirection="column" flexGrow={1} flexShrink={1}>
        <Show when={range().start > 0}>
          <text fg={style.theme.dim} height={1}>
            {"  "}
            {style.glyphs.foldClosed} {range().start} more above
          </text>
        </Show>
        <For each={lines().slice(range().start, range().end)}>
          {(line) => {
            // A provider heading: said once, and everything under it belongs to
            // it. Not selectable — the cursor only ever lands on a model.
            if (line.kind === "provider") {
              return (
                <text fg={line.profile.credential ? style.theme.muted : style.theme.warn} height={1}>
                  {fit(providerHeadline(line.profile), inner())}
                </text>
              )
            }
            const index = line.at
            const row = rows()[index]!
            const selected = () => index === at()
            const tone = () => ({ selected: selected(), hovered: hover.at() === index })
            const gutter = () => rowGutter(style, tone())
            const ready = row.profile.credential
            // Starting a session is the one action in this view that spends
            // money, so it takes two clicks: land, then confirm on the row.
            const click = onClick(() => (selected() ? pick() : setAt(index)))
            return (
              <box
                flexDirection="row"
                width="100%"
                height={1}
                flexShrink={0}
                backgroundColor={rowBackground(style, tone())}
                onMouseDown={click.onMouseDown}
                onMouseUp={click.onMouseUp}
                {...hover.row(index)}
              >
                <text fg={gutter().fg} flexShrink={0}>
                  {`  ${gutter().text}`}
                </text>
                <box width={cols().label} flexShrink={0}>
                  <text fg={isCurrentModel(row) ? style.theme.accent.user : ready ? style.theme.fg : style.theme.dim}>
                    {fit(labelOf(row), cols().label - 2)}
                  </text>
                </box>
                <box width={cols().id} flexShrink={0}>
                  <text fg={style.theme.muted}>{fit(idOf(row), cols().id - 2)}</text>
                </box>
                <box width={cols().ctx} flexShrink={0}>
                  <text fg={style.theme.dim}>{fit(contextOf(row.params), cols().ctx - 2)}</text>
                </box>
                <box width={cols().dial} flexShrink={0}>
                  <text fg={selected() ? style.theme.accent.evolve : style.theme.dim}>
                    {fit(dialOf(row, effortOf(row)), cols().dial - 2)}
                  </text>
                </box>
                <box width={cols().mark} flexShrink={0}>
                  <text fg={style.theme.ok}>{fit(currentMark(row), cols().mark)}</text>
                </box>
              </box>
            )
          }}
        </For>
        <Show when={range().end < lines().length}>
          <text fg={style.theme.dim} height={1}>
            {"  "}
            {style.glyphs.foldOpen} {lines().length - range().end} more below
          </text>
        </Show>

        <Show when={config() === null && error() === null}>
          <text fg={style.theme.dim} height={1}>
            reading the kernel's config…
          </text>
        </Show>
        <For each={error() ? wrapWords(`could not read config: ${error()}`, inner()) : []}>
          {(line) => (
            <text fg={style.theme.err} height={1}>
              {line}
            </text>
          )}
        </For>
        {/* No rows is not an empty list, it is an unfinished setup — so the one
            line here names the screen that finishes it rather than apologising. */}
        <Show when={empty()}>
          <For each={wrapWords(nothing_runs, inner())}>
            {(line) => (
              <text fg={style.theme.dim} height={1}>
                {line}
              </text>
            )}
          </For>
        </Show>
      </box>

      {/* The detail of the highlighted row, then the keys — both broken at
          their ` · ` joints, so neither can wrap into the composer below. */}
      <For each={detailLines()}>
        {(line) => (
          <text fg={style.theme.muted} height={1}>
            {line}
          </text>
        )}
      </For>
      <OverlayFooter width={inner()} help={help} brief={footer().brief} more={footer().more} />
    </box>
  )
}
