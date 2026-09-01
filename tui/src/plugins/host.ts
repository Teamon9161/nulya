/**
 * The plugin host: loading a package's `contributes.ui.tui` module and giving
 * it the one narrow API it gets (tui-plugin U3, contract in
 * `tui/plugin-api.d.ts`).
 *
 * ── WHAT LOADING IS, AND IS NOT ───────────────────────────────────────────
 *
 * Running an extension's code on this machine is not a new authority (D4): a
 * package's own binary already runs whenever anybody calls `ext run`, and the
 * decision to let a store take part at all is the kernel's trust gate (DESIGN
 * §9). So there is no second gate here. What in-process code DOES add is the
 * ability to draw things on a screen a person trusts — so the host, not the
 * plugin, owns every surface where a mistake would be expensive: the approval
 * dialog, the mode picker, `/provider`'s key field are never reachable, and a
 * plugin panel always carries a host-drawn line naming the package.
 *
 * ── ONE LOADER, TWO PRODUCTS ──────────────────────────────────────────────
 *
 * `await import(<absolute path to a .ts file>)` works identically under `bun
 * run src/main.tsx` and inside a `bun build --compile` executable — verified
 * before this file was written (tui-plugin §6, U3's first task). So there is
 * ONE code path here and no transpile fallback: a loader that behaved
 * differently in the two products would be a bug wearing a feature's clothes.
 * Bun erases type-only imports, which is why a plugin may write `import type
 * { PluginApi } from "nulya-tui/plugin-api"` without that specifier ever
 * resolving where it is installed.
 *
 * ── FAILURE IS ORDINARY ───────────────────────────────────────────────────
 *
 * An `api` version this build does not implement, a syntax error, an
 * `activate` that throws, a `render` that throws: each is one warning line and
 * that package's UI is skipped. Its OTHER contributions — tools, skills,
 * prompts, declared commands, policy, render hints — are untouched, because
 * they are JSON the kernel froze and have nothing to do with this file. One
 * bad plugin never takes the front end down (D10).
 *
 * ── WHEN A SURFACE REPAINTS ───────────────────────────────────────────────
 *
 * A plugin's renderers are plain functions with their own memory, so the host
 * has to be told when their answer changed. `bump()` is that signal, and it is
 * raised after everything that could plausibly have changed one: a key a
 * plugin handled, an observed line delivered, `notice`, `state.set`, a panel
 * opening or closing, and a command finishing.
 */
import { existsSync } from "node:fs"
import { join } from "node:path"
import { createSignal, type Accessor } from "solid-js"
import { extList, extRun, type StepLine, type StreamLine } from "../nulya/cli.ts"
import { listExtensions, packageDirOf, readContributions, storeRoots, type Contributions } from "../nulya/files.ts"
import { samePath, storeTrusted, workspaceStorePath } from "../extensions.ts"
import { pluginState, rememberPluginState } from "../state/tui_state.ts"
import { builtin_names } from "../commands.ts"
import type { Workspace } from "../nulya/bin.ts"
import type {
  CardRenderer,
  CommandContext,
  CommandSpec,
  LedgerEventView,
  Line,
  LineRenderer,
  PanelHandle,
  PanelSpec,
  PluginApi,
  PluginKey,
  SessionView,
  StreamLineView,
  TaskView,
  UserTurnRenderer,
} from "nulya-tui/plugin-api"

/**
 * The newest API major this build implements. A package declares its own in
 * `contributes.ui.tui.api`; unsupported majors are warn-and-skip (D10). API 2
 * is backwards-compatible with API 1 because API 1 plugins only return rows,
 * which remain a legal API 2 surface.
 */
export const plugin_api_version = 2
export const supported_plugin_api_versions: ReadonlySet<number> = new Set([1, plugin_api_version])

/** Where a workspace store root is spelled in `ext list` output. */
const workspace_root_spec = ".nulya/extensions"

/** One package this process has loaded, and what it is allowed to touch. */
export interface LoadedPlugin {
  id: string
  version: string
  /** The tools its FROZEN manifest declares — the gate on `registerCard`/`extRun` (D11). */
  tools: readonly string[]
  /** Absolute path of the module that was imported. */
  entry: string
}

