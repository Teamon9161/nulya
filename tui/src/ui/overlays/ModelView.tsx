/**
 * `/model` (F5): pick the provider, model and effort a session runs on — and,
 * when the provider you want is not in the list, add it.
 *
 * Two levels, because a provider and a model are two different questions and
 * flattening them made the screen answer neither. The flat list showed one row
 * per (profile, model): seven built-in profiles became fourteen rows, thirteen
 * of which repeated the same credential status, and the list was mostly models
 * for providers the person has no key for. So:
 *
 *   level 1 · providers — one row per profile: wire kind, endpoint, how many
 *             models it serves, and whether it can run at all. This is where
 *             credentials live (`s` pastes a key) because a credential belongs
 *             to the endpoint, not to each of its models.
 *   level 2 · models — the models of the one provider you chose, with the
 *             effort dial. Enter starts a session on it.
 *
 * `a` on level 1 opens the form for an OpenAI- or Anthropic-compatible endpoint
 * (OpenRouter, Groq, vLLM, an office box …): name → wire → base URL → model
 * ids → key, written as one `[[provider.profiles]]` block in the kernel's user
 * config. The kernel already speaks both wires; what was missing was anywhere
 * to say so without leaving the TUI to go and find a TOML file.
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
 * provider name outgrows. `ui/columns.ts` says why a wrapped line here is not
 * merely untidy but garbled.
 */
