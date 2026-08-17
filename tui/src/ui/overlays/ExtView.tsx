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
 */
import { For, Show, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import { useStyle } from "../../render/theme.ts"
import { listExtensions, readToolUsage, type ExtensionEntry, type ToolUsage } from "../../nulya/files.ts"
import { extPrune, extSetCurrent, type SyncLine } from "../../nulya/cli.ts"
import { draftColumn, planStore } from "../../extensions.ts"
import { UsageTable } from "./UsageTable.tsx"
import type { Workspace } from "../../nulya/bin.ts"
import type { SessionHeader } from "../../nulya/ledger.ts"

type Pane = "extensions" | "versions" | "usage"

/** An action waiting for `y`: pointer moves, and the one deletion. */
type Pending =
  | { kind: "activate" | "rollback"; id: string; version: string }
  | { kind: "prune"; id: string; version: string; count: number }

function confirmLine(pending: Pending): string {
  if (pending.kind === "prune") {
    return `prune ${pending.id}: delete ${pending.count} version(s), keep ${pending.version}? y / Esc`
  }
  return `${pending.kind} ${pending.id} ${pending.version}? y / Esc`
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
  onClose: () => void
}) {
  const style = useStyle()
  const [extensions, setExtensions] = createSignal<ExtensionEntry[]>([])
  const [usage, setUsage] = createSignal<ToolUsage[]>([])
  const [cursor, setCursor] = createSignal(0)
  const [versionCursor, setVersionCursor] = createSignal(0)
  const [pane, setPane] = createSignal<Pane>("extensions")
  const [notice, setNotice] = createSignal<string | null>(null)
  const [drafts, setDrafts] = createSignal<SyncLine[]>([])
  const [confirm, setConfirm] = createSignal<Pending | null>(null)

  const refresh = async () => {
    setExtensions(await listExtensions(props.ws))
    setUsage(await readToolUsage(props.ws))
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
    }
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

  const runConfirmed = async () => {
    const pending = confirm()
    setConfirm(null)
    if (!pending) return
    try {
      if (pending.kind === "prune") {
        // Deleting a version is the one action here that cannot be undone by
        // moving a pointer, so the kernel's own sentence about the cost is what
        // gets shown rather than a cheerful count of freed bytes.
        const output = await extPrune(props.ws, { id: pending.id })
        setNotice(output.split("\n").slice(-2).join(" · "))
      } else {
        // A store action, not a session event: it changes what the NEXT session
        // freezes and nothing about this one (DESIGN §7.5), so it never touches
        // the ledger and its output stays here.
        setNotice(await extSetCurrent(props.ws, pending.kind, pending.id, pending.version))
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
      setPane(pane() === "extensions" ? "versions" : pane() === "versions" ? "usage" : "extensions")
      return
    }
    if (key.name === "j" || key.name === "down") return move(1)
    if (key.name === "k" || key.name === "up") return move(-1)
    if (key.name === "a") return act("activate")
    if (key.name === "r") return act("rollback")
    if (key.name === "p") return prune()
    if (key.name === "u") return setPane(pane() === "usage" ? "extensions" : "usage")
  })

  return (
    <box flexDirection="column" width="100%" flexGrow={1} paddingLeft={1} paddingRight={1}>
      <text fg={style.theme.accent.evolve}>extensions · {extensions().length}</text>
      <box height={1} />

      <Show when={pane() !== "usage"} fallback={<UsageTable rows={usage()} />}>
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
      <text fg={style.theme.dim}>
        j/k move · Tab pane · a activate · r rollback · p prune old versions · u usage · Esc close
      </text>
    </box>
  )
}
