/**
 * `/ext` (F2): the extension store as a view (tui.md §5.3).
 *
 * Three things live here that exist nowhere else on the screen:
 *
 *  - the VERSION LINE. Versions are content-addressed and immutable; `activate`
 *    and `rollback` only move the `current` pointer (physics #5). So the
 *    timeline is the extension's whole history, and rollback is a normal move
 *    along it rather than an undo.
 *  - the DRIFT. This session froze specific versions at `session new` and cannot
 *    change them mid-flight (DESIGN §7.5). When `current` has moved since, that
 *    difference is the single most useful sentence in the view:
 *    `frozen v-a · store v-b → next session`.
 *  - the USAGE table, a plain projection of `.nulya/tool-usage.jsonl`. It does
 *    NOT rank: a tool joins the model's tool face only when somebody writes a
 *    pin (the operator's `registry.pinned_native_tools`, or an evolution
 *    session's `session new --pin`), so there is no "next" for a table to
 *    predict — these counts are the evidence for that judgement, not it.
 *  - the TOOLS pane, where that pin is written (tui.md §11, T12). It manages the
 *    two axes separately (D4) and never merges them into one switch: pins decide
 *    which tools the model can call, membership (activate / deactivate) decides
 *    whose skills and system prompts are in the composition. Both take effect at
 *    the next `session new` and neither can touch this one.
 */
