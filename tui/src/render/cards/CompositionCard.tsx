import { Show, createMemo, createSignal } from "solid-js"
import { useBodyWidth, useStyle } from "../theme.ts"
import { lifted, onClick } from "../../ui/rows.ts"
import { Fact } from "../../ui/Fact.tsx"
import { displayWidth, fit } from "../../ui/columns.ts"
import { useFolds } from "../../state/folds.ts"
import { builtin_tools } from "../../face.ts"
import type { Contributions } from "../../nulya/files.ts"
import type { SessionHeader } from "../../nulya/ledger.ts"

/** This card's label column: shorter than the welcome screen's, same idea. */
const label_width = 9

/**
 * What this session froze at `init`: the model
 * identity, the tool face the model actually sees, the skills on offer, and the
 * parent it forked from.
 *
 * One card per session, at the top. It is not a ledger event — the header is
 * not an event — so it is drawn from the header rather than
 * pushed into the transcript's item list, and it says nothing that is not in
 * that header plus the frozen manifests it names.
 *
 * It FOLDS, and it starts folded (`transcript.composition`). Two
 * lines is the whole card at rest: what this session is, and the one fact that
 * changes what it can do — the model, plus counts. The rest is provenance
 * (which version of which extension), and provenance is what a fold is for: it
 * is worth having, it is not worth a fifth of the screen on every session. Five
 * bundled extensions used to spend eight rows on their hashes before the first
 * word was typed.
 *
 * Every row below the head is a label column and a value that WRAPS (`ui/Fact`)
 * rather than a flex row that gets shrunk — a card whose rows reflow under the
 * pointer cannot be read, and the shrink is what turned `model` into `mode`.
 *
 * A tab with no session has no card at all. It used to draw this same one in the
 * future tense; the facts that were worth having before anything is frozen
 * are on the welcome screen now, in a shape that suits a decision rather than a
 * record (`ui/Welcome.tsx`).
 *
 * The model row answers to a click when `onPickModel` is given: it opens
 * `/model`, which on a started session continues the conversation in a new one.
 * What this row says is the header's identity, and that is the whole file's
 * answer — every turn beneath this card was answered by it. Rendered without the
 * callback (a test, a card on its own) the row is inert and does not light up: a
 * highlight on a row that does nothing when pressed would be a lie.
 */
