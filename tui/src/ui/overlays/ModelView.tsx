/**
 * `/model` (F5): pick the model this conversation runs on. Nothing else.
 *
 * Two things can be in front of a person, and Enter means the same sentence for
 * both — "run on that from here". On a DRAFT tab, "from here" is its first
 * message: nothing is created, the pick is what will be frozen. On a tab that
 * already has a session, `App.chooseModel` continues the conversation in a new
 * session on that model — history carried, the old file untouched.
 *
 * What it does NOT do is re-decide any of the kernel's gates (credential,
 * vision when the carried turns hold images). Their words name the config key
 * or the command that fixes them, and they reach the screen verbatim.
 *
 * `/model` is a list of models and an effort dial; `/provider` (F6) is where
 * credentials and endpoints live. Enter on a ready provider over there comes
 * back here, landed on that provider's first model — that is "pick a provider,
 * then its model", and it is two screens rather than two levels.
 *
 * What shortens the list is still the filter tcode's `build_menu` uses, not
 * nesting: a provider that cannot run is offered no model row at all
 * (`pickableRows`), plus — whatever its state — the provider of the pick in
 * force, so the row marked `current` always has somewhere to sit. The provider
 * is the heading over its own models: said once, with no level to descend into.
 *
 * The list is `nulya config show --json`: the kernel's shell projects the
 * effective config chain once, so nothing here re-derives profiles or guesses
 * which key a profile needs.
 *
 * Effort is not frozen either way — it is a per-step generation option — so it
 * rides along with whatever Enter does here, and `/effort` changes it alone.
 *
 * `s` is the screen's second sentence: put a SUB-AGENT on the highlighted row.
 * It asks by offering the personas this machine defines — nobody remembers a
 * list of names they never wrote, so the question is a list to choose from and
 * never a field to type into. What is written is a RUNG on the profile in
 * force, because the rung table hangs on the PROFILE the main model runs on:
 * that is why picking a model under another provider moves the whole team at
 * once, and why a rung may name a model on a different provider
 * (`<profile>/<id>`) — the main model on one endpoint and its explore on
 * another is a fleet, not a mistake. The team in force is drawn on the rows it
 * lands on.
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
import { createHover, onClick, rowBackground, rowGutter, rowText } from "../rows.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import { blockedReason, keyable, modelIdsOf } from "./providers.ts"
import { configShow, type ConfigView, type ModelView as ModelParams, type ProfileView } from "../../nulya/cli.ts"
import { validRungName, writeRung } from "../../nulya/credentials.ts"
import type { RungChoice } from "../../agents.ts"
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
 * A model id's parameters, as the endpoint that actually serves it describes
 * them — the profile's OWN catalog first, and only then the global
 * `[[models]]` list. The same id can be two different models: `gpt-5.6-sol`
 * on a ChatGPT subscription has 258k of context and an `xhigh` rung on its
 * ladder, while the public API's entry for that id says 1.05M and stops at
 * `high`. An id-keyed catalog cannot say which one a given profile means,
 * so whoever actually serves the row is the honest source.
 *
 * This is the ONE place that fallback happens. Both the picker's rows
 * (`modelRows`, below) and the status bar's context gauge (`App.contextWindow`)
 * call it, so a subscribed model's real window is never quietly overridden by
 * the public-API number that happens to share its id — that mismatch was
 * `docs/BUGS.md` #8: the gauge read the global list only, the picker already
 * read this way.
 */
export function modelParamsFor(
  models: readonly ModelParams[],
  profile: ProfileView,
  modelId: string,
): ModelParams | null {
  return profile.catalog?.find((m) => m.id === modelId) ?? models.find((m) => m.id === modelId) ?? null
}

