/**
 * The nulya TUI plugin host API — version 1.
 *
 * This file is THE CONTRACT. A package declares `contributes.ui.tui = {entry,
 * api}` in its manifest (DESIGN §7.2.1) — the block is keyed by front end, and
 * `tui` is this one's key; the entry is a TypeScript module inside the package
 * that default-exports, or named-exports, an `activate` function. The host
 * imports it and calls `activate(api)` once.
 *
 *     import type { PluginApi } from "nulya-tui/plugin-api"
 *
 *     export function activate(api: PluginApi) {
 *       api.registerWidget({
 *         render: (width) => [[{ text: `hello from ${api.pkg.id}`, token: "dim" }]],
 *       })
 *     }
 *
 * The import above is TYPE-ONLY and is erased before the module ever runs, so
 * the specifier never has to resolve on the machine the plugin is installed
 * on. A plugin must not import anything at run time that is not beside it in
 * its own package: the host's own dependencies (OpenTUI, Solid) are
 * deliberately not reachable, and a bare specifier resolves against the
 * plugin's own directory, not the host's.
 *
 * ── VERSION POLICY ────────────────────────────────────────────────────────
 *
 * `contributes.ui.tui.api` is a single number and it is the MAJOR version of
 * this file. The host loads a module only when that number equals the version it
 * implements (`api === 1` today); anything else is one warning line and a skip
 * — the package's other contributions (tools, skills, prompts, commands,
 * policy, render hints) are unaffected, exactly as an agent definition this
 * build cannot read is skipped rather than fatal.
 *
 * Within a major version this file only ever GROWS: new optional fields, new
 * methods, new theme tokens. A plugin written against 1.0 keeps working
 * against 1.9. Anything that would break an existing plugin — a removed
 * method, a changed argument order, a narrowed return — is a new major, and
 * then both numbers are honoured for as long as it is worth it: the host
 * knows which version a package declared, and that is the whole point of the
 * number being frozen in the manifest.
 *
 * A plugin cannot ask which MINOR it is running against, and does not need to:
 * a build older than a field it wants simply leaves that field `undefined`
 * (`PluginKey.text`) or that method missing, which a plugin already has to
 * tolerate for any optional part of this file. What is here so far:
 *
 *   1.0  the whole of it, as U3 shipped it.
 *   1.1  `PluginKey.text` — the character a key produced, so a panel can accept
 *        typing; and `PluginActions.compact` — `/compact` on the front tab's
 *        session, which is how an approved plan continues in a session that no
 *        longer wears the persona that wrote it (`extensions/plan`).
 *
 * ── WHAT IS DELIBERATELY NOT HERE ─────────────────────────────────────────
 *
 * No component tree, no renderer, no reactive primitive. A plugin renders by
 * returning LINES (tui-plugin D9), which means there is no single-instance
 * problem, no version skew with a UI library, and nothing terminal-specific in
 * this contract beyond the idea of a fixed-width row. The host owns the frame,
 * the folding, the focus, the layout and the mapping from token to colour
 * (which is what makes `NO_COLOR` free).
 *
 * No way to answer the kernel's gate, and no way to write a session file. A
 * plugin changes the world only through the verbs a PERSON already has
 * (`PluginActions`, tui-plugin D5): append a note, run one of its own tools,
 * open a tab, wear a package. Everything the model must see is in the ledger;
 * everything else is a view.
 *
 * ── WHEN A SURFACE IS REDRAWN ─────────────────────────────────────────────
 *
 * A renderer is a plain function over the plugin's own memory, so the host
 * cannot watch that memory and has to be told. It redraws after each of these,
 * which between them cover every way a plugin learns anything: a key `onKey`
 * saw, a line delivered to `observe`, `notice`, `state.set`, a panel opening or
 * closing, and a registered command finishing. If a plugin changes what it
 * would draw from some other asynchronous callback of its own, `notice("")` is
 * not the way to ask for a repaint — do the work in response to an observed
 * line or a key, which is where the information came from anyway.
 */

/** The entry point the host looks for: a named `activate`, or a default export carrying one. */
export type PluginModule =
  | { activate(api: PluginApi): void | Promise<void> }
  | { default: { activate(api: PluginApi): void | Promise<void> } }
  | { default(api: PluginApi): void | Promise<void> }

/**
 * A colour, named by what the text IS rather than by how it should look
 * (`render/theme.ts`). The host maps each to the theme in force, so a plugin
 * is light-, dark- and `NO_COLOR`-correct without knowing any of them.
 *
 *   fg      the thing itself
 *   muted   what the thing is made of — an id beside its label, a count
 *   dim     what is written about it — captions, hints, footers
 *   faint   furniture — an empty gutter, a disabled cell
 *   accent  role colour; only ever a glyph or a head line
 *   ok/err/warn  a verdict, in a chip — never a wash over a whole block
 *
 * Absent means `fg`.
 */