export interface PluginCommandRow {
  /** The package that registered it. */
  pkg: string
  name: string
  description: string
  run(ctx: CommandContext): void | Promise<void>
}

export interface PluginCard {
  pkg: string
  tool: string
  renderer: CardRenderer
}

export interface PluginWidget {
  pkg: string
  renderer: LineRenderer
}

export interface PluginUserTurn {
  pkg: string
  renderer: UserTurnRenderer
}

/** The panel currently on screen: which package's, and how to draw it. */
export interface OpenPanel {
  pkg: string
  spec: PanelSpec
}

/**
 * What the screen has to lend the host. Every one of these is a verb `App`
 * already performs for a person (D5) — this interface exists so the host does
 * not reach into the tab store, and so a test can drive it without a screen.
 */
export interface PluginHostSeams {
  ws: Workspace
  /** `[extensions] plugins`. False means nothing here ever loads. */
  enabled: boolean
  /** Where `api.state` is remembered; tests point it elsewhere. */
  statePath?: string
  env?: Record<string, string | undefined>
  /**
   * The frozen composition members of every open session tab — the "worn this
   * session" half of the load set. A session that exists at all implies its
   * workspace store was trusted, because the kernel refuses to create one
   * otherwise, so these need no separate trust check.
   */
  members?: () => readonly Pick<Contributions, "id" | "version">[]
  session: () => SessionView | null
  tasks: () => TaskView[]
  /** `session append`, wrapped in the plugin sentinel (`extnote.ts`). */
  appendNote: (pkg: string, kind: string, text: string) => Promise<void>
  openTab: (sessionId: string, options?: { wakePending?: boolean }) => void
  wearNext: (id: string) => void
  notice: (text: string) => void
  /**
   * Whether a TRUSTED ZONE is up: the approval dialog, the permission-mode
   * picker, `/provider`'s key field (D4). While one is, a plugin panel neither
   * shows nor receives keys — a queued `open()` simply waits.
   */
  zoneBusy: () => boolean
}

export interface PluginHost {
  /** Load every eligible package that is not loaded yet. Safe to call again. */
  load(): Promise<void>
  loaded: Accessor<readonly LoadedPlugin[]>
  /** One line per package that could not be used, and why. */
  warnings: Accessor<readonly string[]>
  commands: Accessor<readonly PluginCommandRow[]>
  cardFor(tool: string): PluginCard | null
  /** First package matcher in load order, or null. */
  userTurnFor(text: string): PluginUserTurn | null
  /** Display-only session title supplied by the matching package, or null. */
  sessionTitle(text: string): string | null
  widgets: Accessor<readonly PluginWidget[]>
  /** Package ids that registered a code widget — their own `panel: true` rows stand down. */
  widgetPackages: Accessor<ReadonlySet<string>>
  /** The panel to draw, or null (including while a trusted zone holds it back). */
  panel: Accessor<OpenPanel | null>
  closePanel(): void
  /** True when a plugin panel used the key. `Ctrl+C` never reaches one. */
  handleKey(key: PluginKey): boolean
  /** Every `--stream` line and ledger event of a step this front end drives. */
  observe(line: StepLine, session: string): void
  /** Tell plugins when the front session, its permission mode, or its writer role changed. */
  observeSession(session: SessionView | null): void
  /** Bumped whenever a surface's answer may have changed; surfaces read it. */
  revision: Accessor<number>
}

/** OpenTUI's key event, narrowed to what a plugin is told (contract `PluginKey`). */
export function pluginKeyOf(key: {
  name?: string
  ctrl?: boolean
  shift?: boolean
  meta?: boolean
  sequence?: string
}): PluginKey {
  const text = printableOf(key)
  return {
    name: key.name ?? "",
    ctrl: key.ctrl ?? false,
    shift: key.shift ?? false,
    meta: key.meta ?? false,
    ...(text !== null ? { text } : {}),
  }
}

/**
 * The character a keypress produced, or null when it produced none.
 *
 * `PluginKey.name` is a key's IDENTITY — lower-cased, shared by `a` and `A`,
 * and a word (`escape`, `pageup`) for keys that are not characters. A panel
 * that lets somebody write needs the byte instead, and reconstructing it from
 * `name` + `shift` is a keyboard-layout guess (`shift+3` is `#` on one layout
 * and `£` on another). OpenTUI already parsed the real bytes into `sequence`,
 * so the rule is simply: one printable character, and no modifier that turns a
 * keypress into a command.
 */
