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
 *    `pinned v-a · store v-b → next session`.
 *  - the USAGE table, a plain projection of `.nulya/tool-usage.jsonl`. It does
 *    NOT rank: "who gets promoted next session" is `tool_selection.rank`, a
 *    kernel policy, and a second implementation of it here would drift.
 */
import { For, Show, createMemo, createSignal, onMount } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import { useStyle } from "../../render/theme.ts"
import { listExtensions, readToolUsage, type ExtensionEntry, type ToolUsage } from "../../nulya/files.ts"
import { extSetCurrent } from "../../nulya/cli.ts"
import { UsageTable } from "./UsageTable.tsx"
import type { Workspace } from "../../nulya/bin.ts"
import type { SessionHeader } from "../../nulya/ledger.ts"

type Pane = "extensions" | "versions" | "usage"

/** What the running session froze for this extension, if anything. */
export function frozenVersion(header: SessionHeader | null | undefined, id: string): string | null {
  return header?.composition.active.find((entry) => entry.id === id)?.version ?? null
}

export function driftLine(frozen: string | null, current: string | null): string | null {
  if (!frozen || !current || frozen === current) return null
  return `pinned ${frozen} · store ${current} → next session`
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
  const [confirm, setConfirm] = createSignal<{ verb: "activate" | "rollback"; id: string; version: string } | null>(null)

  const refresh = async () => {
    setExtensions(listExtensions(props.ws))
    setUsage(await readToolUsage(props.ws))
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
    const version = selectedVersion()
    if (!entry || !version) {
      setNotice("no version selected · Tab to the version line first")
      return
    }
    setConfirm({ verb, id: entry.id, version: version.version })
  }

  const runConfirmed = async () => {
    const pending = confirm()
    setConfirm(null)
    if (!pending) return
    try {
      const line = await extSetCurrent(props.ws, pending.verb, pending.id, pending.version)
      // A store action, not a session event: it changes what the NEXT session
      // freezes and nothing about this one (DESIGN §7.5), so it never touches
      // the ledger and its output stays here.
      setNotice(line)
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
                    <text fg={here() ? style.theme.fg : style.theme.dim}>
                      {here() ? style.glyphs.foldOpen : " "} {entry.id}
                    </text>
                    <text fg={style.theme.dim}>
                      {" "}
                      {entry.versions.length}v {entry.kind.slice(0, 4)}
                    </text>
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
                  <text fg={style.theme.dim}>
                    tools {entry.tools.join(" ") || "—"} · skills{" "}
                    {entry.skills.map((skill: string) => skill.split("/").pop()).join(" ") || "—"}
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
        {(pending: { verb: "activate" | "rollback"; id: string; version: string }) => (
          <text fg={style.theme.warn}>
            {pending.verb} {pending.id} {pending.version}? y / Esc
          </text>
        )}
      </Show>
      <Show when={notice() && !confirm()}>
        <text fg={style.theme.dim}>{notice()}</text>
      </Show>
      <text fg={style.theme.dim}>j/k move · Tab pane · a activate · r rollback · u usage table · Esc close</text>
    </box>
  )
}