export type ThemeToken =
  | "fg"
  | "muted"
  | "dim"
  | "faint"
  | "accent.user"
  | "accent.assistant"
  | "accent.tool"
  | "accent.evolve"
  | "ok"
  | "err"
  | "warn"

/** A run of text in one colour. */
export interface Span {
  text: string
  token?: ThemeToken
}

/**
 * One row. The host draws spans left to right and does not wrap: a renderer is
 * told the width it has and decides what fits, because only it knows what is
 * worth cutting. Tabs and newlines inside a span are not rows — split them
 * yourself.
 *
 * HEIGHT is the host's, and a renderer is not told it. A panel is capped at
 * half the screen and an opened widget body at a quarter; whatever is past
 * that is not drawn and the host says how many rows it left out. That is not a
 * budget to plan against — it is the guard that keeps a composer-area surface
 * from pushing the transcript it is about off the screen (D6). A renderer with
 * a lot to show should page or fold it ITSELF, using keys of its own.
 */
export type Line = Span[]

/** A host-rendered unified diff surface. Plugins provide data, not components. */
export interface DiffSurface {
  kind: "diff"
  patch: string
  /** Changed file path, when known. The host uses it for labels and syntax hints. */
  path?: string
  /** Syntax highlighter hint for the changed file, e.g. `zig` or `typescript`. */
  filetype?: string
  /** Optional precomputed stats. When absent, the host derives them from `patch`. */
  added?: number
  removed?: number
}

/** Card bodies may return host-owned primitives; composer widgets and panels may not. */
export type Surface = Line[] | DiffSurface

/**
 * A keypress, normalised. `name` is a lower-case key name: a single character
 * (`"a"`, `"1"`), or one of `return` / `escape` / `tab` / `space` /
 * `backspace` / `delete` / `up` / `down` / `left` / `right` / `home` / `end` /
 * `pageup` / `pagedown` / `f1`…`f12`.
 *
 * `ctrl+c` never reaches a plugin: it is how a person stops what is running
 * and then leaves, and no plugin may stand in front of that.
 */
export interface PluginKey {
  name: string
  ctrl: boolean
  shift: boolean
  meta: boolean
  /**
   * The CHARACTER this key produced, when it produced one — `"a"`, `"A"`,
   * `"."`, `"7"` — and absent for every key that is a command rather than a
   * letter (`escape`, `up`, `f3`, anything with `ctrl` or `meta`).
   *
   * Added in 1.1, for the one thing `name` cannot do: a panel that lets a
   * person WRITE. `name` is a key's identity, lower-cased and shared by `a` and
   * `A`; typing needs the byte, and reconstructing it from `name` + `shift` is
   * a keyboard-layout guess. A panel accumulating `key.text` and handling
   * `space` / `backspace` / `return` itself is the whole of a text field here.
   */
  text?: string
}

/** Return `true` from `onKey` to say the key was used; anything else lets the host have it. */
export type KeyResult = boolean | void

/** Which package this API belongs to, at the version the session froze. */
export interface PluginPkg {
  id: string
  version: string
}

/**
 * What a plugin row renderer draws: ordinary rows for a given width, and optionally keys.
 * Diff surfaces are a transcript card primitive; widgets and panels stay rows
 * so a legal plugin cannot return something the host silently drops.
 *
 * `onKey` is called only where the surface actually HOLDS the keyboard, which
 * today is a panel and only a panel (`PanelSpec`). A widget's is not called —
 * a persistent row above the composer competes with the composer for every
 * keystroke, and the composer wins; a widget that needs keys should open a
 * panel from a command.
 */
export interface LineRenderer {
  render(width: number): Line[]
  onKey?(key: PluginKey): KeyResult
}

/** A renderer that may return a host-owned primitive such as a diff. */
export interface SurfaceRenderer {
  render(width: number): Surface
}

/** One tool call, as much of it as a card is allowed to see. */
export interface CardView {
  tool: string
  /** Raw JSON arguments, verbatim — still growing while `state` is `"pending"`. */
  args: string
  /** The recorded result, or `""` before there is one. */
  output: string
  /** UI-only JSON presentation from the tool result. It is never model-visible. */
  presentation: unknown | null
  ok: boolean | null
  state: "pending" | "running" | "done"
}