import { For, Show, createEffect, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { InputRenderable } from "@opentui/core"
import { useScreen, useStyle } from "../../render/theme.ts"
import { listBudget, windowRange } from "../list.ts"
import { columnWidth, fit, squeeze, wrapWords } from "../columns.ts"
import { configShow, type ConfigView, type ModelView as ModelParams, type ProfileView } from "../../nulya/cli.ts"
import { validProfileName, writeProfile, writeProfileKey, type ProfileDraft } from "../../nulya/credentials.ts"
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

/** The model ids a profile offers, default first if it named one. */
export function modelIdsOf(profile: ProfileView): string[] {
  return profile.models.length > 0 ? profile.models : profile.model ? [profile.model] : []
}

/** The models of one profile, as rows with their effort dials. */
export function modelRows(config: ConfigView, profile: ProfileView): PickerRow[] {
  const byId = new Map(config.models.map((m) => [m.id, m]))
  return modelIdsOf(profile).map((model) => {
    const params = byId.get(model) ?? null
    return { profile, model, params, slots: [AUTO, ...(params?.efforts ?? [])] }
  })
}

/** Every (profile, model) the config offers, in config order, with its dial. */
export function pickerRows(config: ConfigView): PickerRow[] {
  return config.profiles.flatMap((profile) => modelRows(config, profile))
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

/** What a profile IS, in one phrase: the wire it speaks and where it speaks it. */
export function endpointOf(profile: ProfileView): string {
  const host = hostOf(profile.base_url)
  switch (profile.kind) {
    case "codex":
      return "codex · ChatGPT subscription"
    case "scripted":
      return "offline · no network"
    default:
      return host.length > 0 ? `${profile.kind} wire · ${host}` : `${profile.kind} wire`
  }
}

function hostOf(url: string): string {
  if (url.length === 0) return ""
  try {
    return new URL(url).host
  } catch {
    return url.replace(/^https?:\/\//, "").split("/")[0] ?? url
  }
}

function contextOf(params: ModelParams | null): string {
  const window = params?.context_window
  if (!window) return ""
  return window >= 1_000_000
    ? `${(window / 1_000_000).toFixed(window % 1_000_000 === 0 ? 0 : 1)}M ctx`
    : `${Math.round(window / 1000)}k ctx`
}

/** The wires the kernel speaks, as the add-provider form offers them. */
export const WIRES: Array<{ kind: "openai" | "anthropic"; label: string; hint: string }> = [
  {
    kind: "openai",
    label: "openai · Chat Completions",
    hint: "OpenAI-compatible: OpenRouter, Groq, Together, vLLM, Ollama, LM Studio …",
  },
  {
    kind: "anthropic",
    label: "anthropic · Messages",
    hint: "Anthropic-compatible: Anthropic itself, OpenRouter's /api, DeepSeek's /anthropic …",
  },
]

/** Where the keyboard is. Text steps hand every printable key to their input. */
type Mode = "providers" | "models" | "key" | "add-name" | "add-wire" | "add-url" | "add-models" | "add-key"

const text_steps: ReadonlySet<Mode> = new Set<Mode>(["key", "add-name", "add-url", "add-models", "add-key"])

/** The compatible endpoint being defined, filled step by step. */
interface Draft {
  name: string
  kind: "openai" | "anthropic"
  base_url: string
  models: string[]
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
  /** Test seam: where an added provider is written. */
  writeProfileBlock?: (path: string, draft: ProfileDraft) => void
}) {
  const style = useStyle()
  const screen = useScreen()
  const [config, setConfig] = createSignal<ConfigView | null>(null)
  const [error, setError] = createSignal<string | null>(null)
  const [mode, setMode] = createSignal<Mode>("providers")
  /** Cursor of the provider list, of the model list, and of the wire menu. */
  const [atProvider, setAtProvider] = createSignal(0)
  const [atModel, setAtModel] = createSignal(0)
  const [atWire, setAtWire] = createSignal(0)
  const [slots, setSlots] = createSignal<number[]>([])
  const [draft, setDraft] = createSignal<Draft>({ name: "", kind: "openai", base_url: "", models: [] })
  /** The profile whose key is being pasted right now, if any. */
  const [entering, setEntering] = createSignal<ProfileView | null>(null)
  /** Which level `s` was pressed on, so Esc and a saved key come back to it. */
  const [keyFrom, setKeyFrom] = createSignal<Mode>("providers")
  let field: InputRenderable | undefined

  const profiles = () => config()?.profiles ?? []
  /** One row past the profiles is the "add a provider" row. */
  const providerCount = () => profiles().length + 1
  const onAddRow = () => atProvider() >= profiles().length
  const provider = () => profiles()[atProvider()] ?? null

  const rows = createMemo<PickerRow[]>(() => {
    const loaded = config()
    const chosen = provider()
    return loaded && chosen ? modelRows(loaded, chosen) : []
  })

  const isCurrentProfile = (profile: ProfileView) => props.current !== null && props.current.profile === profile.name
  const isCurrentModel = (row: PickerRow) =>
    props.current !== null && props.current.profile === row.profile.name && (props.current.model ?? "") === row.model

  /** What each cell of a row says, so the columns can be sized from it. */
  const statusOf = (profile: ProfileView) =>
    profile.credential ? readyLabel(profile, isCurrentProfile(profile), style.glyphs.check) : blockedReason(profile)
  const countOf = (profile: ProfileView) => {
    const n = modelIdsOf(profile).length
    return `${n} model${n === 1 ? "" : "s"}`
  }
  const dialOf = (row: PickerRow, slot: string) =>
    row.slots.length > 1 ? `${style.glyphs.dialLeft} ${slot} ${style.glyphs.dialRight}` : "no dial"
  /** The dial at its widest position: a column that fits every turn of it. */
  const widestDial = (row: PickerRow) =>
    dialOf(
      row,
      row.slots.reduce((a, b) => (b.length > a.length ? b : a), ""),
    )
  const modelStatus = (row: PickerRow) =>
    row.profile.credential
      ? isCurrentModel(row)
        ? `${style.glyphs.check} current`
        : ""
      : blockedReason(row.profile)

  /** What the highlighted provider is, in full — its row above was cut to fit. */
  const detailOf = (chosen: ProfileView) => {
    const parts = [chosen.name, `${chosen.kind} wire`]
    if (chosen.base_url.length > 0) parts.push(chosen.base_url)
    if (chosen.api_key_env.length > 0)
      parts.push(`${chosen.api_key_env} ${chosen.credential_source === "env" ? "set" : "unset"}`)
    if (chosen.credential_source === "config") parts.push("key in the user config")
    if (chosen.kind === "codex") parts.push("~/.codex/auth.json")
    return parts.join(" · ")
  }

  /** The keys of the level that is up. A text step's hint lives on its field. */
  const hintOf = () => {
    switch (mode()) {
      // Short enough to stand on one line at eighty columns: a hint that wraps
      // is a hint whose last joint ends up alone on a line of its own.
      case "providers":
        return "j/k move · Enter its models · s paste a key · a add a provider · r reload · Esc close"
      case "models":
        return "j/k move · h/l effort · Enter start a session on it · s paste a key · Esc back"
      case "add-wire":
        return "j/k move · Enter confirm the wire · Esc back · the kernel speaks both; pick what the endpoint serves"
      default:
        return ""
    }
  }

  /** The columns this overlay may draw in: the box pads one on each side. */
  const inner = () => Math.max(24, screen().width - 2)

  // Every line long enough to wrap is broken here instead, one `<text>` each:
  // a `<text>` that wraps reflows, and a reflow leaves the line underneath it
  // showing through its blanks (`ui/columns.ts`).
  const noticeLines = () => (props.notice ? wrapWords(props.notice, inner()) : [])
  const hintLines = () => wrapWords(hintOf(), inner())
  const detailLines = () => {
    const chosen = mode() === "providers" ? provider() : null
    return chosen ? wrapWords(detailOf(chosen), inner()) : []
  }

  /**
   * The list gets what the chrome leaves — title, the notice as it actually
   * wrapped, the blank, the detail and the hint. Reserving one flat row for a
   * notice that took two is how the list claimed "2 more above" with a screen
   * full of blank rows under it.
   */
  const space = () =>
    listBudget(screen().height, 1 + noticeLines().length + 1 + detailLines().length + hintLines().length)

  /** A window that leaves room for the "N more" lines it may need to draw. */
  const windowOf = (count: number, cursor: number) => {
    const budget = space()
    return count <= budget ? { start: 0, end: count } : windowRange(count, cursor, Math.max(3, budget - 2))
  }

  const providerRange = createMemo(() => windowOf(providerCount(), atProvider()))
  const modelRange = createMemo(() => windowOf(rows().length, atModel()))

  /**
   * Provider columns sized from the content: a name column as wide as the
   * longest name — a fixed 18 was exactly `deepseek-anthropic`, which ran
   * straight into the endpoint beside it — and, when the screen is narrow, the
   * widest column giving up cells rather than any of them overflowing.
   */
  const providerCols = createMemo(() => {
    const list = profiles()
    const [name, endpoint, count, status] = squeeze(
      [
        columnWidth(list.map((p) => p.name), 2, 24),
        columnWidth(list.map(endpointOf), 2, 40),
        columnWidth(list.map(countOf), 2, 11),
        columnWidth(list.map(statusOf), 0, 26),
      ],
      [8, 6, 4, 8],
      inner() - 2,
    )
    return { name: name!, endpoint: endpoint!, count: count!, status: status! }
  })

  /** The same, one level down: the id column is the one that may vanish. */
  const modelCols = createMemo(() => {
    const list = rows()
    const [label, id, ctx, dial, status] = squeeze(
      [
        columnWidth(list.map(labelOf), 2, 26),
        columnWidth(list.map((row) => (labelOf(row) === row.model ? "" : row.model)), 2, 30),
        columnWidth(list.map((row) => contextOf(row.params)), 2, 10),
        columnWidth(list.map(widestDial), 2, 16),
        columnWidth(list.map(modelStatus), 0, 24),
      ],
      [10, 0, 0, 6, 0],
      inner() - 2,
    )
    return { label: label!, id: id!, ctx: ctx!, dial: dial!, status: status! }
  })

  /**
   * Re-read the config. `select` names the provider to land on; without it the
   * cursor stays on the provider it was already on — a reload after saving a
   * key must not quietly move somebody who is two levels deep looking at that
   * provider's models. Only a first load has nobody to keep, and then it opens
   * on the provider in force, else on the first one that can actually run.
   */
  const refresh = async (select?: string) => {
    const keep = select ?? provider()?.name
    try {
      const loaded = await (props.load ?? (() => configShow(props.ws)))()
      setConfig(loaded)
      setError(null)
      const at = loaded.profiles.findIndex((p) =>
        keep ? p.name === keep : props.current !== null && p.name === props.current.profile,
      )
      const ready = loaded.profiles.findIndex((p) => p.credential && p.kind !== "scripted")
      setAtProvider(at >= 0 ? at : ready >= 0 ? ready : 0)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  onMount(() => void refresh())

  createEffect(() => {
    if (atProvider() >= providerCount()) setAtProvider(Math.max(0, providerCount() - 1))
  })

  /** Entering the model level: dials start where the config (or the live pick) says. */
  const enterModels = () => {
    const list = rows()
    if (list.length === 0) return props.onNotice(`${provider()?.name ?? "this profile"} serves no model ids`)
    setSlots(list.map((row) => initialSlot(row, props.current)))
    const at = list.findIndex((row) => props.current && (props.current.model ?? "") === row.model)
    setAtModel(at >= 0 ? at : 0)
    setMode("models")
  }

  const move = (delta: number) => {
    if (mode() === "providers") {
      setAtProvider(Math.min(Math.max(atProvider() + delta, 0), providerCount() - 1))
    } else if (mode() === "models") {
      setAtModel(Math.min(Math.max(atModel() + delta, 0), Math.max(0, rows().length - 1)))
    } else if (mode() === "add-wire") {
      setAtWire(Math.min(Math.max(atWire() + delta, 0), WIRES.length - 1))
    }
  }

  const turn = (delta: number) => {
    const row = rows()[atModel()]
    if (!row) return
    const next = [...slots()]
    const size = row.slots.length
    next[atModel()] = ((((next[atModel()] ?? 0) + delta) % size) + size) % size
    setSlots(next)
  }

  const pick = () => {
    const row = rows()[atModel()]
    if (!row) return
    if (!row.profile.credential)
      return props.onNotice(`${row.profile.name} cannot run yet · ${blockedReason(row.profile)}`)
    const slot = row.slots[slots()[atModel()] ?? 0] ?? AUTO
    props.onPick({ profile: row.profile.name, model: row.model, effort: slot === AUTO ? undefined : slot })
  }

  /** `s`: ask for this provider's API key. Codex has a login instead of a key. */
  const startKey = () => {
    const chosen = provider()
    if (!chosen) return
    if (chosen.kind === "codex") return props.onNotice("codex signs in with `codex login`, not a key")
    if (!keyable(chosen)) return props.onNotice(`${chosen.name} takes no API key`)
    setEntering(chosen)
    setKeyFrom(mode())
    setMode("key")
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
      setMode(keyFrom())
      props.onNotice(`api_key for ${profile.name} saved to ${loaded.paths.user}`)
      void refresh()
    } catch (err) {
      props.onNotice(`could not save the key: ${err instanceof Error ? err.message : String(err)}`)
    }
  }

  const startAdd = () => {
    setDraft({ name: "", kind: "openai", base_url: "", models: [] })
    setAtWire(0)
    setMode("add-name")
  }

  /** The add form, one confirmed field at a time. The last one writes. */
  const confirmField = (value: string) => {
    const text = value.trim()
    switch (mode()) {
      case "add-name": {
        if (!validProfileName(text)) return props.onNotice("a profile name is letters, digits, `_`, `-` or `.`")
        if (profiles().some((p) => p.name === text))
          return props.onNotice(`'${text}' already exists · Esc, then s to give it a key`)
        setDraft({ ...draft(), name: text })
        setMode("add-wire")
        return
      }
      case "add-url": {
        if (!/^https?:\/\//.test(text)) return props.onNotice("the base URL starts with http:// or https://")
        setDraft({ ...draft(), base_url: text.replace(/\/+$/, "") })
        setMode("add-models")
        return
      }
      case "add-models": {
        const ids = text
          .split(",")
          .map((id) => id.trim())
          .filter((id) => id.length > 0)
        if (ids.length === 0) return props.onNotice("at least one model id, comma-separated")
        setDraft({ ...draft(), models: ids })
        setMode("add-key")
        return
      }
      case "add-key":
        return saveProvider(text)
    }
  }

  const saveProvider = (key: string) => {
    const loaded = config()
    if (!loaded) return
    const made = draft()
    try {
      ;(props.writeProfileBlock ?? writeProfile)(loaded.paths.user, { ...made, key: key.length > 0 ? key : undefined })
      setMode("providers")
      props.onNotice(`${made.name} added to ${loaded.paths.user}`)
      // Land on what was just added: it is the thing the person came to use.
      void refresh(made.name)
    } catch (err) {
      props.onNotice(`could not add the provider: ${err instanceof Error ? err.message : String(err)}`)
    }
  }

  /** Esc: out of a step, back a level, and only then out of the picker. */
  const back = () => {
    switch (mode()) {
      case "providers":
        return props.onClose()
      case "models":
        return setMode("providers")
      case "key":
        setEntering(null)
        return setMode(keyFrom())
      case "add-name":
        return setMode("providers")
      case "add-wire":
        return setMode("add-name")
      case "add-url":
        return setMode("add-wire")
      case "add-models":
        return setMode("add-url")
      case "add-key":
        return setMode("add-models")
    }
  }

  useKeyboard((key) => {
    // A text step's input owns every printable key; only Esc is ours.
    if (text_steps.has(mode())) {
      if (key.name === "escape") {
        key.preventDefault()
        back()
      }
      return
    }
    if (key.name === "escape") return back()
    if (key.name === "j" || key.name === "down") return move(1)
    if (key.name === "k" || key.name === "up") return move(-1)
    if (mode() === "add-wire") {
      if (key.name === "return") {
        // Consumed: the base-URL input mounts focused within this same dispatch
        // and would otherwise take this Enter as an empty submit.
        key.preventDefault()
        setDraft({ ...draft(), kind: WIRES[atWire()]!.kind })
        setMode("add-url")
      }
      return
    }
    if (key.name === "r") return void refresh(provider()?.name)
    if (mode() === "models") {
      if (key.name === "h" || key.name === "left") return turn(-1)
      if (key.name === "l" || key.name === "right") return turn(1)
      if (key.name === "s") {
        // The credential belongs to the provider, so `s` means the same thing
        // on both levels: fix the row you are looking at.
        key.preventDefault()
        return startKey()
      }
      if (key.name === "return") return pick()
      return
    }
    // Providers.
    if (key.name === "a") {
      // Consumed: the input this opens is focused within the same dispatch and
      // would otherwise receive this very `a` as its first character.
      key.preventDefault()
      return startAdd()
    }
    if (key.name === "s") {
      key.preventDefault()
      if (onAddRow()) return startAdd()
      return startKey()
    }
    if (key.name === "return") {
      if (onAddRow()) {
        key.preventDefault()
        return startAdd()
      }
      return enterModels()
    }
  })

  const title = () => {
    switch (mode()) {
      case "models":
        return `model · ${provider()?.name ?? ""} · ${rows().length} model${rows().length === 1 ? "" : "s"}`
      case "key":
        return `model · a key for ${entering()?.name ?? ""}`
      case "providers":
        return "model · which provider a session runs on"
      default:
        return "model · add a compatible provider"
    }
  }

  /** The text step that is up, as a stable value to key the input on. */
  const textStep = () => (text_steps.has(mode()) ? mode() : null)

  // Every step starts empty. The renderable behind `<input>` survives the step
  // change (unmount/remount inside the same frame reuses it), so a base URL
  // would otherwise arrive with the profile name still in front of it — which
  // is exactly how a valid URL turned into "openrouterhttps://…".
  createEffect(() => {
    if (textStep() === null) return
    const clear = () => {
      if (field) field.value = ""
    }
    clear()
    queueMicrotask(clear)
  })

  /** The prompt, placeholder and hint of whichever text step is up. */
  const fieldOf = (): { label: string; placeholder: string; hint: string; masked: boolean } | null => {
    const where = config()?.paths.user ?? "the user config"
    switch (mode()) {
      case "key":
        return {
          label: `API key for ${entering()?.name ?? ""}`,
          placeholder: "paste it here",
          hint: `Enter save to ${where} (as this profile's api_key) · Esc cancel`,
          masked: false,
        }
      case "add-name":
        return {
          label: "profile name",
          placeholder: "openrouter, groq, local …",
          hint: "the name you will see in this list and pass to --profile · Esc cancel",
          masked: false,
        }
      case "add-url":
        return {
          label: "base URL",
          placeholder: draft().kind === "openai" ? "https://openrouter.ai/api/v1" : "https://openrouter.ai/api",
          hint:
            draft().kind === "openai"
              ? "the endpoint that serves /chat/completions · Esc back"
              : "the endpoint that serves /v1/messages · Esc back",
          masked: false,
        }
      case "add-models":
        return {
          label: "model id(s)",
          placeholder: "comma-separated, e.g. moonshotai/kimi-k3, qwen/qwen4-max",
          hint: "exactly as the provider names them; the first becomes this profile's default · Esc back",
          masked: false,
        }
      case "add-key":
        return {
          label: `API key for ${draft().name}`,
          placeholder: "paste it here, or leave empty",
          hint: `Enter write ${draft().name} to ${where} · empty = no key yet (s on its row later) · Esc back`,
          masked: false,
        }
      default:
        return null
    }
  }

  return (
    <box flexDirection="column" width="100%" flexGrow={1} flexShrink={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve} height={1}>
        {fit(title(), inner())}
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
        <Show when={mode() === "providers"}>
          <Show when={providerRange().start > 0}>
            <text fg={style.theme.dim} height={1}>
              {"  "}
              {style.glyphs.foldClosed} {providerRange().start} more above
            </text>
          </Show>
          <For each={profiles().slice(providerRange().start, providerRange().end)}>
            {(profile, offset) => {
              const index = () => providerRange().start + offset()
              const selected = () => index() === atProvider()
              const ready = profile.credential
              return (
                <box
                  flexDirection="row"
                  width="100%"
                  height={1}
                  flexShrink={0}
                  backgroundColor={selected() ? style.theme.selection : undefined}
                >
                  <text fg={selected() ? style.theme.fg : style.theme.dim} flexShrink={0}>
                    {selected() ? style.glyphs.foldOpen : " "}{" "}
                  </text>
                  <box width={providerCols().name} flexShrink={0}>
                    <text fg={isCurrentProfile(profile) ? style.theme.accent.user : ready ? style.theme.fg : style.theme.dim}>
                      {fit(profile.name, providerCols().name - 2)}
                    </text>
                  </box>
                  <box width={providerCols().endpoint} flexShrink={0}>
                    <text fg={style.theme.dim}>{fit(endpointOf(profile), providerCols().endpoint - 2)}</text>
                  </box>
                  <box width={providerCols().count} flexShrink={0}>
                    <text fg={style.theme.dim}>{fit(countOf(profile), providerCols().count - 2)}</text>
                  </box>
                  <box width={providerCols().status} flexShrink={0}>
                    <text fg={ready ? style.theme.ok : style.theme.warn}>
                      {fit(statusOf(profile), providerCols().status)}
                    </text>
                  </box>
                </box>
              )
            }}
          </For>
          <Show when={providerRange().end >= profiles().length}>
            <box
              flexDirection="row"
              width="100%"
              height={1}
              flexShrink={0}
              backgroundColor={onAddRow() ? style.theme.selection : undefined}
            >
              <text fg={onAddRow() ? style.theme.fg : style.theme.dim} flexShrink={0}>
                {onAddRow() ? style.glyphs.foldOpen : " "}{" "}
              </text>
              <text fg={onAddRow() ? style.theme.accent.evolve : style.theme.dim}>
                {fit("+ add an OpenAI- or Anthropic-compatible provider", inner() - 2)}
              </text>
            </box>
          </Show>
          <Show when={providerRange().end < providerCount()}>
            <text fg={style.theme.dim} height={1}>
              {"  "}
              {style.glyphs.foldOpen} {providerCount() - providerRange().end} more below
            </text>
          </Show>
        </Show>

        <Show when={mode() === "models"}>
          <Show when={modelRange().start > 0}>
            <text fg={style.theme.dim} height={1}>
              {"  "}
              {style.glyphs.foldClosed} {modelRange().start} more above
            </text>
          </Show>
          <For each={rows().slice(modelRange().start, modelRange().end)}>
            {(row, offset) => {
              const index = () => modelRange().start + offset()
              const selected = () => index() === atModel()
              const slot = () => row.slots[slots()[index()] ?? 0] ?? AUTO
              return (
                <box
                  flexDirection="row"
                  width="100%"
                  height={1}
                  flexShrink={0}
                  backgroundColor={selected() ? style.theme.selection : undefined}
                >
                  <text fg={selected() ? style.theme.fg : style.theme.dim} flexShrink={0}>
                    {selected() ? style.glyphs.foldOpen : " "}{" "}
                  </text>
                  <box width={modelCols().label} flexShrink={0}>
                    <text fg={isCurrentModel(row) ? style.theme.accent.user : style.theme.fg}>
                      {fit(labelOf(row), modelCols().label - 2)}
                    </text>
                  </box>
                  <box width={modelCols().id} flexShrink={0}>
                    <text fg={style.theme.dim}>
                      {labelOf(row) === row.model ? "" : fit(row.model, modelCols().id - 2)}
                    </text>
                  </box>
                  <box width={modelCols().ctx} flexShrink={0}>
                    <text fg={style.theme.dim}>{fit(contextOf(row.params), modelCols().ctx - 2)}</text>
                  </box>
                  <box width={modelCols().dial} flexShrink={0}>
                    <text fg={selected() ? style.theme.accent.evolve : style.theme.dim}>
                      {fit(dialOf(row, slot()), modelCols().dial - 2)}
                    </text>
                  </box>
                  <box width={modelCols().status} flexShrink={0}>
                    <text fg={row.profile.credential ? style.theme.ok : style.theme.warn}>
                      {fit(modelStatus(row), modelCols().status)}
                    </text>
                  </box>
                </box>
              )
            }}
          </For>
          <Show when={modelRange().end < rows().length}>
            <text fg={style.theme.dim} height={1}>
              {"  "}
              {style.glyphs.foldOpen} {rows().length - modelRange().end} more below
            </text>
          </Show>
        </Show>

        <Show when={mode() === "add-wire"}>
          <For each={WIRES}>
            {(wire, index) => {
              const selected = () => index() === atWire()
              return (
                <box flexDirection="column" width="100%">
                  <box
                    flexDirection="row"
                    width="100%"
                    height={1}
                    flexShrink={0}
                    backgroundColor={selected() ? style.theme.selection : undefined}
                  >
                    <text fg={selected() ? style.theme.fg : style.theme.dim} flexShrink={0}>
                      {selected() ? style.glyphs.foldOpen : " "}{" "}
                    </text>
                    <text fg={selected() ? style.theme.fg : style.theme.dim}>{fit(wire.label, inner() - 2)}</text>
                  </box>
                  <For each={wrapWords(wire.hint, inner() - 4)}>
                    {(line) => (
                      <text fg={style.theme.dim} height={1}>
                        {"    "}
                        {line}
                      </text>
                    )}
                  </For>
                </box>
              )
            }}
          </For>
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
        <Show when={config() !== null && profiles().length === 0}>
          <text fg={style.theme.dim} height={1}>
            the config has no profiles · a to add one
          </text>
        </Show>
      </box>

      {/*
        Keyed on the STEP, not on the spec object: each step of the form gets a
        fresh, empty input (a base URL must not arrive pre-filled with the name
        just typed), while the label and hint inside stay ordinary reactive
        reads. Keying on `fieldOf()` would rebuild the input on every render and
        eat the keystroke that caused it.
      */}
      <Show when={textStep()} keyed>
        {() => (
          <>
            <box flexDirection="row" width="100%">
              <text fg={style.theme.accent.evolve} flexShrink={0}>
                {fieldOf()?.label} {style.glyphs.user}{" "}
              </text>
              <input
                ref={(el: InputRenderable) => (field = el)}
                flexGrow={1}
                focused
                placeholder={fieldOf()?.placeholder ?? ""}
                placeholderColor={style.theme.dim}
                textColor={style.theme.fg}
                focusedTextColor={style.theme.fg}
                cursorColor={style.theme.accent.user}
                onSubmit={(value: unknown) =>
                  mode() === "key"
                    ? saveKey(typeof value === "string" ? value : (field?.value ?? ""))
                    : confirmField(typeof value === "string" ? value : (field?.value ?? ""))
                }
              />
            </box>
            <For each={wrapWords(fieldOf()?.hint ?? "", inner())}>
              {(line) => (
                <text fg={style.theme.dim} height={1}>
                  {line}
                </text>
              )}
            </For>
          </>
        )}
      </Show>

      {/* The detail of the highlighted row, then the keys — both broken at
          their ` · ` joints, so neither can wrap into the composer below. */}
      <For each={detailLines()}>
        {(line) => (
          <text fg={style.theme.dim} height={1}>
            {line}
          </text>
        )}
      </For>
      <For each={hintLines()}>
        {(line) => (
          <text fg={style.theme.dim} height={1}>
            {line}
          </text>
        )}
      </For>
    </box>
  )
}