function printableOf(key: { sequence?: string; ctrl?: boolean; meta?: boolean }): string | null {
  if (key.ctrl || key.meta) return null
  const seq = key.sequence
  if (typeof seq !== "string" || seq.length === 0) return null
  // One code point, and not a control character: `\r`, `\t`, `\x1b[A` and every
  // escape sequence fall out here, and they all have a `name` of their own.
  const points = [...seq]
  if (points.length !== 1) return null
  const code = seq.codePointAt(0)
  if (code === undefined || code < 0x20 || code === 0x7f) return null
  return seq
}

/**
 * The module's `activate`, whichever of the three shapes the contract allows
 * it to arrive in. Null when the module exports nothing callable — which is a
 * warning, not a crash: a package may ship an entry that is not a plugin yet.
 */
function activateOf(mod: unknown): ((api: PluginApi) => void | Promise<void>) | null {
  if (typeof mod !== "object" || mod === null) return null
  const record = mod as Record<string, unknown>
  if (typeof record["activate"] === "function") {
    return record["activate"] as (api: PluginApi) => void | Promise<void>
  }
  const fallback = record["default"]
  if (typeof fallback === "function") return fallback as (api: PluginApi) => void | Promise<void>
  if (typeof fallback === "object" && fallback !== null) {
    const nested = (fallback as Record<string, unknown>)["activate"]
    if (typeof nested === "function") return nested as (api: PluginApi) => void | Promise<void>
  }
  return null
}

/** A package eligible for loading: id, the version to load, and what it declares. */
export interface PluginCandidate {
  id: string
  version: string
  entry: string
  api: number
  tools: readonly string[]
}

/**
 * Which packages a load pass considers: ACTIVATED (a `current` version, not
 * shadowed, and — for the workspace root — trusted) plus every package a
 * session in this process is WEARING.
 *
 * Both halves matter and neither implies the other. A package that is built
 * and activated but in no session still gets to offer its `/command` — that is
 * how a mode becomes reachable at all; and a package brought in with `--with`
 * at a version the store's `current` no longer names is what this session is
 * actually running, so its plugin has to be the version frozen with it.
 */
export async function pluginCandidates(
  ws: Workspace,
  members: readonly Pick<Contributions, "id" | "version">[] = [],
  env: Record<string, string | undefined> = process.env,
): Promise<PluginCandidate[]> {
  const wanted: { id: string; version: string }[] = []
  try {
    const trusted = storeTrusted(workspaceStorePath(ws), env)
    for (const entry of await listExtensions(ws)) {
      if (entry.current === null || entry.shadowed) continue
      if (entry.root === workspace_root_spec && !trusted) continue
      wanted.push({ id: entry.id, version: entry.current })
    }
  } catch {
    // No binary, no store: only what sessions are wearing, which came from a
    // header this process already read.
  }
  for (const member of members) {
    if (!wanted.some((one) => one.id === member.id && one.version === member.version)) {
      wanted.push({ id: member.id, version: member.version })
    }
  }
  if (wanted.length === 0) return []
  const roots = await storeRoots(ws)
  const out: PluginCandidate[] = []
  for (const one of wanted) {
    const contributions = await readContributions(ws, one.id, one.version, roots)
    // No entry for this front end is an ordinary answer, not a warning: the
    // manifest keys `ui` by host, and a package may ship modules for others.
    if (!contributions.ui) continue
    const dir = packageDirOf(roots, one.id, one.version)
    if (dir === null) continue
    out.push({
      id: one.id,
      version: one.version,
      // The kernel checked at build time that this path is safe and present
      // (`build_ext.validateUi`), and froze the bytes with the version.
      entry: `${dir}/${contributions.ui.entry}`,
      api: contributions.ui.api,
      tools: contributions.tools,
    })
  }
  return out
}