export interface CardRenderer {
  render(view: CardView, width: number): Surface
  /**
   * NOT CALLED IN 1.0, and it is honest to say so rather than let you wire one
   * up and wonder. A transcript card has no focus of its own here: browse mode
   * owns the keys over cards (`j/k` to move, `Enter`/`Space` to fold), and
   * giving a card its own keyboard means inventing a third focus holder beside
   * the composer and the panel. The declaration stays because that is where
   * the answer belongs when there is a reason for one; until then, a card that
   * needs keys should open a panel.
   */
  onKey?(key: PluginKey): KeyResult
}

/**
 * A panel in the composer area — where the approval dialog and the pickers
 * live (tui-plugin D6). While it is open it holds the keyboard (`Ctrl+C`
 * excepted) and the host draws an attribution row above it saying which
 * package is talking, so a panel can never impersonate the screen itself.
 *
 * `open()` while a TRUSTED ZONE is up — the approval dialog, the permission
 * mode picker, `/provider`'s key field — does not open: the request is
 * remembered and honoured the moment the zone clears (tui-plugin D4). There is
 * no way to detect or defeat that from here, which is the point.
 */
export interface PanelHandle {
  open(): void
  close(): void
  /** Whether the panel is on screen right now (a queued `open()` is not). */
  isOpen(): boolean
}

export interface PanelSpec extends LineRenderer {
  /** Called when the panel comes down, whoever closed it (`Esc`, `close()`, a trusted zone). */
  onClose?(): void
}

/** One package in a session's frozen composition. */
export interface SessionMemberView {
  id: string
  version: string
  tools: string[]
}

/** The session the front tab is on, as a read-only projection. */
export interface SessionView {
  id: string
  /** The model identity frozen at `session new`, or `""` when unknown. */
  model: string
  members: SessionMemberView[]
}

/**
 * A background task of the front tab's session (DESIGN §6.1). The shape is
 * `nulya task list --json`'s own; unknown states are possible and a reader
 * should not switch exhaustively over them.
 */
export interface TaskView {
  /** Full name `<session>/t<N>`. */
  task: string
  state: string
  command: string
  exitCode: number | null
}

/**
 * A `session step --stream` line (DESIGN §14), typed. The union is OPEN on
 * purpose: the kernel may add a stream or an event, and a plugin that
 * `switch`es over `event` must have a default rather than assume this list is
 * final.
 */
export type StreamLineView =
  | { stream: "model"; event: "started" }
  | { stream: "model"; event: "text_delta"; text: string }
  | { stream: "model"; event: "thinking_delta"; text: string }
  | { stream: "model"; event: "tool_use_start"; index: number; id: string; name: string }
  | { stream: "model"; event: "tool_use_input_delta"; index: number; fragment: string }
  | { stream: "model"; event: "done"; stop: string }
  | { stream: "tool"; event: "begin"; call_id: string; tool: string }
  | { stream: "tool"; event: "end"; call_id: string; ok: boolean }
  | { stream: "step"; event: "end"; status: string }
  | { stream: "run"; event: "done"; steps: number; stopped: string }
  | { stream: "run"; event: "error"; message: string }
  | { stream: string; event: string; [field: string]: unknown }

/**
 * A ledger event (DESIGN §3.1), in the shape `session events` prints. Kept
 * open for the same reason the stream union is: the event alphabet is
 * append-only, and a build that refused an unknown `kind` would be a build
 * that stops working when the kernel grows.
 */
export interface LedgerEventView {
  seq: number
  kind: string
  [field: string]: unknown
}

/** Stop receiving. Calling it twice is harmless. */
export type Unsubscribe = () => void

/**
 * Reading the world. Everything here is a projection of what the kernel
 * already wrote or streamed — there is no second source of truth, and nothing
 * a plugin observes can change what the model sees.
 */
export interface PluginObserve {
  /** Every `--stream` line of every step this front end drives, as it arrives. */
  onStream(cb: (line: StreamLineView, session: string) => void): Unsubscribe
  /** Every ledger event, live and on replay. */
  onEvent(cb: (event: LedgerEventView, session: string) => void): Unsubscribe
  /** The front tab's background tasks, right now. */
  tasks(): TaskView[]
  /** The front tab's session, or null while it is still a draft. */
  session(): SessionView | null
}

export interface ExtRunResult {
  code: number
  stdout: string
  stderr: string
}

/** Where a compaction landed: the session that continues, and from where. */
export interface CompactedView {
  session: string
  parent: { session: string; seq: number }
}

/**
 * Changing the world — and only in the ways a person already can (tui-plugin
 * D5). There is deliberately no gate verdict, no session write, no second
 * ledger.
 */