export function CompositionCard(props: {
  header: SessionHeader | null
  contributions?: Contributions[]
  onPickModel?: () => void
  onOpenSession?: (id: string) => void
}) {
  const style = useStyle()
  // This pane's columns, not the terminal's (`useBodyWidth`, BUGS.md #10/#17):
  // `Fact` wraps into `height={1}` rows, which lose their tail rather than
  // reflowing when they are laid out wider than the column they land in.
  const body = useBodyWidth()
  const folds = useFolds()
  const [overModel, setOverModel] = createSignal(false)
  const [overHead, setOverHead] = createSignal(false)
  const [overParent, setOverParent] = createSignal(false)
  const modelClick = onClick(() => props.onPickModel?.(), true)
  const parentClick = onClick(() => {
    const parent = props.header?.parent
    if (parent) props.onOpenSession?.(parent.session)
  }, true)

  const foldKey = () => `composition:${props.header?.session ?? ""}`
  const defaultOpen = () => style.settings.transcript.composition === "expanded"
  const open = () => folds.isOpen(foldKey(), defaultOpen())
  const headClick = onClick(() => folds.toggle(foldKey(), defaultOpen()))

  /** The model as a person names it: `provider/model`, nothing else. */
  const model = createMemo(() => {
    const identity = props.header?.model_identity
    if (!identity) return "…"
    const name = identity.model.length > 0 ? `${identity.provider}/${identity.model}` : identity.provider
    return name.length > 0 ? name : (props.header?.model ?? "?")
  })

  /** Where that model is being reached — provenance, so only when open. */
  const endpoint = createMemo(() => {
    const url = props.header?.model_identity?.base_url ?? ""
    if (url.length === 0) return ""
    try {
      return new URL(url).host
    } catch {
      return url
    }
  })

  /**
   * Builtin tools are always there and always first; the
   * promoted ones are the interesting half, so only those carry the ⚡.
   * `native_tools` holds stable ids (`ext:<ext>/<tool>`) — the tool name is
   * what the model actually calls.
   */
  const promoted = createMemo(() =>
    (props.header?.composition.native_tools ?? []).map((id) => id.split("/").pop() ?? id),
  )

  const tools = () => ["shell", ...promoted().map((name) => `${style.glyphs.capability}${name}`)].join(" ")

  const skills = createMemo(() =>
    (props.contributions ?? []).flatMap((entry) =>
      entry.skills.map((path) => path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? path),
    ),
  )

  /**
   * A `--with` package is often nothing but a system prompt (a mode, an
   * identity): naming its owners is how the card says this session is wearing
   * something the next one will not.
   */
  const prompts = createMemo(() =>
    (props.contributions ?? []).filter((entry) => entry.systemPrompts.length > 0).map((entry) => entry.id),
  )

  const versions = createMemo(() =>
    (props.header?.composition.active ?? []).map((entry) => `${entry.id}@${shortVersion(entry.version)}`),
  )

  /**
   * The card at rest: the counts the status line and `/ext` already speak in,
   * most telling first. A narrow line DROPS whole counts from the end rather
   * than cutting the last one in half — `ext 5` cut to `e…` says nothing, and
   * the fold is right there for the rest.
   */
  const summary = (room: number) => {
    const parts = [`tools ${builtin_tools}+${promoted().length}`]
    if (skills().length > 0) parts.push(`skills ${skills().length}`)
    if (prompts().length > 0) parts.push(`prompts ${prompts().length}`)
    if (versions().length > 0) parts.push(`ext ${versions().length}`)
    while (parts.length > 1 && displayWidth(parts.join(" · ")) > room) parts.pop()
    return parts.join(" · ")
  }

  const created = () => {
    const at = props.header?.created ?? ""
    return at.length > 0 ? at.replace("T", " ").replace(/(:\d\d)(\.\d+)?Z?$/, "") : ""
  }

  /**
   * The head line gives up whole phrases, from the least telling end, rather
   * than being cut: a title that reads `session · 2026-08-19 07:10 · frozen`
   * has lost the word that says what the card is.
   */
  const title = () => {
    const room = Math.max(8, Math.min(body(), style.maxWidth) - 3)
    const stamp = created()
    const forms = stamp.length > 0 ? [`session · ${stamp} · frozen composition`, `session · ${stamp}`] : []
    for (const form of [...forms, "session · frozen composition", "session"]) {
      if (displayWidth(form) <= room) return form
    }
    return fit("session", room)
  }

  /**
   * The rest of the model row: where the model is reached when the card is
   * open, what the session is carrying when it is closed — cut to what the line
   * has left, because this row must never become two.
   */
  const trailing = () => {
    const room = valueWidth() - displayWidth(model()) - 3
    const text = open() ? endpoint() : summary(room)
    if (text.length === 0 || room < 4) return ""
    return ` · ${fit(text, room)}`
  }

  const gutter = () => ({ text: `${style.glyphs.bar} `, fg: style.theme.accent.evolve })
  /** What a value has left after the left rule and the label column. */
  const valueWidth = () => Math.max(8, Math.min(body(), style.maxWidth) - 2 - label_width)

  return (
    <box flexDirection="column" width="100%" marginTop={1}>
      {/* The head line is the fold's handle, the way a tool card's is
          (`CardFrame`): the tint under the pointer is the only thing that says
          it answers to a click at all. */}
      <box
        flexDirection="row"
        width="100%"
        height={1}
        onMouseDown={headClick.onMouseDown}
        onMouseUp={headClick.onMouseUp}
        onMouseOver={() => setOverHead(true)}
        onMouseOut={() => setOverHead(false)}
      >
        <text fg={lifted(style, overHead(), style.theme.accent.evolve)}>{`${style.glyphs.bar} `}</text>
        <box flexGrow={1} flexShrink={1} flexBasis={0}>
          <text fg={lifted(style, overHead(), style.theme.muted)}>{title()}</text>
        </box>
        <text fg={lifted(style, overHead(), style.theme.faint)} flexShrink={0}>
          {open() ? style.glyphs.foldOpen : style.glyphs.foldClosed}
        </text>
      </box>

      {/* The one row that stays: the model, and either what it costs to reach
          (open) or what this session is carrying (closed). */}
      <box flexDirection="row" width="100%" height={1}>
        <text fg={style.theme.accent.evolve}>{`${style.glyphs.bar} `}</text>
        <box width={label_width} flexShrink={0}>
          <text fg={style.theme.dim}>model</text>
        </box>
        {/* Only the model itself is the target, not the whole row — and the
            click is claimed, so it does not also fold the card. */}
        <box
          height={1}
          flexShrink={0}
          onMouseDown={props.onPickModel ? modelClick.onMouseDown : undefined}
          onMouseUp={props.onPickModel ? modelClick.onMouseUp : undefined}
          onMouseOver={() => setOverModel(true)}
          onMouseOut={() => setOverModel(false)}
        >
          <text fg={lifted(style, Boolean(props.onPickModel) && overModel(), style.theme.fg)}>
            {fit(model(), valueWidth())}
          </text>
        </box>
        <Show when={trailing().length > 0}>
          <text fg={style.theme.dim}>{trailing()}</text>
        </Show>
      </box>

      {/* A continuation must never look like a blank unrelated conversation.
          Its parent stays one visible, clickable row even while provenance is
          folded; no ancestor events are copied into this ledger. */}
      <Show when={props.header?.parent}>
        <box
          flexDirection="row"
          width="100%"
          height={1}
          onMouseDown={props.onOpenSession ? parentClick.onMouseDown : undefined}
          onMouseUp={props.onOpenSession ? parentClick.onMouseUp : undefined}
          onMouseOver={() => setOverParent(true)}
          onMouseOut={() => setOverParent(false)}
        >
          <text fg={style.theme.accent.evolve}>{`${style.glyphs.bar} `}</text>
          <box width={label_width} flexShrink={0}><text fg={style.theme.dim}>previous</text></box>
          <text fg={lifted(style, Boolean(props.onOpenSession) && overParent(), style.theme.muted)}>
            {fit(`from ${props.header!.parent!.session}:${props.header!.parent!.seq} · open previous conversation`, valueWidth())}
          </text>
        </box>
      </Show>

      <Show when={open()}>
        <Fact label="tools" value={tools()} width={valueWidth()} labelWidth={label_width} gutter={gutter()} fg={style.theme.fg} />
        <Show when={skills().length > 0}>
          <Fact label="skills" value={skills().join(" ")} width={valueWidth()} labelWidth={label_width} gutter={gutter()} />
        </Show>
        <Show when={prompts().length > 0}>
          <Fact
            label="prompts"
            value={prompts().join(" ")}
            width={valueWidth()}
            labelWidth={label_width}
            gutter={gutter()}
            fg={style.theme.accent.evolve}
          />
        </Show>
        <Show when={versions().length > 0}>
          <Fact label="ext" value={versions().join(" · ")} width={valueWidth()} labelWidth={label_width} gutter={gutter()} />
        </Show>
      </Show>
    </box>
  )
}

/**
 * A content-addressed version is 24 hex characters and only the first few of
 * them are ever read by a person — five of those on one row is what pushed this
 * card into eight wrapped lines. The full string is in the header, in
 * `/ext`, and in `session list --json`; here it is an identity, not a key.
 */
export function shortVersion(version: string): string {
  const match = /^v-([0-9a-f]{12,})$/.exec(version)
  return match ? `v-${match[1]!.slice(0, 8)}` : version
}
