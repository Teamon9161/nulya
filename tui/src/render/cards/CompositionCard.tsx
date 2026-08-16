import { For, Show, createMemo } from "solid-js"
import { useStyle } from "../theme.ts"
import type { Contributions } from "../../nulya/files.ts"
import type { SessionHeader } from "../../nulya/ledger.ts"

/**
 * What this session froze at `init` (tui.md §5.1, DESIGN §3.4/§7.5): the model
 * identity, the tool face the model actually sees, the skills on offer, and the
 * parent it forked from.
 *
 * One card per session, at the top, always expanded. It is not a ledger event —
 * the header is not an event (DESIGN §3.1) — so it is drawn from the header
 * rather than pushed into the transcript's item list, and it says nothing that
 * is not in that header plus the frozen manifests it names.
 */
export function CompositionCard(props: { header: SessionHeader | null; contributions?: Contributions[] }) {
  const style = useStyle()

  const model = createMemo(() => {
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
    const native = props.header?.composition.native_tools ?? []
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

  const versions = createMemo(() =>
    (props.header?.composition.active ?? []).map((entry) => `${entry.id}@${entry.version}`),
  )

  const created = () => {
    const at = props.header?.created ?? ""
    return at.length > 0 ? ` · ${at.replace("T", " ").replace(/(:\d\d)(\.\d+)?Z?$/, "")}` : ""
  }

  return (
    <box flexDirection="column" width="100%" marginTop={1}>
      <Row bar={style.glyphs.bar} accent={style.theme.accent.evolve}>
        <text fg={style.theme.dim}>
          session{created()} · frozen composition
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
        <text fg={style.theme.fg}>{model()}</text>
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