/** The models of one profile, as rows with their effort dials. */
export function modelRows(config: ConfigView, profile: ProfileView): PickerRow[] {
  return modelIdsOf(profile).map((model) => {
    const params = modelParamsFor(config.models, profile, model)
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
    .filter((profile) => {
      if (current !== null && current.profile === profile.name) return true
      // The offline stand-in is not an endpoint anybody configures or would
      // choose on purpose — it exists so a machine with no key still runs, and
      // `launch.ts` lands you on it by itself when that happens (and then the
      // clause above keeps it). `/provider` still lists it: that screen is the
      // inventory of endpoints, this one is the list of what to spend on.
      if (profile.kind === "scripted") return false
      return profile.credential
    })
    .flatMap((profile) => modelRows(config, profile))
}

/** One row's stable identity across reloads: the config can change under it. */
export function rowKey(row: PickerRow): string {
  return `${row.profile.name}/${row.model}`
}

/**
 * One drawn line: a provider heading, or one of its models.
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

/**
 * How this provider staffs its rungs, one `rung→model` each, with the effort in
 * parentheses when the rung pins one. A bare model id is this provider's own;
 * `<profile>/<id>` is somebody else's.
 *
 * Picking a model here picks the whole team with it, so the team cannot stay
 * knowledge that only the person who wrote the config file has. Empty says
 * nothing at all: most profiles staff no rung, and every delegation then runs
 * on the model it inherits — which is not news.
 */
export function teamOf(profile: ProfileView | undefined): string[] {
  return (profile?.roles ?? []).map((role) => `${role.name}→${role.model}${role.effort ? ` (${role.effort})` : ""}`)
}

/** The same team on ONE line: spelled out while it is short, counted once it is not. */
export function teamSummary(profile: ProfileView | undefined, limit = 3): string {
  const roles = teamOf(profile)
  if (roles.length === 0) return ""
  return roles.length > limit ? `${roles.length} roles` : roles.join(", ")
}

/**
 * What the highlighted row's provider is, in full — its cell was cut to fit,
 * and its team is nowhere else on the screen.
 */
export function providerDetail(profile: ProfileView): string {
  const parts = [profile.name, `${profile.kind} wire`]
  if (profile.base_url.length > 0) parts.push(profile.base_url)
  if (profile.api_key_env.length > 0)
    parts.push(`${profile.api_key_env} ${profile.credential_source === "env" ? "set" : "unset"}`)
  if (profile.credential_source === "config") parts.push("key in the user config")
  if (profile.kind === "codex") parts.push("~/.codex/auth.json")
  parts.push(...teamOf(profile))
  return parts.join(" · ")
}

/**
 * Where a rung value lands: `<model-id>` is one of `owner`'s own models,
 * `<profile>/<model-id>` is somebody else's. The same grammar `extensions/agent`
 * resolves, which is why a fleet can cross endpoints at all — the main model on
 * one provider, a rung on another.
 */
export function rungLanding(owner: string, value: string): { profile: string; model: string } {
  const at = value.indexOf("/")
  if (at <= 0 || at === value.length - 1) return { profile: owner, model: value }
  return { profile: value.slice(0, at), model: value.slice(at + 1) }
}

/**
 * The profile a rung is written to: the one in FORCE, never whichever row the
 * cursor is passing over. The team hangs on the model this conversation runs
 * on, so staffing a rung with a model from another provider is the ordinary
 * case, not a special one — `s` on a DeepSeek row while running on codex means
 * "my explore runs on DeepSeek", and that is what `<profile>/<id>` is for.
 *
 * With nothing in force at all, the row's own provider: picking it is what
 * would put it in force anyway.
 */
export function rungAnchor(current: ModelPick | null, row: PickerRow | null): string {
  return current?.profile ?? row?.profile.name ?? ""
}

/** What a rung on `anchor` must say to land on `row`. */
export function rungValue(anchor: string, row: PickerRow): string {
  return row.profile.name === anchor ? row.model : `${row.profile.name}/${row.model}`
}

/**
 * The rungs OF THE FLEET IN FORCE that land on this row — the team that will
 * actually run, wherever its members live. `s` writes one, so the answer to
 * "did that take, and who runs on this row" is on the row itself rather than
 * only in the config file.
 */
export function rungsOn(fleet: ProfileView | undefined, row: PickerRow): string {
  const names: string[] = []
  for (const role of fleet?.roles ?? []) {
    const at = rungLanding(fleet!.name, role.model)
    const name = `@${role.name}`
    if (at.profile === row.profile.name && at.model === row.model && !names.includes(name)) names.push(name)
  }
  return names.join(" ")
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
  /**
   * The front tab already has a session, so Enter CONTINUES it in a new one
   * rather than settling what its first message will start. The only thing this
   * changes here is the wording: one screen, one gesture, and the difference is
   * whose "from here" it is.
   */
  live?: boolean
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
  /** Where credentials and endpoints are: `/provider`. */
  onOpenProviders: () => void
  onClose: () => void
  /** Test seam: the loader defaults to the real `nulya config show --json`. */
  load?: () => Promise<ConfigView>
  /**
   * The rungs `s` may staff, asked for only when somebody presses it: reading
   * them means running the package that owns the definitions, and a screen
   * nobody has asked a question of must not spend a subprocess. Absent = this
   * caller has no way to know, and `s` says so instead of guessing.
   */
  rungs?: () => Promise<readonly RungChoice[]>
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
  /**
   * Who to put on the highlighted row. The row already carries both halves of
   * the answer — a model and a dial turned to something — so the only question
   * left is whose, and it is asked as a list: null while it is not being asked.
   */
  const [choices, setChoices] = createSignal<readonly RungChoice[] | null>(null)
  const [choiceAt, setChoiceAt] = createSignal(0)

  /** The profile whose team `s` writes to, and whose rungs the rows are marked with. */
  const anchor = () => rungAnchor(props.current, row())
  const fleet = () => config()?.profiles.find((profile) => profile.name === anchor())
  /** What the fleet in force staffs this rung with today, if anything. */
  const fleetRung = (name: string) => fleet()?.roles.find((role) => role.name === name)?.model

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

  /**
   * The keys, in two parts: the two or three that are the point, and the rest
   * behind `?`. With no rows there is one thing to do and the
   * brief says only that.
   */
  const footer = (): { brief: string; more: string[] } => {
    if (empty())
      return { brief: "Enter · p opens /provider · Esc close", more: ["r reload"] }
    if (choices()) {
      return {
        brief: "↑↓ who · Enter puts them here · Esc cancel",
        more: [
          "a persona rides a rung of the profile in force, so this follows the conversation from provider to provider — and a persona that names a model of its own is not on this list, because it already answered",
        ],
      }
    }
    const enter = props.live ? "Enter continues this here" : "Enter starts a session"
    return {
      brief: `↑↓ model · ←→ effort · ${enter} · s puts an agent here · Esc close`,
      more: [
        "j/k and h/l do the same · r reload · /provider (F6) is where keys and endpoints are",
        "s offers the sub-agents this machine defines: the one you pick runs on this row, on this provider or another one",
        props.live
          ? "the history comes along in a new session; the old reasoning does not, and the prompt cache starts cold"
          : "the effort dial is per step, not frozen · click a row to select it, again to start on it",
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
    return chosen ? wrapWords(providerDetail(chosen.profile), inner()) : []
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
   * beside it). There is no provider column it is the heading above
   * the group, said once.
   */
  const cols = createMemo(() => {
    const list = rows()
    const labelWant = columnWidth(list.map(labelOf), 2, 26)
    const [label, id, ctx, dial, team, mark] = squeeze(
      [
        labelWant,
        columnWidth(list.map(idOf), 2, 30),
        columnWidth(list.map((row) => contextOf(row.params)), 2, 10),
        columnWidth(list.map(widestDial), 2, 16),
        // Zero-wide when no rung is staffed anywhere, which is most configs:
        // the column appears the moment there is something in it.
        columnWidth(list.map((row) => rungsOn(fleet(), row)), 2, 20),
        columnWidth(list.map(currentMark), 0, 12),
      ],
      [Math.min(labelWant, 20), 0, 0, 6, 0, 0],
      inner() - 4,
    )
    return {
      label: label!,
      id: id!,
      ctx: ctx!,
      dial: dial!,
      team: team!,
      mark: mark!,
    }
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

  /**
   * Name the highlighted row as a rung of its own provider, in the person's
   * config — the same file, and the same marked-block discipline, that a pasted
   * key is written with. What is saved is what is on the row: this model, and
   * the effort the dial is turned to (`auto` says nothing, which is not the
   * same instruction as a level).
   */
  const staff = (rung: string) => {
    const here = row()
    const loaded = config()
    const on = anchor()
    if (!here || !loaded || on.length === 0) return
    if (!validRungName(rung)) {
      return props.onNotice(`a rung is named like a sub-agent is (not '${rung}')`)
    }
    const slot = effortOf(here)
    const lands = rungValue(on, here)
    try {
      writeRung(loaded.paths.user, on, rung, lands, slot === AUTO ? undefined : slot)
      setChoices(null)
      props.onNotice(`${on} · ${rung} → ${lands}${slot === AUTO ? "" : ` (${slot})`}`)
      void refresh()
    } catch (err) {
      props.onNotice(err instanceof Error ? err.message : String(err))
    }
  }

  /**
   * Ask who should run on this row. The definitions live in a package, so this
   * is a subprocess — spent when somebody presses `s` and never on the way in.
   */
  const offer = async () => {
    if (!props.rungs) return props.onNotice("this screen was opened without a way to read the sub-agent definitions")
    try {
      const found = await props.rungs()
      if (found.length === 0) {
        return props.onNotice("no sub-agent asks for a model of its own · /agent lists what this machine defines")
      }
      setChoiceAt(0)
      setChoices(found)
    } catch (err) {
      props.onNotice(err instanceof Error ? err.message : String(err))
    }
  }

  useKeyboard((key) => {
    if (help.consume(key)) return
    // While the question is up it owns the list keys: they move the answer,
    // not the models underneath.
    const asked = choices()
    if (asked) {
      if (key.name === "escape") return setChoices(null)
      if (key.name === "return") return staff(asked[choiceAt()]?.name ?? "")
      if (key.name === "j" || key.name === "down") return setChoiceAt(Math.min(choiceAt() + 1, asked.length - 1))
      if (key.name === "k" || key.name === "up") return setChoiceAt(Math.max(choiceAt() - 1, 0))
      return
    }
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
    if (key.name === "s" && row() !== null) return void offer()
  })

  return (
    <box flexDirection="column" width="100%" flexGrow={1} flexShrink={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve} height={1}>
        {fit(
          `${style.glyphs.picker} model · what ${props.live ? "this conversation runs on from here" : "the next session runs on"}`,
          inner(),
        )}
      </text>
      <For each={noticeLines()}>
        {(line) => (
          <text fg={style.theme.warn} height={1}>
            {line}
          </text>
        )}
      </For>
      <box height={1} />

      {/* One region, two questions: while `s` is being answered the models are
          not what the keys mean, so they are not what the screen shows. */}
      <Show when={choices()}>
        {(asked: () => readonly RungChoice[]) => (
          <box flexDirection="column" flexGrow={1} flexShrink={1}>
            <text fg={style.theme.accent.evolve} height={1}>
              {fit(
                `who runs on ${labelOf(row()!)}${effortOf(row()!) === AUTO ? "" : ` (${effortOf(row()!)})`}? · saved on ${anchor()}`,
                inner(),
              )}
            </text>
            <For each={asked()}>
              {(choice, index) => {
                const tone = () => ({
                  selected: index() === choiceAt(),
                  hovered: false,
                })
                const click = onClick(() => (index() === choiceAt() ? staff(choice.name) : setChoiceAt(index())))
                // Who rides this rung, said next to it: the name is the thing
                // written to the config, the riders are how a person recognises
                // it. Identical when a persona rides its own name, which is the
                // common case and reads as one fact rather than two.
                const riders = () =>
                  choice.riders.length === 1 && choice.riders[0] === choice.name ? "" : choice.riders.join(", ")
                const lands = () => rungLanding(anchor(), fleetRung(choice.name) ?? "").model
                return (
                  <box
                    flexDirection="row"
                    width="100%"
                    height={1}
                    flexShrink={0}
                    backgroundColor={rowBackground(style, tone())}
                    onMouseDown={click.onMouseDown}
                    onMouseUp={click.onMouseUp}
                  >
                    <text fg={rowGutter(style, tone()).fg} flexShrink={0}>
                      {`  ${rowGutter(style, tone()).text}`}
                    </text>
                    <box width={22} flexShrink={0}>
                      <text fg={rowText(style, tone(), style.theme.fg)}>{fit(choice.name, 20)}</text>
                    </box>
                    <box width={26} flexShrink={0}>
                      <text fg={rowText(style, tone(), style.theme.dim)}>{fit(riders(), 24)}</text>
                    </box>
                    <text fg={rowText(style, tone(), style.theme.muted)} flexShrink={0}>
                      {fit(lands().length > 0 ? `now on ${lands()}` : "inherits today", Math.max(0, inner() - 52))}
                    </text>
                  </box>
                )
              }}
            </For>
          </box>
        )}
      </Show>

      <Show when={choices() === null}>
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
              const tone = () => ({
                selected: selected(),
                hovered: hover.at() === index,
              })
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
                    <text
                      fg={rowText(
                        style,
                        tone(),
                        isCurrentModel(row) ? style.theme.accent.user : ready ? style.theme.fg : style.theme.dim,
                      )}
                    >
                      {fit(labelOf(row), cols().label - 2)}
                    </text>
                  </box>
                  <box width={cols().id} flexShrink={0}>
                    <text fg={rowText(style, tone(), style.theme.muted)}>{fit(idOf(row), cols().id - 2)}</text>
                  </box>
                  <box width={cols().ctx} flexShrink={0}>
                    <text fg={rowText(style, tone(), style.theme.dim)}>
                      {fit(contextOf(row.params), cols().ctx - 2)}
                    </text>
                  </box>
                  <box width={cols().dial} flexShrink={0}>
                    <text fg={rowText(style, tone(), selected() ? style.theme.accent.evolve : style.theme.dim)}>
                      {fit(dialOf(row, effortOf(row)), cols().dial - 2)}
                    </text>
                  </box>
                  <box width={cols().team} flexShrink={0}>
                    <text fg={rowText(style, tone(), style.theme.accent.evolve)}>
                      {fit(rungsOn(fleet(), row), cols().team - 2)}
                    </text>
                  </box>
                  <box width={cols().mark} flexShrink={0}>
                    <text fg={rowText(style, tone(), style.theme.ok)}>{fit(currentMark(row), cols().mark)}</text>
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
      </Show>

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
