/**
 * `/provider` (F6): the endpoints that serve models — their keys, and adding
 * one that the kernel already knows how to speak to.
 *
 * This screen is the second half of the T21 split (tui.md §11, T5 → T6 → T20 →
 * T21). Everything here used to be a level BEHIND `/model`: T20 put models
 * first and left providers, keys and the add-endpoint form behind a last row,
 * which meant one screen answered two different questions and neither key
 * (`s`, `a`) belonged where it was pressed. tcode has had the answer since the
 * beginning — `/model` picks a model, `/provider` configures a provider — so
 * these are two commands over the same `nulya config show --json` rows.
 *
 * The list is every profile, runnable or not: what a person needs here is the
 * one that is NOT working. A provider without a key still lists its model ids
 * in the detail line under the list — browsing is never gated, only starting a
 * session is — and Enter does whatever that row's state calls for: a provider
 * that can run hands off to `/model` landed on its first model (the "pick a
 * provider, then its model" path, `onShowModels`), a keyless openai/anthropic
 * endpoint opens the key field, codex says it signs in instead.
 *
 * A credential belongs to the endpoint, not to each of its models, which is why
 * `s` is here and nowhere else. `a` opens the form for an OpenAI- or
 * Anthropic-compatible endpoint (OpenRouter, Groq, vLLM, an office box …):
 * name → wire → base URL → model ids → key, written as one
 * `[[provider.profiles]]` block in the kernel's user config. The kernel already
 * speaks both wires; what was missing was anywhere to say so without leaving
 * the TUI to go and find a TOML file (§1.2 D10).
 *
 * Every line is laid out by us and never by the terminal: cells are cut to
 * their column and sentences are broken at their ` · ` joints (`ui/columns.ts`).
 */