import { For, Show, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import { useStyle } from "../../render/theme.ts"
import { listExtensions, readToolUsage, type ExtensionEntry, type ToolUsage } from "../../nulya/files.ts"
import { configShow, extDeactivate, extPrune, extSetCurrent, type SyncLine } from "../../nulya/cli.ts"
import { draftColumn, planStore } from "../../extensions.ts"
import {
  pinState,
  promote,
  quotaLine,
  readUserPins,
  stateLabel,
  toggle,
  toggleAll,
  toolId,
  writeUserPins,
  type PinChange,
  type PinSources,
  type PinState,
} from "../../pins.ts"
import { rememberSessionPins, sessionPins } from "../../state/tui_state.ts"
import { UsageTable } from "./UsageTable.tsx"
import type { Workspace } from "../../nulya/bin.ts"
import type { SessionHeader } from "../../nulya/ledger.ts"

type Pane = "extensions" | "versions" | "tools" | "usage"

/** An action waiting for `y`: pointer moves, and the two that take something away. */
type Pending =
  | { kind: "activate" | "rollback"; id: string; version: string }
  | { kind: "prune"; id: string; version: string; count: number }
  | { kind: "deactivate"; id: string }

function confirmLine(pending: Pending): string {
  if (pending.kind === "prune") {
    return `prune ${pending.id}: delete ${pending.count} version(s), keep ${pending.version}? y / Esc`
  }
  if (pending.kind === "deactivate") {
    return `deactivate ${pending.id}: its skills and prompts leave the NEXT session; versions all stay? y / Esc`
  }
  return `${pending.kind} ${pending.id} ${pending.version}? y / Esc`
}

/** One row of the tools pane: a pinnable tool, its state, and its evidence. */
export interface ToolRow {
  id: string
  extension: string
  tool: string
  state: PinState
  uses: number
  ok: number
}

/**
 * Every tool that could be pinned, with the state each one is in.
 *
 * Only extensions with an ACTIVE, un-shadowed version are here: a pin naming
 * anything else is refused by `session new` (`PinNamesUnknownExtension`), so
 * offering it would be offering a session that will not start.
 */
export function toolRows(
  extensions: readonly ExtensionEntry[],
  sources: PinSources,
  usage: readonly ToolUsage[],
): ToolRow[] {
  const rows: ToolRow[] = []
  for (const entry of extensions) {
    if (!entry.current || entry.shadowed) continue
    for (const tool of entry.tools) {
      const id = toolId(entry.id, tool)
      const row = usage.find((u) => u.toolId === id)
      rows.push({
        id,
        extension: entry.id,
        tool,
        state: pinState(id, sources),
        uses: row?.uses ?? 0,
        ok: row?.ok ?? 0,
      })
    }
  }
  return rows.sort((a, b) => a.id.localeCompare(b.id))
}

/** What the NEXT session's face would carry: the merged config plus our own. */
export function nextFace(sources: PinSources): string[] {
  const face = [...sources.merged]
  for (const pin of sources.session) if (!face.includes(pin)) face.push(pin)
  return face
}

/** What the running session froze for this extension, if anything. */
export function frozenVersion(header: SessionHeader | null | undefined, id: string): string | null {
  return header?.composition.active.find((entry) => entry.id === id)?.version ?? null
}

export function driftLine(frozen: string | null, current: string | null): string | null {
  if (!frozen || !current || frozen === current) return null
  return `frozen ${frozen} · store ${current} → next session`
}

export function ExtView(props: {
  ws: Workspace
  header: SessionHeader | null
  /**
   * The session file the screen is following, relative to the workspace. Passed
   * to `ext activate` as `NULYA_SESSION` so the kernel deposits its capability
   * note where the model will see it (DESIGN §5.3) — the one action in this view
   * that a running session can do anything about.
   */
  sessionFile?: string
  /** Where `session_pins` is remembered; tests point it elsewhere. */
  statePath?: string
  onClose: () => void
}) {
  const style = useStyle()
  const [extensions, setExtensions] = createSignal<ExtensionEntry[]>([])
  const [usage, setUsage] = createSignal<ToolUsage[]>([])
  const [cursor, setCursor] = createSignal(0)
  const [versionCursor, setVersionCursor] = createSignal(0)
  const [toolCursor, setToolCursor] = createSignal(0)
  const [pane, setPane] = createSignal<Pane>("extensions")
  const [notice, setNotice] = createSignal<string | null>(null)
  const [drafts, setDrafts] = createSignal<SyncLine[]>([])
  const [confirm, setConfirm] = createSignal<Pending | null>(null)
  // The three places a pin can be written, plus the quota the kernel enforces.
  // `userPath` comes from the kernel's own projection: we write where it reads.
  const [maxTools, setMaxTools] = createSignal(8)
  const [merged, setMerged] = createSignal<string[]>([])
  const [userPath, setUserPath] = createSignal("")
  const [userPins, setUserPins] = createSignal<string[]>([])
  const [tuiPins, setTuiPins] = createSignal<string[]>(sessionPins(props.statePath))

  const sources = createMemo<PinSources>(() => ({
    user: userPins(),
    session: tuiPins(),
    merged: merged(),
  }))

  const refreshPins = async () => {
    setTuiPins(sessionPins(props.statePath))
    try {
      const view = await configShow(props.ws)
      setMaxTools(view.registry.max_tools)
      setMerged(view.registry.pinned_native_tools)
      setUserPath(view.paths.user)
      setUserPins(readUserPins(view.paths.user))
    } catch {
      // No projection is "unknown", never a wrong state: with `merged` empty
      // the panel simply shows nothing as pinned from a config layer, and the
      // kernel still has the last word at `session new`.
    }
  }

  const refresh = async () => {
    setExtensions(await listExtensions(props.ws))
    setUsage(await readToolUsage(props.ws))
    await refreshPins()
    // What the SOURCE in each store directory would build to, versus what is
    // there — the one thing the store's own listing cannot say. A plan, so this
    // view never writes anything by opening.
    try {
      const [ws_plan, user_plan] = await Promise.all([planStore(props.ws, false), planStore(props.ws, true)])
      setDrafts([...ws_plan.lines, ...user_plan.lines])
    } catch {
      setDrafts([]) // no plan is "unknown", never a wrong column
    }
  }

  onMount(() => void refresh())

  const selected = createMemo(() => extensions()[Math.min(cursor(), Math.max(0, extensions().length - 1))] ?? null)
  const versions = createMemo(() => selected()?.versions ?? [])
  const selectedVersion = createMemo(() => versions()[Math.min(versionCursor(), Math.max(0, versions().length - 1))] ?? null)
  const drift = createMemo(() => {
    const entry = selected()
    return entry ? driftLine(frozenVersion(props.header, entry.id), entry.current) : null
  })
  const usageOf = (entry: ExtensionEntry, tool: string) =>
    usage().find((row) => row.toolId === `ext:${entry.id}/${tool}`) ?? null
  /** The sync plan's line for an id, when that id still has a draft. */
  const draftOf = (id: string) => drafts().find((line) => line.id === id) ?? null

  const tools = createMemo(() => toolRows(extensions(), sources(), usage()))
  const selectedTool = createMemo(() => tools()[Math.min(toolCursor(), Math.max(0, tools().length - 1))] ?? null)
  const quota = createMemo(() => quotaLine(maxTools(), nextFace(sources()).length))

  const move = (delta: number) => {
    if (pane() === "extensions") {
      const count = extensions().length
      if (count === 0) return
      setCursor(Math.min(Math.max(cursor() + delta, 0), count - 1))
      setVersionCursor(0)
      return
    }
    if (pane() === "versions") {
      const count = versions().length
      if (count === 0) return
      setVersionCursor(Math.min(Math.max(versionCursor() + delta, 0), count - 1))
      return
    }
    if (pane() === "tools") {
      const count = tools().length
      if (count === 0) return
      setToolCursor(Math.min(Math.max(toolCursor() + delta, 0), count - 1))
    }
  }

  /**
   * Carry out one pin decision. The config file is written by text surgery that
   * re-reads and checks itself (`pins.ts`), so a failure here means nothing
   * changed on disk and the sentence says which file to look at.
   */
  const applyPin = async (change: PinChange) => {
    try {
      if (change.user) {
        if (userPath().length === 0) throw new Error("config show did not say where the user config lives")
        writeUserPins(userPath(), change.user)
      }
      if (change.session) rememberSessionPins(change.session, props.statePath)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
      return
    }
    setNotice(change.notice)
    await refreshPins()
  }

  /** `Space` / `A`: on a tool row it is that tool, on an id row the whole package. */
  const pinKey = (verb: "toggle" | "promote") => {
    if (pane() === "tools") {
      const row = selectedTool()
      if (!row) return
      return void applyPin(verb === "toggle" ? toggle(row.id, sources()) : promote(row.id, sources()))
    }
    const entry = selected()
    if (!entry) return
    const ids = tools()
      .filter((row) => row.extension === entry.id)
      .map((row) => row.id)
    if (ids.length === 0) {
      setNotice(`${entry.id} declares no tools · nothing to pin (its skills and prompts are the membership axis)`)
      return
    }
    if (verb === "promote") {
      // Deliberately one at a time: `always` costs a slot and prefix tokens in
      // every session on this machine, and a whole package at once is not a
      // decision anybody makes by holding a key down.
      setNotice("A promotes one tool · Tab to the tools pane and pick it")
      return
    }
    void applyPin(toggleAll(ids, sources()))
  }

  const act = (verb: "activate" | "rollback") => {
    const entry = selected()
    if (!entry) return
    // On the version line the selection IS the answer; on the id list the
    // draft's own version is — which is what makes an id just built by a sync
    // one key away from being the current one.
    const version = pane() === "versions" ? selectedVersion()?.version : draftOf(entry.id)?.version
    if (!version) {
      setNotice("no version to point at · Tab to the version line and pick one")
      return
    }
    setConfirm({ kind: verb, id: entry.id, version })
  }

  const prune = () => {
    const entry = selected()
    if (!entry) return
    if (!entry.current) {
      setNotice(`${entry.id} has no current version · nothing can say which one to keep`)
      return
    }
    const others = entry.versions.length - 1
    if (others <= 0) {
      setNotice(`${entry.id} has only the current version`)
      return
    }
    setConfirm({ kind: "prune", id: entry.id, version: entry.current, count: others })
  }

  /**
   * `d` — the membership axis (D4). Deactivating takes an extension's skills and
   * system prompts out of the next composition; its tools leave the face with
   * them, because a pin can only resolve through an active version. Nothing is
   * deleted and nothing about this session moves.
   */
  const deactivate = () => {
    const entry = selected()
    if (!entry) return
    if (!entry.current) {
      setNotice(`${entry.id} has no current version · it is already out of every composition`)
      return
    }
    setConfirm({ kind: "deactivate", id: entry.id })
  }

  const runConfirmed = async () => {
    const pending = confirm()
    setConfirm(null)
    if (!pending) return
    try {
      if (pending.kind === "deactivate") {
        setNotice(await extDeactivate(props.ws, pending.id))
      } else if (pending.kind === "prune") {
        // Deleting a version is the one action here that cannot be undone by
        // moving a pointer, so the kernel's own sentence about the cost is what
        // gets shown rather than a cheerful count of freed bytes.
        const output = await extPrune(props.ws, { id: pending.id })
        setNotice(output.split("\n").slice(-2).join(" · "))
      } else {
        // A store action, not a session event: it changes what the NEXT session
        // freezes and nothing about this one (DESIGN §7.5), so it never touches
        // the ledger and its output stays here.
        //
        // The one exception is the note: an activation is the single change here
        // the running model CAN act on — `ext run <id>@<version>` reaches a new
        // version through the shell without any composition moving — so the
        // session is named and the kernel deposits its capability note. Anything
        // it prints on stderr (the `--user`-inside-a-session warning) is not our
        // news to relay.
        setNotice(
          await extSetCurrent(props.ws, pending.kind, pending.id, pending.version, {
            session: pending.kind === "activate" ? props.sessionFile : undefined,
          }),
        )
      }
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error))
    }
    await refresh()
  }

  useKeyboard((key) => {
    if (confirm()) {
      if (key.name === "y" || key.name === "return") return void runConfirmed()
      setConfirm(null)
      return
    }
    if (key.name === "escape") return props.onClose()
    if (key.name === "tab") {
      const next: Record<Pane, Pane> = {
        extensions: "versions",
        versions: "tools",
        tools: "usage",
        usage: "extensions",
      }
      setPane(next[pane()])
      return
    }
    if (key.name === "j" || key.name === "down") return move(1)
    if (key.name === "k" || key.name === "up") return move(-1)
    if (key.name === "space") return pinKey("toggle")
    // Shift+A, not `a`: promotion writes a config file, and it must not be one
    // keystroke away from the activate that sits beside it.
    if (key.name === "a" && key.shift) return pinKey("promote")
    if (key.name === "a") return act("activate")
    if (key.name === "r") return act("rollback")
    if (key.name === "p") return prune()
    if (key.name === "d") return deactivate()
    if (key.name === "t") return setPane(pane() === "tools" ? "extensions" : "tools")
    if (key.name === "u") return setPane(pane() === "usage" ? "extensions" : "usage")
  })

  /**
   * The pin panel. One row per tool, three states, and the quota above them —
   * `2+N/8`, because the builtins count and a refused pin is otherwise a
   * mystery (DESIGN §5.1).
   *
   * A pin written by a project or system config layer is shown and not touched:
   * this view writes one key in one file (D3), and quietly editing somebody
   * else's layer to make a checkbox look right would be the worse lie.
   */
  const ToolsPane = () => (
    <box flexDirection="column" width="100%" flexGrow={1}>
      <text fg={style.theme.fg}>{quota()}</text>
      <text fg={style.theme.dim}>
        user config {userPath() || "(unknown)"}
      </text>
      <box height={1} />
      <For each={tools()}>
        {(row, index) => {
          const here = () => index() === toolCursor()
          const on = () => row.state !== "off"
          return (
            <box flexDirection="row" backgroundColor={here() ? style.theme.selection : undefined}>
              <text fg={on() ? style.theme.accent.evolve : style.theme.dim}>
                {on() ? "[x]" : "[ ]"} {row.id}
              </text>
              <text fg={row.state === "other" ? style.theme.warn : style.theme.dim}>
                {" "}
                {stateLabel(row.state)}
              </text>
              <text fg={style.theme.dim}>
                {"  "}
                {row.uses} uses
                {row.uses > 0 ? ` · ${Math.round((row.ok / row.uses) * 100)}% ok` : ""}
              </text>
            </box>
          )
        }}
      </For>
      <Show when={tools().length === 0}>
        <text fg={style.theme.dim}>
          no extension has an active version · `a` on the id list points `current` at one
        </text>
      </Show>
    </box>
  )

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve}>
        extensions · {extensions().length} · {quota()}
      </text>
      <box height={1} />

      {/* Two of the four panes share the id list / detail split; the other two
          are whole-width tables of their own. */}
      <Show
        when={pane() === "extensions" || pane() === "versions"}
        fallback={pane() === "tools" ? <ToolsPane /> : <UsageTable rows={usage()} />}
      >
        <box flexDirection="row" width="100%" flexGrow={1}>
          <box flexDirection="column" width={34} flexShrink={0}>
            <For each={extensions()}>
              {(entry, index) => {
                const here = () => index() === cursor()
                return (
                  <box
                    flexDirection="row"
                    backgroundColor={here() && pane() === "extensions" ? style.theme.selection : undefined}
                  >
                    <text fg={entry.shadowed ? style.theme.dim : here() ? style.theme.fg : style.theme.dim}>
                      {here() ? style.glyphs.foldOpen : " "} {entry.id}
                    </text>
                    <text fg={style.theme.dim}>
                      {" "}
                      {entry.versions.length}v {entry.kind.slice(0, 4)}
                    </text>
                    {/* What the SOURCE beside those versions would build to. An
                        id whose draft has moved on shows `not built` here while
                        its old version is still current — the difference `ext
                        sync` is for. */}
                    <Show when={draftColumn(draftOf(entry.id))}>
                      <text fg={draftColumn(draftOf(entry.id)) === "active" ? style.theme.dim : style.theme.warn}>
                        {" "}
                        {draftColumn(draftOf(entry.id))}
                      </text>
                    </Show>
                    {/* An id an earlier root already has active: this copy never
                        runs (DESIGN §7.2). Saying so is the whole point — a
                        silently omitted duplicate is how it becomes a mystery. */}
                    <Show when={entry.shadowed}>
                      <text fg={style.theme.warn}> shadowed</text>
                    </Show>
                  </box>
                )
              }}
            </For>
            <Show when={extensions().length === 0}>
              <text fg={style.theme.dim}>no extensions built yet</text>
            </Show>
          </box>

          <box flexDirection="column" flexGrow={1} flexShrink={1} flexBasis={0} paddingLeft={2}>
            <Show when={selected()} keyed>
              {(entry: ExtensionEntry) => (
                <box flexDirection="column">
                  <text fg={style.theme.fg}>
                    {entry.id} · {entry.kind} · current {entry.current ?? "(none)"}
                  </text>
                  <text fg={entry.shadowed ? style.theme.warn : style.theme.dim}>
                    root {entry.root}
                    {entry.shadowed ? " · shadowed by an earlier root · never runs" : ""}
                  </text>
                  <text fg={style.theme.dim}>
                    tools {entry.tools.join(" ") || "—"} · skills{" "}
                    {entry.skills.map((skill: string) => skill.split("/").pop()).join(" ") || "—"} · prompts{" "}
                    {entry.systemPrompts.length || "—"}
                  </text>
                  <text fg={style.theme.dim}>
                    permissions fs {entry.permissions.fs.length} · net {entry.permissions.network.join(",") || "—"} ·
                    proc {entry.permissions.process.length}
                  </text>
                  <Show when={drift()}>
                    <text fg={style.theme.warn}>{drift()}</text>
                  </Show>
                  <box height={1} />

                  <text fg={style.theme.dim}>versions</text>
                  <For each={entry.versions}>
                    {(version, index) => {
                      const here = () => index() === versionCursor() && pane() === "versions"
                      const isCurrent = () => version.version === entry.current
                      const isFrozen = () => version.version === frozenVersion(props.header, entry.id)
                      return (
                        <box flexDirection="row" backgroundColor={here() ? style.theme.selection : undefined}>
                          <text fg={isCurrent() ? style.theme.accent.evolve : style.theme.dim}>
                            {here() ? style.glyphs.foldOpen : " "} {version.version}
                          </text>
                          <text fg={style.theme.dim}> {new Date(version.mtime).toISOString().slice(0, 16)}</text>
                          <Show when={isCurrent()}>
                            <text fg={style.theme.accent.evolve}> {style.glyphs.capability} current</text>
                          </Show>
                          <Show when={isFrozen()}>
                            <text fg={style.theme.accent.user}> {style.glyphs.bar} this session</text>
                          </Show>
                        </box>
                      )
                    }}
                  </For>
                  <box height={1} />

                  <text fg={style.theme.dim}>usage</text>
                  <For each={entry.tools}>
                    {(tool) => {
                      const row = () => usageOf(entry, tool)
                      return (
                        <text fg={style.theme.dim}>
                          {"  "}
                          {tool} · {row()?.uses ?? 0} uses ·{" "}
                          {row() && row()!.uses > 0 ? `${Math.round((row()!.ok / row()!.uses) * 100)}% ok` : "—"}
                        </text>
                      )
                    }}
                  </For>
                </box>
              )}
            </Show>
          </box>
        </box>
      </Show>

      <Show when={confirm()} keyed>
        {(pending: Pending) => <text fg={style.theme.warn}>{confirmLine(pending)}</text>}
      </Show>
      <Show when={notice() && !confirm()}>
        <text fg={style.theme.dim}>{notice()}</text>
      </Show>
      {/* The sister sentence of the drift line: every key in this view moves a
          pointer or a pin, and physics #2 says none of them can reach the
          session already on screen. Said once, permanently, rather than after
          each action. */}
      <text fg={style.theme.warn}>changes apply to the NEXT session — this one froze its tools at start</text>
      <text fg={style.theme.dim}>
        j/k move · Tab pane · t tools · u usage · Space pin · A always · Esc close
      </text>
      <text fg={style.theme.dim}>a activate · r rollback · d deactivate · p prune old versions</text>
    </box>
  )
}
