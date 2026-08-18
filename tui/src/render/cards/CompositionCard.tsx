import { For, Show, createMemo, createSignal } from "solid-js"
import { useStyle } from "../theme.ts"
import { onClick } from "../../ui/rows.ts"
import type { Contributions } from "../../nulya/files.ts"
import type { SessionHeader } from "../../nulya/ledger.ts"

/**
 * What the NEXT session will be told, on a tab that has not started one
 * (tui.md §11, T22). It is not a header and it is not frozen — that is the
 * point of showing it: everything on it is still a decision.
 */
export interface NextSession {
  /** The model id `session new` will name, or the profile when only that is known. */
  model: string
  /** The stable pin ids this TUI would pass as `--pin` (`ext:<id>/<tool>`). */
  tools: string[]
  /** `--with <id>[@<version>]`, when `/evolve` or `/mode` set one. */
  bring?: string
}

/**
 * What this session froze at `init` (tui.md §5.1, DESIGN §3.4/§7.5): the model
 * identity, the tool face the model actually sees, the skills on offer, and the
 * parent it forked from.
 *
 * One card per session, at the top, always expanded. It is not a ledger event —
 * the header is not an event (DESIGN §3.1) — so it is drawn from the header
 * rather than pushed into the transcript's item list, and it says nothing that
 * is not in that header plus the frozen manifests it names.
 *
 * With no header and a `plan` it is the same card in the other tense: what the
 * first message will freeze. Same rows, same order, so the change from "will be"
 * to "was" is one word and no re-reading (tui.md §11, T22).
 *
 * The model row answers to a click when `onPickModel` is given: it opens
 * `/model`. On a frozen session that is not "change this session's model" —
 * that is frozen (physics #2) — but the place where the next session's is
 * chosen, which is what a person reaching for the model line means; on a draft
 * it is literally this tab's own model. Rendered without the callback (a test, a
 * card on its own) the row is inert and does not light up: a highlight on a row
 * that does nothing when pressed would be a lie (tui.md §11, T18).
 */
export function CompositionCard(props: {
  header: SessionHeader | null
  contributions?: Contributions[]
  /** Drawn instead of the frozen header, on a tab with no session yet. */
  plan?: NextSession
  onPickModel?: () => void
}) {
  const style = useStyle()
  const [overModel, setOverModel] = createSignal(false)
  const modelClick = onClick(() => props.onPickModel?.())
  const planned = () => (props.header ? null : (props.plan ?? null))

  const model = createMemo(() => {
    const plan = planned()
    if (plan) return plan.model || "…"
    const identity = props.header?.model_identity
    if (!identity) return "…"
    const name = identity.model.length > 0 ? `${identity.provider}/${identity.model}` : identity.provider
    let host = ""
    try {
      if (identity.base_url.length > 0) host = ` · ${new URL(identity.base_url).host}`
    } catch {
      host = ` · ${identity.base_url}`
    }
    return `${name || props.header?.model || "?"}${host}`
  })

  /**
   * Builtin tools are always there and always first (DESIGN §5.1/§5.2); the
   * promoted ones are the interesting half, so only those carry the ⚡.
   * `native_tools` holds stable ids (`ext:<ext>/<tool>`) — the tool name is
   * what the model actually calls.
   */
  const tools = createMemo(() => {
    const native = planned()?.tools ?? props.header?.composition.native_tools ?? []
    return [
      { name: "shell", promoted: false },
      { name: "edit", promoted: false },
      ...native.map((id) => ({ name: id.split("/").pop() ?? id, promoted: true })),
    ]
  })

  const skills = createMemo(() =>
    (props.contributions ?? []).flatMap((entry) =>
      entry.skills.map((path) => path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? path),
    ),
  )

  const prompts = createMemo(() =>
    (props.contributions ?? []).reduce((count, entry) => count + entry.systemPrompts.length, 0),
  )

  const versions = createMemo(() => {
    const plan = planned()
    if (plan) return plan.bring ? [plan.bring] : []
    return (props.header?.composition.active ?? []).map((entry) => `${entry.id}@${entry.version}`)
  })

  const created = () => {
    const at = props.header?.created ?? ""
    return at.length > 0 ? ` · ${at.replace("T", " ").replace(/(:\d\d)(\.\d+)?Z?$/, "")}` : ""
  }

  return (
    <box flexDirection="column" width="100%" marginTop={1}>
      <Row bar={style.glyphs.bar} accent={style.theme.accent.evolve}>
        {/* The card's own title, so it sits a level above the labels below it.
            A draft says the tense out loud: nothing here is decided yet, and
            the first message is what decides it (physics #2). */}
        <text fg={style.theme.muted}>
          {planned() ? "next session · set when you send the first message" : `session${created()} · frozen composition`}
        </text>
      </Row>
      <Row bar={style.glyphs.bar} accent={style.theme.accent.evolve}>
        <text fg={style.theme.dim}>tools </text>
        <For each={tools()}>
          {(tool) => (
            <text fg={tool.promoted ? style.theme.accent.evolve : style.theme.fg}>
              {tool.promoted ? style.glyphs.capability : ""}
              {tool.name}{" "}
            </text>
          )}
        </For>
        <Show when={skills().length > 0}>
          <text fg={style.theme.dim}> skills </text>
          <text fg={style.theme.fg}>{skills().join(" ")}</text>
        </Show>
        {/* A `--with` package is often nothing but a system prompt (a mode, an
            identity): counting them is how the card says this session is
            wearing something the next one will not. */}
        <Show when={prompts() > 0}>
          <text fg={style.theme.dim}> prompts </text>
          <text fg={style.theme.accent.evolve}>{prompts()}</text>
        </Show>
      </Row>
      <Row bar={style.glyphs.bar} accent={style.theme.accent.evolve}>
        <text fg={style.theme.dim}>model </text>
        {/* Only the model itself is the target, not the whole row: the ext
            versions beside it are frozen facts with nothing to open. */}
        <box
          height={1}
          flexShrink={0}
          backgroundColor={props.onPickModel && overModel() ? style.theme.hover : undefined}
          onMouseDown={props.onPickModel ? modelClick.onMouseDown : undefined}
          onMouseUp={props.onPickModel ? modelClick.onMouseUp : undefined}
          onMouseOver={() => setOverModel(true)}
          onMouseOut={() => setOverModel(false)}
        >
          <text fg={style.theme.fg}>{model()}</text>
        </box>
        <Show when={versions().length > 0}>
          <text fg={style.theme.dim}> · ext </text>
          <text fg={style.theme.fg}>{versions().join(" ")}</text>
        </Show>
      </Row>
      <Show when={props.header?.parent}>
        <Row bar={style.glyphs.bar} accent={style.theme.accent.evolve}>
          <text fg={style.theme.dim}>parent </text>
          <text fg={style.theme.fg}>
            {props.header!.parent!.session}:{props.header!.parent!.seq}
          </text>
        </Row>
      </Show>
    </box>
  )
}

/** A left rule instead of a border: the one framed block in the transcript. */
function Row(props: { bar: string; accent: string; children: import("solid-js").JSX.Element }) {
  return (
    <box flexDirection="row" width="100%">
      <text fg={props.accent}>{props.bar} </text>
      {props.children}
    </box>
  )
}