export interface PluginActions {
  /**
   * Append a user turn carrying this package's words, wrapped in a sentinel the
   * transcript folds back down (`<ext-note pkg="…" kind="…">`). `kind` is the
   * package's own word for what sort of note this is; it is shown as the card's
   * badge and is otherwise not interpreted.
   *
   * This is the one way a plugin puts anything in front of the model, and it is
   * the same verb `session append` gives a person — so it lands in the inbox and
   * the kernel drains it at its next step boundary, whether or not a step is
   * running.
   *
   * Rejects when the front tab has no session yet.
   */
  appendNote(kind: string, text: string): Promise<void>

  /**
   * `nulya ext run <this package>@<this version> <tool> <args>` — a driver-side
   * call of the package's OWN tool. Naming a tool this package's frozen manifest
   * does not declare throws: a plugin runs its own code, never somebody else's.
   */
  extRun(tool: string, args: Record<string, unknown>): Promise<ExtRunResult>

  /**
   * `/compact` on the front tab's session — the person's own verb (tui.md
   * §5.8, DESIGN §11), added in 1.1.
   *
   * `briefFile` is a workspace-relative path to a brief that has already been
   * written; giving one skips the summarising round trip and leaves the old
   * session byte-identical, which is the branch `/compact` takes when the model
   * writes a handoff. Without it, the session is asked to summarise itself
   * first. Either way the fork is `session new --parent` with no `--with`, so
   * the child carries the brief and NOT the packages this session was wearing —
   * which is exactly what an approved plan wants: the plan travels, the
   * planning persona does not.
   *
   * The tab moves to the child, as it does when a person runs `/compact`.
   * Rejects when there is no session, when somebody else is driving it, or when
   * a step is running.
   *
   * There is no fork primitive here beyond this one. A plugin cannot open a
   * session, name a parent, or choose a composition: it can ask for the move a
   * person could have made from the composer, and that is all (D5).
   */
  compact(options?: { briefFile?: string; focus?: string }): Promise<CompactedView>

  /** Open a session in a tab of its own (what `Enter` on a sub-session card does). */
  openTab(sessionId: string): void

  /**
   * Put `id` on the NEXT session's `--with` list, in a new draft tab — the
   * `/with <id>` move. Nothing is activated and no session changes: composition
   * freezes at `session new` (physics #2).
   */
  wearNext(id: string): void
}

/**
 * This package's slot in `tui-state.json` (`plugins: {"<pkg>": {…}}`).
 *
 * For PREFERENCES — what this plugin should remember between runs. Not for view
 * state (that belongs in the plugin's own memory and should die with the
 * process) and not for anything the model must see (that belongs in the
 * ledger, via `appendNote`). Values must be JSON-serialisable.
 */
export interface PluginStateStore {
  get<T = unknown>(key: string): T | undefined
  set(key: string, value: unknown): void
}

export interface CommandContext {
  /** Everything typed after the command name, verbatim. */
  args: string
  session: SessionView | null
}

export interface CommandSpec {
  /** Bare name, no leading slash. `[a-z0-9-]+`, as the manifest's own commands are. */
  name: string
  description: string
  run(ctx: CommandContext): void | Promise<void>
}

/** What `activate` receives. */
export interface PluginApi {
  pkg: PluginPkg

  /**
   * A slash command backed by code. When this package's manifest ALSO declares
   * a `contributes.commands` entry of the same name, this one wins — it is the
   * same package making a more capable statement about itself (tui-plugin §5,
   * open question 2). A built-in name is never taken (D8); registering one is a
   * no-op the host warns about.
   */
  registerCommand(spec: CommandSpec): void

  /**
   * Draw this package's own tool call in the transcript. `tool` MUST be a tool
   * this package's frozen manifest declares — registering somebody else's
   * throws, because a card that can redraw another package's call is display
   * spoofing (D11). The host supplies the card frame, glyph, chip and folding.
   */
  registerCard(tool: string, renderer: CardRenderer): void

  /** A panel in the composer area. Registering returns the handle that opens it. */
  registerPanel(spec: PanelSpec): PanelHandle

  /**
   * A persistent, foldable row above the composer — where the declaration
   * layer's `panel: true` projection lives (D12). A package that registers one
   * SUPERSEDES its own declared projections: code is the ceiling over its own
   * floor, and the two would otherwise say the same thing twice.
   */
  registerWidget(spec: LineRenderer): void

  observe: PluginObserve
  actions: PluginActions
  state: PluginStateStore

  /**
   * Say something on the status line, briefly. The one output channel a plugin
   * has that is not a surface it drew itself; it is news, and it goes away.
   */
  notice(text: string): void
}