/**
 * Entry paths whose FIRST `import()` failed, and what it said.
 *
 * Module-level, not per host, because the thing it is about is: JavaScript's
 * module registry is the process's. Measured on Bun 1.3.5, a second `import()`
 * of a module whose first import failed to PARSE never settles — so a second
 * host in one process (only tests build one, but the rule has to hold anyway)
 * must not reach for it again. The message is kept so that host still reports
 * the failure rather than being quietly missing a package.
 */
const import_failures = new Map<string, string>()

export function createPluginHost(seams: PluginHostSeams): PluginHost {
  const [loaded, setLoaded] = createSignal<readonly LoadedPlugin[]>([])
  const [warnings, setWarnings] = createSignal<readonly string[]>([])
  const [commands, setCommands] = createSignal<readonly PluginCommandRow[]>([])
  const [cards, setCards] = createSignal<readonly PluginCard[]>([])
  const [userTurns, setUserTurns] = createSignal<readonly PluginUserTurn[]>([])
  const [widgets, setWidgets] = createSignal<readonly PluginWidget[]>([])
  const [revision, setRevision] = createSignal(0)
  /** Which panel a plugin has asked to be on screen, before the zone is consulted. */
  const [wanted, setWanted] = createSignal<OpenPanel | null>(null)

  const streamObservers: { pkg: string; cb: (line: StreamLineView, session: string) => void }[] = []
  const eventObservers: {
    pkg: string
    cb: (event: LedgerEventView, session: string, source: "live" | "replay") => void
  }[] = []
  const sessionObservers: {
    pkg: string
    cb: (session: SessionView | null) => void
    key: string | null
  }[] = []
  let frontSessionKey: string | null | undefined
  const reportedMatcherFailures = new Set<string>()
  const reportedMatcherConflicts = new Set<string>()

  const bump = () => setRevision((at) => at + 1)

  const warn = (line: string) => setWarnings((all) => [...all, line])

  /** Everything one package registered, undone — for an `activate` that threw. */
  const rollback = (pkg: string) => {
    setCommands((all) => all.filter((row) => row.pkg !== pkg))
    setCards((all) => all.filter((row) => row.pkg !== pkg))
    setUserTurns((all) => all.filter((row) => row.pkg !== pkg))
    setWidgets((all) => all.filter((row) => row.pkg !== pkg))
    for (const list of [streamObservers, eventObservers]) {
      for (let at = list.length - 1; at >= 0; at--) if (list[at]!.pkg === pkg) list.splice(at, 1)
    }
    for (let at = sessionObservers.length - 1; at >= 0; at--) {
      if (sessionObservers[at]!.pkg === pkg) sessionObservers.splice(at, 1)
    }
    setWanted((open) => (open?.pkg === pkg ? null : open))
  }

  /**
   * The API one package gets. Every method that could name something outside
   * the package checks that it does not: `registerCard` and `extRun` against
   * the frozen tool list, `appendNote` against the package's own id, which is
   * filled in here rather than passed.
   */
  function apiFor(plugin: LoadedPlugin): PluginApi {
    const pkg = plugin.id

    const guardTool = (tool: string, what: string) => {
      if (plugin.tools.includes(tool)) return
      throw new Error(
        `${pkg} cannot ${what} '${tool}': its frozen manifest declares ${
          plugin.tools.length > 0 ? plugin.tools.join(", ") : "no tools"
        }`,
      )
    }

    return {
      pkg: { id: plugin.id, version: plugin.version },

      registerCommand(spec: CommandSpec) {
        const name = spec.name.trim()
        if (name.length === 0) throw new Error(`${pkg} registered a command with no name`)
        if (builtin_names.has(name)) {
          // A built-in is never taken from a person (D8). Said rather than
          // thrown: the rest of the package is fine, and the plugin author
          // deserves to know why nothing happened.
          warn(`${pkg}: '/${name}' is a built-in command and cannot be replaced`)
          return
        }
        setCommands((all) => [
          // Same package, same name: the code version replaces the one this
          // package DECLARED in its manifest — and replaces an earlier code
          // registration too, since a package registering twice meant the
          // second one (tui-plugin §5, open question 2).
          ...all.filter((row) => !(row.pkg === pkg && row.name === name)),
          { pkg, name, description: spec.description, run: spec.run },
        ])
      },

      registerCard(tool: string, renderer: CardRenderer) {
        // Throws, deliberately: drawing another package's call is display
        // spoofing (D11), and a plugin that tried is a plugin whose whole
        // activation is rolled back rather than half-honoured.
        guardTool(tool, "draw a card for")
        setCards((all) => [...all.filter((row) => !(row.pkg === pkg && row.tool === tool)), { pkg, tool, renderer }])
      },

      registerUserTurn(renderer: UserTurnRenderer) {
        const id = renderer.id.trim()
        if (id.length === 0) throw new Error(`${pkg} registered a user-turn renderer with no id`)
        setUserTurns((all) => [
          ...all.filter((row) => !(row.pkg === pkg && row.renderer.id === id)),
          { pkg, renderer: { ...renderer, id } },
        ])
      },

      registerPanel(spec: PanelSpec): PanelHandle {
        const entry: OpenPanel = { pkg, spec }
        return {
          open() {
            // While a trusted zone is up this only queues: `panel()` consults
            // the zone, so the panel appears the moment the zone clears and
            // there is nothing here for a plugin to detect or defeat (D4).
            setWanted(entry)
            bump()
          },
          close() {
            if (wanted() !== entry) return
            setWanted(null)
            try {
              spec.onClose?.()
            } catch (error) {
              warn(`${pkg}: onClose threw · ${message(error)}`)
            }
            bump()
          },
          isOpen: () => wanted() === entry && !seams.zoneBusy(),
        }
      },

      registerWidget(spec: LineRenderer) {
        setWidgets((all) => [...all.filter((row) => row.pkg !== pkg), { pkg, renderer: spec }])
      },

      observe: {
        onStream(cb) {
          const entry = { pkg, cb }
          streamObservers.push(entry)
          return () => {
            const at = streamObservers.indexOf(entry)
            if (at >= 0) streamObservers.splice(at, 1)
          }
        },
        onEvent(cb) {
          const entry = { pkg, cb }
          eventObservers.push(entry)
          return () => {
            const at = eventObservers.indexOf(entry)
            if (at >= 0) eventObservers.splice(at, 1)
          }
        },
        onSession(cb) {
          const current = seams.session()
          const entry = { pkg, cb, key: sessionObservationKey(current) }
          sessionObservers.push(entry)
          try {
            cb(current)
          } catch (error) {
            warn(`${pkg}: onSession threw · ${message(error)}`)
          }
          return () => {
            const at = sessionObservers.indexOf(entry)
            if (at >= 0) sessionObservers.splice(at, 1)
          }
        },
        tasks: () => seams.tasks(),
        session: () => seams.session(),
      },

      actions: {
        appendNote: (kind, text) => seams.appendNote(pkg, kind, text),
        async extRun(tool, args) {
          guardTool(tool, "run")
          return await extRun(seams.ws, `${plugin.id}@${plugin.version}`, tool, args)
        },
        extRunPackage: (ref, tool, args) => runPackageTool(ref, tool, args),
        openTab: (sessionId, options) => seams.openTab(sessionId, options),
        wearNext: (id) => seams.wearNext(id),
      },

      state: {
        get<T = unknown>(key: string): T | undefined {
          return pluginState(pkg, seams.statePath)[key] as T | undefined
        },
        set(key: string, value: unknown) {
          rememberPluginState(pkg, { ...pluginState(pkg, seams.statePath), [key]: value }, seams.statePath)
          bump()
        },
      },

      notice(text: string) {
        seams.notice(text)
        bump()
      },
    }
  }

  async function runPackageTool(ref: string, tool: string, args: Record<string, unknown>) {
    const trimmed = ref.trim()
    const split = trimmed.lastIndexOf("@")
    const id = split > 0 ? trimmed.slice(0, split) : trimmed
    let version = split > 0 ? trimmed.slice(split + 1) : ""
    if (id.length === 0 || (split > 0 && version.length === 0)) throw new Error(`invalid package ref '${ref}'`)

    if (version.length === 0) {
      const effective = (await extList(seams.ws)).find((entry) => entry.id === id && !entry.shadowed)
      if (!effective || effective.current === null) {
        throw new Error(`${id} has no current version · build and activate it, then try again`)
      }
      version = effective.current
    }

    const roots = await storeRoots(seams.ws)
    const dir = packageDirOf(roots, id, version)
    if (dir === null) throw new Error(`${id}@${version} is not built in an effective extension store`)
    const selectedRoot = roots.find((root) => existsSync(join(root, id, "versions", version, "package")))
    if (selectedRoot && samePath(selectedRoot, workspaceStorePath(seams.ws)) && !storeTrusted(selectedRoot, seams.env)) {
      throw new Error(`${id}@${version} is in an untrusted workspace store · trust the store, then try again`)
    }
    const contributions = await readContributions(seams.ws, id, version, roots)
    if (!contributions.internalTools.includes(tool)) {
      throw new Error(`${id}@${version} cannot run '${tool}' here: its frozen manifest does not declare it internal`)
    }
    return await extRun(seams.ws, `${id}@${version}`, tool, args)
  }

  /**
   * Every `<id>@<version>` a pass has already tried, however it went.
   *
   * Not the same set as `loaded()`, and the difference is load-bearing twice
   * over. A package that was skipped (wrong API version) or that failed
   * (unparseable, `activate` threw) must not be tried again by the next pass:
   * it would re-warn on every `/ext` toggle, and — measured on Bun 1.3.5 — a
   * second `import()` of a module whose FIRST import failed to parse never
   * settles at all, so a retry does not merely repeat the failure, it hangs
   * the pass and everything chained behind it.
   */
  const attempted = new Set<string>()

  async function loadOne(candidate: PluginCandidate): Promise<void> {
    if (!supported_plugin_api_versions.has(candidate.api)) {
      warn(
        `${candidate.id}: its front-end module wants plugin API ${candidate.api}, this build supports ${[...supported_plugin_api_versions].join(", ")} · skipped`,
      )
      return
    }
    const failed = import_failures.get(candidate.entry)
    if (failed !== undefined) {
      warn(`${candidate.id}: its front-end module did not load · ${failed}`)
      return
    }
    let mod: unknown
    try {
      mod = await import(candidate.entry)
    } catch (error) {
      import_failures.set(candidate.entry, message(error))
      warn(`${candidate.id}: its front-end module did not load · ${message(error)}`)
      return
    }
    const activate = activateOf(mod)
    if (!activate) {
      warn(`${candidate.id}: ${candidate.entry} exports no \`activate\` · skipped`)
      return
    }
    const plugin: LoadedPlugin = {
      id: candidate.id,
      version: candidate.version,
      tools: candidate.tools,
      entry: candidate.entry,
    }
    // Marked loaded BEFORE `activate` runs: the module HAS run either way, and
    // a package whose `activate` threw must show up in `loaded()` so nothing
    // later mistakes it for one that was never reached.
    setLoaded((all) => [...all, plugin])
    try {
      await activate(apiFor(plugin))
    } catch (error) {
      rollback(candidate.id)
      warn(`${candidate.id}: activate threw · ${message(error)}`)
      return
    }
    bump()
  }

  let loading: Promise<void> | null = null

  /** Take the panel down and tell its plugin. The one place that does both. */
  function closePanel(): void {
    const open = wanted()
    if (!open) return
    setWanted(null)
    try {
      open.spec.onClose?.()
    } catch (error) {
      warn(`${open.pkg}: onClose threw · ${message(error)}`)
    }
    bump()
  }

  return {
    load() {
      if (!seams.enabled) return Promise.resolve()
      // One pass at a time: `/ext` and the first session can both ask, and two
      // overlapping passes would import the same module twice and call its
      // `activate` twice with two different API objects.
      loading = (loading ?? Promise.resolve()).then(async () => {
        let candidates: PluginCandidate[] = []
        try {
          candidates = await pluginCandidates(seams.ws, seams.members?.() ?? [], seams.env)
        } catch (error) {
          warn(`the extension store could not be read for plugins · ${message(error)}`)
          return
        }
        for (const candidate of candidates) {
          // Loading is one-way for the life of a process: a module that has run
          // has run, and "unloading" it is not a thing JavaScript offers. A
          // package deactivated now keeps its surfaces until the next start,
          // which is honest and is what `/ext` says about a mode package too.
          const ref = `${candidate.id}@${candidate.version}`
          if (attempted.has(ref)) continue
          attempted.add(ref)
          await loadOne(candidate)
        }
      })
      return loading
    },
    loaded,
    warnings,
    commands,
    cardFor(tool) {
      return cards().find((row) => row.tool === tool) ?? null
    },
    userTurnFor(text) {
      const matches: PluginUserTurn[] = []
      for (const row of userTurns()) {
        try {
          if (row.renderer.match(text)) matches.push(row)
        } catch (error) {
          const key = `${row.pkg}\0${row.renderer.id}`
          if (!reportedMatcherFailures.has(key)) {
            reportedMatcherFailures.add(key)
            warn(`${row.pkg}: user-turn matcher '${row.renderer.id}' threw · ${message(error)}`)
          }
        }
      }
      if (matches.length > 1) {
        const key = matches.map((row) => `${row.pkg}:${row.renderer.id}`).join("|")
        if (!reportedMatcherConflicts.has(key)) {
          reportedMatcherConflicts.add(key)
          warn(`multiple user-turn renderers matched; using ${matches[0]!.pkg}:${matches[0]!.renderer.id} · ${key}`)
        }
      }
      return matches[0] ?? null
    },
    sessionTitle(text) {
      const row = this.userTurnFor(text)
      if (!row?.renderer.sessionTitle) return null
      try {
        return row.renderer.sessionTitle(text)
      } catch (error) {
        const key = `${row.pkg}\0${row.renderer.id}\0title`
        if (!reportedMatcherFailures.has(key)) {
          reportedMatcherFailures.add(key)
          warn(`${row.pkg}: session-title formatter '${row.renderer.id}' threw · ${message(error)}`)
        }
        return null
      }
    },
    widgets,
    widgetPackages: () => new Set(widgets().map((row) => row.pkg)),
    panel: () => (seams.zoneBusy() ? null : wanted()),
    closePanel,
    handleKey(key) {
      if (key.ctrl && key.name === "c") return false
      const open = wanted()
      if (!open || seams.zoneBusy()) return false
      // `Esc` takes the panel down, always. A plugin may see it first and use
      // it for something of its own (clearing a selection), but a panel that
      // could swallow the only key that closes it would be a panel a person
      // cannot leave.
      let used = false
      try {
        used = open.spec.onKey?.(key) === true
      } catch (error) {
        warn(`${open.pkg}: onKey threw · ${message(error)}`)
      }
      bump()
      if (used) return true
      if (key.name === "escape") {
        closePanel()
        return true
      }
      // Everything else is consumed while the panel is up: it owns the
      // keyboard, exactly as the approval dialog and the pickers do (D6).
      return true
    },
    observe(line, session) {
      if (line.kind === "stream") {
        if (streamObservers.length === 0) return
        for (const observer of [...streamObservers]) {
          try {
            observer.cb(line.line as StreamLine as StreamLineView, session)
          } catch (error) {
            warn(`${observer.pkg}: onStream threw · ${message(error)}`)
          }
        }
        bump()
        return
      }
      if (eventObservers.length === 0) return
      for (const observer of [...eventObservers]) {
        try {
          observer.cb(line.event as unknown as LedgerEventView, session, "live")
        } catch (error) {
          warn(`${observer.pkg}: onEvent threw · ${message(error)}`)
        }
      }
      bump()
    },
    observeSession(session) {
      // Status/activity churn is delivered by stream observers. Session
      // observers need identity plus the two explicit policies that decide
      // whether a continuation waits, follows automatically, or stays
      // read-only: permission mode and writer role.
      const key = sessionObservationKey(session)
      if (frontSessionKey === key) return
      frontSessionKey = key
      for (const observer of [...sessionObservers]) {
        if (observer.key === key) continue
        observer.key = key
        try {
          observer.cb(session)
        } catch (error) {
          warn(`${observer.pkg}: onSession threw · ${message(error)}`)
        }
      }
      bump()
    },
    revision,
  }
}

function sessionObservationKey(session: SessionView | null): string | null {
  return session
    ? `${session.id}\u0000${session.permissionMode ?? ""}\u0000${session.role}`
    : null
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** Re-exported so surfaces do not each import from the contract path. */
export type { Line, PluginKey }
