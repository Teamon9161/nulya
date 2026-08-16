/**
 * `/model` (F5): pick the profile, model and effort a session runs on.
 *
 * One flat list — every model of every profile the kernel's config knows —
 * because that is how a person thinks about it ("DeepSeek Flash", not "the
 * openai-kind profile whose base_url is deepseek.com, then its second id").
 * ↑↓ moves, ←→ turns the effort dial of the highlighted row, Enter starts a
 * session on it, Esc backs out. The list is `nulya config show --json`: the
 * kernel's shell projects the effective config chain once, so nothing here
 * re-derives profiles or guesses which key a profile needs.
 *
 * A model is frozen into a session at creation (physics #2), so "switch model"
 * is always "new session on that model" (`App` decides whether that replaces a
 * fresh untouched tab or opens a second one). Effort is not frozen — it is a
 * per-step generation option — so `/effort` can also change it in place.
 *
 * Rows whose profile has no usable credential stay visible but dim, saying so;
 * `s` on a row asks for its API key right here and writes it into the kernel's
 * user config (`nulya/credentials.ts`), so the answer to "why can't I pick
 * this?" and the way to fix it are both on the row — never in a config file
 * the user has to go and find (tui.md §1.2 D10).
 */
import { For, Show, createEffect, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { InputRenderable } from "@opentui/core"
import { useScreen, useStyle } from "../../render/theme.ts"
import { configShow, type ConfigView, type ModelView as ModelParams, type ProfileView } from "../../nulya/cli.ts"
import { writeProfileKey } from "../../nulya/credentials.ts"
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

/** Every (profile, model) the config offers, in config order, with its dial. */
export function pickerRows(config: ConfigView): PickerRow[] {
  const byId = new Map(config.models.map((m) => [m.id, m]))
  const rows: PickerRow[] = []
  for (const profile of config.profiles) {
    const ids = profile.models.length > 0 ? profile.models : profile.model ? [profile.model] : []
    for (const model of ids) {
      const params = byId.get(model) ?? null
      rows.push({ profile, model, params, slots: [AUTO, ...(params?.efforts ?? [])] })
    }
  }
  return rows
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

/** How a row says it cannot run, and what would fix it. */
export function blockedReason(profile: ProfileView): string {
  if (profile.credential) return ""
  if (profile.kind === "codex") return "run `codex login`"
  if (keyable(profile)) return "no key · s to paste one"
  return "no credential"
}

/** Profiles whose credential is an API key we can write for them. */
export function keyable(profile: ProfileView): boolean {
  return profile.kind === "openai" || profile.kind === "anthropic"
}

/** The status chip of a ready row: where its credential comes from. */
export function readyLabel(profile: ProfileView, current: boolean, check: string): string {
  if (current) return `${check} current`
  switch (profile.credential_source) {
    case "config":
      return "ready · key in config"
    case "env":
      return `ready · ${profile.api_key_env}`
    case "login":
      return "ready · codex login"
    case "builtin":
      return "offline stand-in"
    default:
      return "ready"
  }
}

function contextOf(params: ModelParams | null): string {
  const window = params?.context_window
  if (!window) return ""
  return window >= 1_000_000 ? `${(window / 1_000_000).toFixed(window % 1_000_000 === 0 ? 0 : 1)}M ctx` : `${Math.round(window / 1000)}k ctx`
}

/**
 * The slice of `count` rows to draw so that `cursor` is visible in `visible`
 * rows: the window slides only when the cursor leaves it, so a list longer than
 * the screen never overflows into the lines below it.
 */
export function windowRange(count: number, cursor: number, visible: number): { start: number; end: number } {
  if (count <= visible) return { start: 0, end: count }
  const start = Math.min(Math.max(cursor - Math.floor(visible / 2), 0), count - visible)
  return { start, end: start + visible }
}

export function ModelView(props: {
  ws: Workspace
  /** What the front tab runs on, so the list can mark it and start its dial there. */
  current: ModelPick | null
  /** A line under the title: why the picker opened by itself, if it did. */
  notice?: string
  onPick: (pick: ModelPick) => void
  /** A line for the status bar: Enter on a row that cannot run, a key saved, … */
  onNotice: (message: string) => void
  onClose: () => void
  /** Test seam: the loader defaults to the real `nulya config show --json`. */
  load?: () => Promise<ConfigView>
  /** Test seam: where a pasted key is written; defaults to the config's user path. */
  writeKey?: (path: string, profile: string, key: string) => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const [config, setConfig] = createSignal<ConfigView | null>(null)
  const [error, setError] = createSignal<string | null>(null)
  const [cursor, setCursor] = createSignal(0)
  const [slots, setSlots] = createSignal<number[]>([])
  /** The profile whose key is being pasted right now, if any. */
  const [entering, setEntering] = createSignal<ProfileView | null>(null)
  let keyInput: InputRenderable | undefined

  const rows = () => (config() ? pickerRows(config()!) : [])
  // Everything around the list is fixed: header + hairline above, title,
  // notice, blank, detail, footer, hairline + composer + hairline + status
  // below, plus the two "more" markers — about sixteen rows. Never fewer than
  // three rows of list.
  const visible = () => Math.max(3, screen().height - 16 - (props.notice ? 1 : 0))
  const range = createMemo(() => windowRange(rows().length, cursor(), visible()))
  const shown = () => rows().slice(range().start, range().end)

  const refresh = async () => {
    try {
      const loaded = await (props.load ?? (() => configShow(props.ws)))()
      setConfig(loaded)
      setError(null)
      const list = pickerRows(loaded)
      setSlots(list.map((row) => initialSlot(row, props.current)))
      // Open on the current pick, else on the first row that can actually run.
      const at = list.findIndex(
        (row) => props.current && row.profile.name === props.current.profile && (props.current.model ?? "") === row.model,
      )
      const ready = list.findIndex((row) => row.profile.credential && row.profile.kind !== "scripted")
      setCursor(at >= 0 ? at : ready >= 0 ? ready : 0)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  onMount(() => void refresh())

  createEffect(() => {
    const count = rows().length
    if (cursor() >= count) setCursor(Math.max(0, count - 1))
  })

  const move = (delta: number) => {
    const count = rows().length
    if (count === 0) return
    setCursor(Math.min(Math.max(cursor() + delta, 0), count - 1))
  }

  const turn = (delta: number) => {
    const row = rows()[cursor()]
    if (!row) return
    const next = [...slots()]
    const size = row.slots.length
    next[cursor()] = (((next[cursor()] ?? 0) + delta) % size + size) % size
    setSlots(next)
  }

  const pick = () => {
    const row = rows()[cursor()]
    if (!row) return
    if (!row.profile.credential) return props.onNotice(`${row.profile.name} cannot run yet · ${blockedReason(row.profile)}`)
    const slot = row.slots[slots()[cursor()] ?? 0] ?? AUTO
    props.onPick({ profile: row.profile.name, model: row.model, effort: slot === AUTO ? undefined : slot })
  }

  /** `s`: ask for this row's API key. Codex has a login instead of a key. */
  const startKey = () => {
    const row = rows()[cursor()]
    if (!row) return
    if (row.profile.kind === "codex") return props.onNotice("codex signs in with `codex login`, not a key")
    if (!keyable(row.profile)) return props.onNotice(`${row.profile.name} takes no API key`)
    setEntering(row.profile)
  }

  const saveKey = (value: string) => {
    const profile = entering()
    const loaded = config()
    if (!profile || !loaded) return
    const key = value.trim()
    if (key.length === 0) return props.onNotice("nothing pasted · Esc to leave the key alone")
    try {
      ;(props.writeKey ?? writeProfileKey)(loaded.paths.user, profile.name, key)
      setEntering(null)
      props.onNotice(`api_key for ${profile.name} saved to ${loaded.paths.user}`)
      void refresh()
    } catch (err) {
      props.onNotice(`could not save the key: ${err instanceof Error ? err.message : String(err)}`)
    }
  }

  useKeyboard((key) => {
    // While a key is being pasted the input owns every printable key; only
    // Esc (back out) is ours.
    if (entering()) {
      if (key.name === "escape") {
        key.preventDefault()
        setEntering(null)
      }
      return
    }
    if (key.name === "escape") return props.onClose()
    if (key.name === "j" || key.name === "down") return move(1)
    if (key.name === "k" || key.name === "up") return move(-1)
    if (key.name === "h" || key.name === "left") return turn(-1)
    if (key.name === "l" || key.name === "right") return turn(1)
    if (key.name === "r") return void refresh()
    if (key.name === "s") {
      // Consumed: the input this opens is focused within the same dispatch and
      // would otherwise receive this very `s` as its first character.
      key.preventDefault()
      return startKey()
    }
    if (key.name === "return") return pick()
  })

  const isCurrent = (row: PickerRow) =>
    props.current !== null && props.current.profile === row.profile.name && (props.current.model ?? "") === row.model

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve}>model · which profile, model and effort a session runs on</text>
      <Show when={props.notice}>
        <text fg={style.theme.warn}>{props.notice}</text>
      </Show>
      <box height={1} />
      <box flexDirection="column" flexGrow={1}>
        <Show when={range().start > 0}>
          <text fg={style.theme.dim}>  {style.glyphs.foldClosed} {range().start} more above</text>
        </Show>
        <For each={shown()}>
          {(row, offset) => {
            const index = () => range().start + offset()
            const selected = () => index() === cursor()
            const ready = row.profile.credential
            const slot = () => row.slots[slots()[index()] ?? 0] ?? AUTO
            const dial = () =>
              row.slots.length > 1 ? `${style.glyphs.dialLeft} ${slot()} ${style.glyphs.dialRight}` : "no effort dial"
            const main = () => (selected() ? style.theme.fg : ready ? style.theme.fg : style.theme.dim)
            return (
              <box flexDirection="row" width="100%" backgroundColor={selected() ? style.theme.selection : undefined}>
                <text fg={selected() ? style.theme.fg : style.theme.dim} flexShrink={0}>
                  {selected() ? style.glyphs.foldOpen : " "}{" "}
                </text>
                <box width={20} flexShrink={0}>
                  <text fg={isCurrent(row) ? style.theme.accent.user : main()}>{row.profile.name}</text>
                </box>
                <box flexDirection="row" flexGrow={1} flexShrink={1} flexBasis={0}>
                  <text fg={main()} flexShrink={0}>
                    {labelOf(row)}
                  </text>
                  <Show when={labelOf(row) !== row.model}>
                    <text fg={style.theme.dim} flexShrink={1}>
                      {"  "}
                      {row.model}
                    </text>
                  </Show>
                </box>
                <box width={9} flexShrink={0}>
                  <text fg={style.theme.dim}>{contextOf(row.params)}</text>
                </box>
                <box width={20} flexShrink={0}>
                  <text fg={ready ? (selected() ? style.theme.accent.evolve : style.theme.dim) : style.theme.dim}>{dial()}</text>
                </box>
                <box width={30} flexShrink={0}>
                  <text fg={ready ? style.theme.ok : style.theme.warn}>
                    {ready ? readyLabel(row.profile, isCurrent(row), style.glyphs.check) : blockedReason(row.profile)}
                  </text>
                </box>
              </box>
            )
          }}
        </For>
        <Show when={range().end < rows().length}>
          <text fg={style.theme.dim}>  {style.glyphs.foldOpen} {rows().length - range().end} more below</text>
        </Show>
        <Show when={config() === null && error() === null}>
          <text fg={style.theme.dim}>reading the kernel's config…</text>
        </Show>
        <Show when={error()}>
          <text fg={style.theme.err}>could not read config: {error()}</text>
        </Show>
        <Show when={config() !== null && rows().length === 0}>
          <text fg={style.theme.dim}>the config has no profiles</text>
        </Show>
      </box>
      <Show
        when={entering()}
        fallback={
          <>
            <Show when={rows()[cursor()]}>
              {(row: () => PickerRow) => (
                <text fg={style.theme.dim}>
                  {row().profile.name} · {row().profile.kind} wire
                  {row().profile.base_url.length > 0 ? ` · ${row().profile.base_url}` : ""}
                  {row().profile.api_key_env.length > 0
                    ? ` · ${row().profile.api_key_env} ${row().profile.credential_source === "env" ? "set" : "unset"}`
                    : ""}
                  {keyable(row().profile) && config() ? ` · key file ${config()!.paths.user}` : ""}
                  {row().profile.kind === "codex" ? " · ~/.codex/auth.json" : ""}
                </text>
              )}
            </Show>
            <text fg={style.theme.dim}>
              j/k move · h/l effort · Enter start a session on it · s paste its API key · r reload · Esc close
            </text>
          </>
        }
      >
        {(profile: () => ProfileView) => (
          <>
            <box flexDirection="row" width="100%">
              <text fg={style.theme.accent.evolve} flexShrink={0}>
                API key for {profile().name} {style.glyphs.user}{" "}
              </text>
              <input
                ref={(el: InputRenderable) => (keyInput = el)}
                flexGrow={1}
                focused
                placeholder="paste it here"
                placeholderColor={style.theme.dim}
                textColor={style.theme.fg}
                focusedTextColor={style.theme.fg}
                cursorColor={style.theme.accent.user}
                onSubmit={(value: unknown) => saveKey(typeof value === "string" ? value : (keyInput?.value ?? ""))}
              />
            </box>
            <text fg={style.theme.dim}>
              Enter save to {config()?.paths.user ?? "the user config"} (as this profile's api_key) · Esc cancel
            </text>
          </>
        )}
      </Show>
    </box>
  )
}