import { For, Show, createEffect, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import type { InputRenderable } from "@opentui/core"
import { useScreen, useStyle } from "../../render/theme.ts"
import { listBudget, windowRange } from "../list.ts"
import { columnWidth, fit, squeeze, wrapWords } from "../columns.ts"
import { createHover, onClick, rowBackground, rowGutter, rowText } from "../rows.ts"
import { OverlayFooter, createKeyHelp } from "./Footer.tsx"
import { blockedReason, keyable, modelIdsOf } from "./providers.ts"
import { configShow, type ConfigView, type ProfileView } from "../../nulya/cli.ts"
import { validProfileName, writeProfile, writeProfileKey, type ProfileDraft } from "../../nulya/credentials.ts"
import type { ModelPick } from "../../state/tui_state.ts"
import type { Workspace } from "../../nulya/bin.ts"

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
type Mode = "providers" | "key" | "add-name" | "add-wire" | "add-url" | "add-models" | "add-key"

const text_steps: ReadonlySet<Mode> = new Set<Mode>(["key", "add-name", "add-url", "add-models", "add-key"])

/** The compatible endpoint being defined, filled step by step. */
interface Draft {
  name: string
  kind: "openai" | "anthropic"
  base_url: string
  models: string[]
}

export function ProviderView(props: {
  ws: Workspace
  /** What the front tab runs on, so the provider serving it is marked. */
  current: ModelPick | null
  /** A line under the title: why this screen opened by itself, if it did. */
  notice?: string
  /** Enter on a provider that can run: over to `/model`, on its first model. */
  onShowModels: (profile: string) => void
  /** A line for the status bar: a key saved, a provider that takes none, … */
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
  /** Cursor of the provider list, and of the wire menu. */
  const [at, setAt] = createSignal(0)
  const [atWire, setAtWire] = createSignal(0)
  const [draft, setDraft] = createSignal<Draft>({ name: "", kind: "openai", base_url: "", models: [] })
  /** The profile whose key is being pasted right now, if any. */
  const [entering, setEntering] = createSignal<ProfileView | null>(null)
  // One hover slot per list; the two are never on screen together.
  const hover = createHover()
  const wireHover = createHover()
  const help = createKeyHelp()
  let field: InputRenderable | undefined

  const profiles = () => config()?.profiles ?? []
  /** One row past the profiles is the "add a provider" row. */
  const count = () => profiles().length + 1
  const onAddRow = () => at() >= profiles().length
  const provider = () => profiles()[at()] ?? null

  const isCurrent = (profile: ProfileView) => props.current !== null && props.current.profile === profile.name

  /** What each cell of a row says, so the columns can be sized from it. */
  const statusOf = (profile: ProfileView) => {
    if (profile.credential) return readyLabel(profile, isCurrent(profile), style.glyphs.check)
    // The remedy is a key that IS on this screen, so it is worth naming here.
    return keyable(profile) ? `${blockedReason(profile)} · s to paste one` : blockedReason(profile)
  }
  const countOf = (profile: ProfileView) => {
    const n = modelIdsOf(profile).length
    return `${n} model${n === 1 ? "" : "s"}`
  }

  /** What the highlighted provider is, in full — its row above was cut to fit. */
  const detailOf = (chosen: ProfileView) => {
    const parts = [chosen.name, `${chosen.kind} wire`]
    if (chosen.base_url.length > 0) parts.push(chosen.base_url)
    if (chosen.api_key_env.length > 0)
      parts.push(`${chosen.api_key_env} ${chosen.credential_source === "env" ? "set" : "unset"}`)
    if (chosen.credential_source === "config") parts.push("key in the user config")
    if (chosen.kind === "codex") parts.push("~/.codex/auth.json")
    // The models of a provider that cannot run are rows nowhere, so this is
    // where they can still be read: browsing is not gated, starting is.
    parts.push(`models ${modelIdsOf(chosen).join(", ") || "none"}`)
    return parts.join(" · ")
  }

  /**
   * The keys of the level that is up, in two parts: the two or three that are
   * the point, and the rest behind `?` (tui.md §11, T18). A text step's hint
   * lives on its field instead — there the question is what to type.
   */
  const footer = (): { brief: string; more: string[] } => {
    switch (mode()) {
      case "providers":
        return {
          brief: "j/k move · s paste a key · Enter its models · Esc close",
          more: [
            "a add an OpenAI- or Anthropic-compatible endpoint · r reload",
            "click a row to select it, again to open it · /model (F5) picks what a session runs on",
          ],
        }
      case "add-wire":
        return {
          brief: "j/k move · Enter confirm the wire · Esc back",
          more: ["the kernel speaks both; pick what the endpoint serves"],
        }
      default:
        return { brief: "", more: [] }
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
    if (mode() !== "providers") return []
    const chosen = provider()
    return chosen ? wrapWords(detailOf(chosen), inner()) : []
  }

  /**
   * The list gets what the chrome leaves — title, the notice as it actually
   * wrapped, the blank, the detail and the hint. Reserving one flat row for a
   * notice that took two is how a list claims "2 more above" with a screen full
   * of blank rows under it.
   */
  const space = () =>
    listBudget(screen().height, 1 + noticeLines().length + 1 + detailLines().length + hintLines().length)

  const range = createMemo(() => {
    const total = count()
    const budget = space()
    return total <= budget ? { start: 0, end: total } : windowRange(total, at(), Math.max(3, budget - 2))
  })

  /** Columns sized from the content: a name column as wide as the longest name. */
  const cols = createMemo(() => {
    const list = profiles()
    const [name, endpoint, models, status] = squeeze(
      [
        columnWidth(list.map((p) => p.name), 2, 24),
        columnWidth(list.map(endpointOf), 2, 40),
        columnWidth(list.map(countOf), 2, 11),
        columnWidth(list.map(statusOf), 0, 26),
      ],
      [8, 6, 4, 8],
      inner() - 2,
    )
    return { name: name!, endpoint: endpoint!, models: models!, status: status! }
  })

  /**
   * Re-read the config. The cursor stays on what it was on, by name — a reload
   * after saving a key must not quietly move somebody who was looking at that
   * very row. `select` names the provider to land on instead. Only a first load
   * has nobody to keep, and then it opens on the provider in force, else on the
   * first one that can actually run.
   */
  const refresh = async (select?: string) => {
    const keep = select ?? provider()?.name
    try {
      const loaded = await (props.load ?? (() => configShow(props.ws)))()
      setConfig(loaded)
      setError(null)
      const found = loaded.profiles.findIndex((p) =>
        keep ? p.name === keep : props.current !== null && p.name === props.current.profile,
      )
      const ready = loaded.profiles.findIndex((p) => p.credential && p.kind !== "scripted")
      setAt(found >= 0 ? found : ready >= 0 ? ready : 0)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  onMount(() => void refresh())

  createEffect(() => {
    if (at() >= count()) setAt(Math.max(0, count() - 1))
  })

  const move = (delta: number) => {
    if (mode() === "providers") return setAt(Math.min(Math.max(at() + delta, 0), count() - 1))
    if (mode() === "add-wire") setAtWire(Math.min(Math.max(atWire() + delta, 0), WIRES.length - 1))
  }

  /** Enter on a provider row: its models if it can run, else the one thing that would let it. */
  const openProvider = () => {
    const chosen = provider()
    if (!chosen) return
    if (chosen.credential) {
      if (modelIdsOf(chosen).length === 0) return props.onNotice(`${chosen.name} serves no model ids`)
      return props.onShowModels(chosen.name)
    }
    if (chosen.kind === "codex") return props.onNotice("codex signs in with `codex login`, not a key")
    if (!keyable(chosen)) return props.onNotice(`${chosen.name} cannot run · ${blockedReason(chosen)}`)
    startKey()
  }

  /** `s`: ask for this provider's API key. Codex has a login instead of a key. */
  const startKey = () => {
    const chosen = provider()
    if (!chosen) return
    if (chosen.kind === "codex") return props.onNotice("codex signs in with `codex login`, not a key")
    if (!keyable(chosen)) return props.onNotice(`${chosen.name} takes no API key`)
    setEntering(chosen)
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
      setMode("providers")
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
      // Land on what was just added: whether it can run is the next thing to
      // read, and Enter there is its models or its key.
      setMode("providers")
      props.onNotice(`${made.name} added to ${loaded.paths.user}`)
      void refresh(made.name)
    } catch (err) {
      props.onNotice(`could not add the provider: ${err instanceof Error ? err.message : String(err)}`)
    }
  }

  /** Esc: out of a step, back a step, and only then out of the screen. */
  const back = () => {
    switch (mode()) {
      case "providers":
        return props.onClose()
      case "key":
        setEntering(null)
        return setMode("providers")
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
    if (help.consume(key)) return
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
    // The two keys that open an input are consumed: the input this opens is
    // focused within the same dispatch and would otherwise receive this very
    // character as its first one.
    if (key.name === "a") {
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
      return openProvider()
    }
  })

  const title = () => {
    switch (mode()) {
      case "providers":
        return "providers · keys and endpoints"
      case "key":
        return `providers · a key for ${entering()?.name ?? ""}`
      default:
        return "providers · add a compatible provider"
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
  const fieldOf = (): { label: string; placeholder: string; hint: string } | null => {
    const where = config()?.paths.user ?? "the user config"
    switch (mode()) {
      case "key":
        return {
          label: `API key for ${entering()?.name ?? ""}`,
          placeholder: "paste it here",
          hint: `Enter save to ${where} (as this profile's api_key) · Esc cancel`,
        }
      case "add-name":
        return {
          label: "profile name",
          placeholder: "openrouter, groq, local …",
          hint: "the name you will see in this list and pass to --profile · Esc cancel",
        }
      case "add-url":
        return {
          label: "base URL",
          placeholder: draft().kind === "openai" ? "https://openrouter.ai/api/v1" : "https://openrouter.ai/api",
          hint:
            draft().kind === "openai"
              ? "the endpoint that serves /chat/completions · Esc back"
              : "the endpoint that serves /v1/messages · Esc back",
        }
      case "add-models":
        return {
          label: "model id(s)",
          placeholder: "comma-separated, e.g. moonshotai/kimi-k3, qwen/qwen4-max",
          hint: "exactly as the provider names them; the first becomes this profile's default · Esc back",
        }
      case "add-key":
        return {
          label: `API key for ${draft().name}`,
          placeholder: "paste it here, or leave empty",
          hint: `Enter write ${draft().name} to ${where} · empty = no key yet (s on its row later) · Esc back`,
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
          <Show when={range().start > 0}>
            <text fg={style.theme.dim} height={1}>
              {"  "}
              {style.glyphs.foldClosed} {range().start} more above
            </text>
          </Show>
          <For each={profiles().slice(range().start, range().end)}>
            {(profile, offset) => {
              const index = () => range().start + offset()
              const selected = () => index() === at()
              const tone = () => ({ selected: selected(), hovered: hover.at() === index() })
              const gutter = () => rowGutter(style, tone())
              const ready = profile.credential
              // Land on it, or — if it is already the row — open it. The same
              // `openProvider` Enter calls, never a second path.
              const click = onClick(() => (selected() ? openProvider() : setAt(index())))
              return (
                <box
                  flexDirection="row"
                  width="100%"
                  height={1}
                  flexShrink={0}
                  backgroundColor={rowBackground(style, tone())}
                  onMouseDown={click.onMouseDown}
                  onMouseUp={click.onMouseUp}
                  {...hover.row(index())}
                >
                  <text fg={gutter().fg} flexShrink={0}>
                    {gutter().text}
                  </text>
                  <box width={cols().name} flexShrink={0}>
                    <text
                      fg={rowText(
                        style,
                        tone(),
                        isCurrent(profile) ? style.theme.accent.user : ready ? style.theme.fg : style.theme.dim,
                      )}
                    >
                      {fit(profile.name, cols().name - 2)}
                    </text>
                  </box>
                  <box width={cols().endpoint} flexShrink={0}>
                    <text fg={rowText(style, tone(), style.theme.muted)}>
                      {fit(endpointOf(profile), cols().endpoint - 2)}
                    </text>
                  </box>
                  <box width={cols().models} flexShrink={0}>
                    <text fg={rowText(style, tone(), style.theme.dim)}>{fit(countOf(profile), cols().models - 2)}</text>
                  </box>
                  <box width={cols().status} flexShrink={0}>
                    <text fg={rowText(style, tone(), ready ? style.theme.ok : style.theme.warn)}>
                      {fit(statusOf(profile), cols().status)}
                    </text>
                  </box>
                </box>
              )
            }}
          </For>
          <Show when={range().end >= profiles().length && config() !== null}>
            {(() => {
              const index = () => profiles().length
              const tone = () => ({ selected: onAddRow(), hovered: hover.at() === index() })
              const gutter = () => rowGutter(style, tone())
              const click = onClick(() => (onAddRow() ? startAdd() : setAt(index())))
              return (
                <box
                  flexDirection="row"
                  width="100%"
                  height={1}
                  flexShrink={0}
                  backgroundColor={rowBackground(style, tone())}
                  onMouseDown={click.onMouseDown}
                  onMouseUp={click.onMouseUp}
                  {...hover.row(index())}
                >
                  <text fg={gutter().fg} flexShrink={0}>
                    {gutter().text}
                  </text>
                  <text fg={rowText(style, tone(), onAddRow() ? style.theme.accent.evolve : style.theme.dim)}>
                    {fit("+ add an OpenAI- or Anthropic-compatible provider", inner() - 2)}
                  </text>
                </box>
              )
            })()}
          </Show>
          <Show when={range().end < count()}>
            <text fg={style.theme.dim} height={1}>
              {"  "}
              {style.glyphs.foldOpen} {count() - range().end} more below
            </text>
          </Show>
        </Show>

        <Show when={mode() === "add-wire"}>
          <For each={WIRES}>
            {(wire, index) => {
              const selected = () => index() === atWire()
              const tone = () => ({ selected: selected(), hovered: wireHover.at() === index() })
              const gutter = () => rowGutter(style, tone())
              const click = onClick(() => {
                if (!selected()) return setAtWire(index())
                setDraft({ ...draft(), kind: wire.kind })
                setMode("add-url")
              })
              return (
                <box flexDirection="column" width="100%">
                  <box
                    flexDirection="row"
                    width="100%"
                    height={1}
                    flexShrink={0}
                    backgroundColor={rowBackground(style, tone())}
                    onMouseDown={click.onMouseDown}
                    onMouseUp={click.onMouseUp}
                    {...wireHover.row(index())}
                  >
                    <text fg={gutter().fg} flexShrink={0}>
                      {gutter().text}
                    </text>
                    <text fg={rowText(style, tone(), selected() ? style.theme.fg : style.theme.muted)}>
                      {fit(wire.label, inner() - 2)}
                    </text>
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
        <Show when={config() !== null && mode() === "providers" && profiles().length === 0}>
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
          <text fg={style.theme.muted} height={1}>
            {line}
          </text>
        )}
      </For>
      <Show when={footer().brief.length > 0}>
        <OverlayFooter width={inner()} help={help} brief={footer().brief} more={footer().more} />
      </Show>
    </box>
  )
}
