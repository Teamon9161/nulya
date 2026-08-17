/**
 * Every `nulya session *` call the TUI makes, and the typed parse of the
 * `session step --stream` line protocol (DESIGN §14). This is the ONLY module
 * that spawns the binary; nothing above it knows a flag name or a JSON field.
 */
import { parseEventLine, type LedgerEvent, type ParentRef, type Usage } from "./ledger.ts"
import type { Workspace } from "./bin.ts"

export type StopReason = "end_turn" | "budget" | "canceled" | "max_tokens"
export type StepStatus = "completed" | "canceled"

/**
 * The stream's per-step counts. Deliberately the ledger's `Usage` — the kernel
 * has one such struct and reports the same four numbers in both places, so a
 * second shape here would only invite them to drift.
 */
export type StreamUsage = Usage

export type StreamLine =
  | { stream: "model"; event: "started" }
  | { stream: "model"; event: "text_delta"; text: string }
  | { stream: "model"; event: "thinking_delta"; text: string }
  | { stream: "model"; event: "tool_use_start"; index: number; id: string; name: string }
  | { stream: "model"; event: "tool_use_input_delta"; index: number; fragment: string }
  | ({ stream: "model"; event: "usage" } & StreamUsage)
  | { stream: "model"; event: "done"; stop: string }
  /** A transient failure; the kernel re-sends after `delay_ms` (DESIGN §13). */
  | { stream: "model"; event: "retry"; attempt: number; max_retries: number; delay_ms: number; error: string }
  | { stream: "tool"; event: "begin"; call_id: string; tool: string }
  | { stream: "tool"; event: "end"; call_id: string; ok: boolean }
  | { stream: "step"; event: "end"; status: StepStatus }
  | { stream: "run"; event: "done"; steps: number; stopped: StopReason }
  | { stream: "run"; event: "error"; message: string }
  /** Forward-compatibility: a stream/event pair this build does not know. */
  | { stream: string; event: string; [field: string]: unknown }

/**
 * One parsed stdout line. The split is exactly the kernel's: a `stream` field
 * means a transient observation, its absence means a ledger event in the same
 * shape `session events` prints. Never filter by `kind` — an event kind added
 * later must still reach the transcript (tui.md §11, T0 reminder 1).
 */
export type StepLine = { kind: "stream"; line: StreamLine } | { kind: "event"; event: LedgerEvent }

export function parseStepLine(line: string): StepLine | null {
  const trimmed = line.trim()
  if (trimmed.length === 0) return null
  let value: unknown
  try {
    value = JSON.parse(trimmed)
  } catch {
    return null
  }
  if (typeof value !== "object" || value === null) return null
  const record = value as Record<string, unknown>
  if (typeof record["stream"] === "string") return { kind: "stream", line: record as unknown as StreamLine }
  const event = parseEventLine(trimmed)
  return event ? { kind: "event", event } : null
}

async function* decodeLines(stream: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let buffered = ""
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      buffered += decoder.decode(value, { stream: true })
      let at = buffered.indexOf("\n")
      while (at >= 0) {
        yield buffered.slice(0, at)
        buffered = buffered.slice(at + 1)
        at = buffered.indexOf("\n")
      }
    }
    buffered += decoder.decode()
    if (buffered.trim().length > 0) yield buffered
  } finally {
    reader.releaseLock()
  }
}

export interface RunResult {
  code: number
  stdout: string
  stderr: string
}

async function run(ws: Workspace, args: string[], env?: Record<string, string>): Promise<RunResult> {
  const proc = Bun.spawn({
    cmd: [ws.bin, ...args],
    cwd: ws.dir,
    env: env ? { ...process.env, ...env } : process.env,
    stdout: "pipe",
    stderr: "pipe",
  })
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ])
  return { code, stdout, stderr }
}

function fail(what: string, result: RunResult): never {
  const detail = (result.stderr.trim() || result.stdout.trim() || `exit ${result.code}`).split("\n")[0]
  throw new Error(`${what}: ${detail}`)
}

export interface NewSessionOptions {
  /** Provider profile name (HOW to reach a provider); omitted means the config's active profile. */
  profile?: string
  /** Model id within that profile; omitted means the profile's default. */
  model?: string
  parent?: { session: string; seq: number }
  /**
   * `--with <id>[@<version>]`, repeatable: bring a BUILT extension version into
   * this session's composition without activating it (DESIGN §7.5). Membership
   * only — skills land in the catalog, system prompts in the system blocks —
   * so this is how a mode or the evolution package is put in front of a model
   * for one session and no other.
   */
  with?: readonly string[]
}

/** `nulya session new` — stdout is the session id. `env` is a test seam (`NULYA_HOME`). */
export async function sessionNew(
  ws: Workspace,
  options: NewSessionOptions = {},
  env?: Record<string, string>,
): Promise<string> {
  const args = ["session", "new"]
  if (options.profile) args.push("--profile", options.profile)
  if (options.model) args.push("--model", options.model)
  if (options.parent) args.push("--parent", `${options.parent.session}:${options.parent.seq}`)
  for (const ref of options.with ?? []) args.push("--with", ref)
  const result = await run(ws, args, env)
  const id = result.stdout.trim()
  if (result.code !== 0 || !id.startsWith("s-")) fail("session new failed", result)
  return id
}

/** One row of `nulya config show --json`: a way to reach a provider. */
export interface ProfileView {
  name: string
  kind: string
  base_url: string
  /** The env var NAME the key is read from — never the key. Empty for codex/scripted. */
  api_key_env: string
  /** Whether `session new --profile <name>` would run this provider right now. */
  credential: boolean
  /**
   * Where the credential comes from: `config` (the profile's own `api_key` in
   * the user file), `env` (`api_key_env` is set), `login` (codex auth file),
   * `builtin` (scripted), `none`.
   */
  credential_source: "config" | "env" | "login" | "builtin" | "none"
  /** Default model id and the selectable list (the default is always in it). */
  model: string
  models: string[]
  /** Profile-wide effort override, or null. */
  effort: string | null
}

/** Where the kernel's config chain reads from — so we write where it reads. */
export interface ConfigPaths {
  system: string
  user: string
  project: string
}

/** One `[[models]]` catalog entry: what a model id IS, whoever serves it. */
export interface ModelView {
  id: string
  label: string
  /** Effort levels the model accepts, lowest → highest; empty means no dial. */
  efforts: string[]
  default_effort: string | null
  context_window: number | null
}

export interface ConfigView {
  paths: ConfigPaths
  active_profile: string
  profiles: ProfileView[]
  models: ModelView[]
}

/**
 * `nulya config show --json` — the effective config chain projected once by
 * the kernel's shell, so the picker never re-derives `default → system → user
 * → project` (and its project-only-tightens rule) on its own. `env` is for
 * tests that point `NULYA_HOME` at a scratch directory.
 */
export async function configShow(ws: Workspace, env?: Record<string, string>): Promise<ConfigView> {
  const result = await run(ws, ["config", "show", "--json"], env)
  if (result.code !== 0) fail("config show failed", result)
  let value: unknown
  try {
    value = JSON.parse(result.stdout)
  } catch {
    fail("config show returned no JSON", result)
  }
  const record = value as Record<string, unknown>
  const paths = (record["paths"] ?? {}) as Partial<ConfigPaths>
  const profiles = Array.isArray(record["profiles"]) ? (record["profiles"] as ProfileView[]) : []
  const models = Array.isArray(record["models"]) ? (record["models"] as ModelView[]) : []
  return {
    paths: { system: paths.system ?? "", user: paths.user ?? "", project: paths.project ?? "" },
    active_profile: typeof record["active_profile"] === "string" ? record["active_profile"] : "",
    profiles: profiles.map((p) => ({
      ...p,
      credential_source: p.credential_source ?? (p.credential ? "env" : "none"),
      models: Array.isArray(p.models) ? p.models : [],
      effort: p.effort ?? null,
    })),
    models: models.map((m) => ({
      ...m,
      label: m.label ?? "",
      efforts: Array.isArray(m.efforts) ? m.efforts : [],
      default_effort: m.default_effort ?? null,
      context_window: m.context_window ?? null,
    })),
  }
}

/** How a session turned out, in the kernel's words (`outcome.Verdict`). */
export type Verdict = "success" | "partial" | "failure"

export const verdicts: Verdict[] = ["success", "partial", "failure"]

export function isVerdict(word: string): word is Verdict {
  return (verdicts as string[]).includes(word)
}

export interface OutcomeView {
  verdict: Verdict
  note: string | null
  /** RFC3339 UTC, when the judgment was recorded. */
  at: string
}

/** One row of `nulya session list --json`. */
export interface SessionListEntry {
  id: string
  /** RFC3339 UTC, or empty for a session created before headers carried it. */
  created: string
  parent: ParentRef | null
  /** The provider PROFILE name, then the identity frozen behind it. */
  model: string
  provider: string
  model_id: string
  events: number
  composition: { active: string[]; native_tools: string[] }
  /** Every recorded step's cost, summed. Steps the provider never priced add nothing. */
  usage: Usage
  first_user_text: string
  /** The verdict that stands, or null — which means "not judged", NOT failure. */
  outcome: OutcomeView | null
}

const no_usage: Usage = { input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0 }

/**
 * `nulya session list --json` — the kernel's own projection of
 * `.nulya/sessions/`, newest first (DESIGN §14).
 *
 * The TUI used to walk those files itself; it no longer does. Composition,
 * parent, cost and verdict are one read here, and the verdict in particular
 * lives in a second journal the front end has no business parsing. What stays
 * ours is the live marker: a lease is a fact about right now, not about the
 * file, and `probeWriterLease` answers it without spawning anything.
 */
export async function sessionList(ws: Workspace, env?: Record<string, string>): Promise<SessionListEntry[]> {
  const result = await run(ws, ["session", "list", "--json"], env)
  if (result.code !== 0) fail("session list failed", result)
  let value: unknown
  try {
    value = JSON.parse(result.stdout)
  } catch {
    fail("session list returned no JSON", result)
  }
  const rows = (value as { sessions?: unknown }).sessions
  if (!Array.isArray(rows)) return []
  return (rows as SessionListEntry[]).map((row) => ({
    ...row,
    created: row.created ?? "",
    parent: row.parent ?? null,
    composition: {
      active: row.composition?.active ?? [],
      native_tools: row.composition?.native_tools ?? [],
    },
    usage: { ...no_usage, ...(row.usage ?? {}) },
    first_user_text: row.first_user_text ?? "",
    outcome: row.outcome ?? null,
  }))
}

/**
 * `nulya session outcome <id> <verdict> [--note]` — how a session turned out.
 *
 * A judgment ABOUT a session, not a turn in it: the kernel writes it to the
 * outcome journal and never opens the session file, which is why this can be
 * called on the session in front of us while its own step is still running.
 */
export async function sessionOutcome(
  ws: Workspace,
  id: string,
  verdict: Verdict,
  note?: string,
): Promise<void> {
  const args = ["session", "outcome", id, verdict]
  if (note && note.length > 0) args.push("--note", note)
  const result = await run(ws, args)
  if (result.code !== 0) fail("session outcome failed", result)
}

/**
 * `nulya ext build <path>` — freeze a draft into the store and return the
 * version it sealed to. Content-addressed, so building an unchanged draft twice
 * yields the same version and no second copy (physics #5).
 */
export async function extBuild(ws: Workspace, path: string): Promise<string> {
  const result = await run(ws, ["ext", "build", path])
  const version = /v-[0-9a-zA-Z]+/.exec(result.stdout)?.[0]
  if (result.code !== 0 || !version) fail("ext build failed", result)
  return version
}

/** One `<id>: …` line of `nulya ext sync` (DESIGN §7.2). */
export interface SyncLine {
  id: string
  /** The version that is (or would be) this draft's, or null when unknown. */
  version: string | null
  /**
   * `built` / `already built` are facts; `not built` only appears under
   * `--dry-run` and means "this pass would produce it". `needs zig` is a
   * compiled draft this machine can neither compile nor copy; `failed` is a
   * fault in the draft itself.
   */
  state: "built" | "already built" | "not built" | "needs zig" | "failed"
  /** The store root the version came from (or would come from), if any. */
  copiedFrom: string | null
  /**
   * What `current` says about this version: `active` (it is the pointer),
   * `activated` (this pass moved it), `kept` (`--activate` left an existing
   * pointer alone — someone's rollback stands), or null.
   */
  activation: "active" | "activated" | "kept" | null
  /** The failure reason, or the version a `kept` pointer names. */
  detail: string | null
}

export interface SyncReport {
  lines: SyncLine[]
  built: number
  already: number
  failed: number
  /** Everything the command printed, for a view that wants the raw text. */
  text: string
}

const empty_report: SyncReport = { lines: [], built: 0, already: 0, failed: 0, text: "" }

/**
 * Parse `ext sync` output. The kernel prints one line per draft plus a summary;
 * the shapes are fixed (DESIGN §14) and everything the front end shows about a
 * draft comes from here, so nothing re-derives a version or a state on its own.
 */
export function parseSyncReport(text: string): SyncReport {
  const report: SyncReport = { ...empty_report, lines: [], text }
  for (const raw of text.split("\n")) {
    const line = raw.trim()
    if (line.length === 0) continue
    const summary = /^(\d+) (?:built|not built), (\d+) already built, (\d+) failed$/.exec(line)
    if (summary) {
      report.built = Number(summary[1])
      report.already = Number(summary[2])
      report.failed = Number(summary[3])
      continue
    }
    const parsed = parseSyncLine(line)
    if (parsed) report.lines.push(parsed)
  }
  return report
}

export function parseSyncLine(line: string): SyncLine | null {
  const at = line.indexOf(": ")
  if (at <= 0) return null
  const id = line.slice(0, at)
  if (id.includes(" ")) return null // "no drafts in <root>", a summary, a note
  const rest = line.slice(at + 2)

  if (rest.startsWith("needs zig")) {
    return { id, version: null, state: "needs zig", copiedFrom: null, activation: null, detail: rest }
  }
  if (rest.startsWith("failed:")) {
    return { id, version: null, state: "failed", copiedFrom: null, activation: null, detail: rest.slice(7).trim() }
  }
  const version = /^(v-[0-9a-f]+)/.exec(rest)?.[1] ?? null
  if (!version) return null
  const tail = rest.slice(version.length)
  const state = tail.includes("already built") ? "already built" : tail.includes("not built") ? "not built" : "built"
  const from = /\((?:copied|available) from ([^)]+)\)/.exec(tail)?.[1] ?? null
  const stays = /\(current stays (v-[0-9a-f]+)\)/.exec(tail)?.[1] ?? null
  const activation = tail.includes("(active)")
    ? "active"
    : tail.includes("-> current")
      ? "activated"
      : stays
        ? "kept"
        : null
  return { id, version, state, copiedFrom: from, activation, detail: stays }
}

export interface SyncOptions {
  /** The user store (`~/.nulya/extensions`) instead of this workspace's. */
  user?: boolean
  /** Move `current` onto what this pass brought in (never over another pointer). */
  activate?: boolean
  /** Compute and report; write nothing. */
  dryRun?: boolean
  env?: Record<string, string>
}

/**
 * `nulya ext sync` — build every draft in a store root (DESIGN §7.2).
 *
 * A non-zero exit means at least one draft did not end up with a version, which
 * is per-draft news rather than a failure of the command, so this returns the
 * report instead of throwing: the caller shows the lines and decides.
 * `onLine` fires as each draft finishes, which is what makes progress visible
 * while a compiled draft takes its seconds.
 */
export async function extSync(
  ws: Workspace,
  options: SyncOptions = {},
  onLine?: (line: SyncLine) => void,
): Promise<SyncReport> {
  const args = ["ext", "sync"]
  if (options.user) args.push("--user")
  if (options.activate) args.push("--activate")
  if (options.dryRun) args.push("--dry-run")
  const proc = Bun.spawn({
    cmd: [ws.bin, ...args],
    cwd: ws.dir,
    env: options.env ? { ...process.env, ...options.env } : process.env,
    stdout: "pipe",
    stderr: "pipe",
  })
  // Drained concurrently, not after: a child blocked writing to a pipe nobody
  // reads never exits, and this one warns on stderr (a `--user` action inside a
  // session, say).
  const stderr = new Response(proc.stderr).text()
  let text = ""
  for await (const raw of decodeLines(proc.stdout)) {
    text += `${raw}\n`
    if (onLine) {
      const parsed = parseSyncLine(raw.trim())
      if (parsed) onLine(parsed)
    }
  }
  await Promise.all([proc.exited, stderr])
  return parseSyncReport(text)
}

/**
 * `nulya ext prune` — drop the versions `current` does not name. Returns what it
 * printed, including the line about what the deletion costs.
 */
export async function extPrune(
  ws: Workspace,
  options: { id?: string; user?: boolean; dryRun?: boolean } = {},
): Promise<string> {
  const args = ["ext", "prune"]
  if (options.user) args.push("--user")
  if (options.id) args.push(options.id)
  if (options.dryRun) args.push("--dry-run")
  const result = await run(ws, args)
  if (result.code !== 0) fail("ext prune failed", result)
  return result.stdout.trim()
}

/**
 * `nulya ext trust` — record, once, that this workspace's store may take part in
 * sessions (DESIGN §9). Only ever called after a person has been shown what the
 * store holds and pressed the key.
 */
export async function extTrust(ws: Workspace): Promise<string> {
  const result = await run(ws, ["ext", "trust"])
  if (result.code !== 0) fail("ext trust failed", result)
  return result.stdout.trim()
}

/**
 * `nulya ext run <id>@<version> <tool> <json>` — one oneshot extension call
 * (DESIGN §7.3/§14). The version is named rather than implied: a package the
 * front end builds for a job of its own is deliberately never activated, so
 * there is no `current` to fall back on.
 *
 * The raw result is returned instead of thrown, because a non-zero exit is how
 * a tool REFUSES — `ext run` prints the extension's own JSON-RPC error on
 * stdout — and the caller usually wants that sentence, not an exception with
 * the wrong words in it.
 */
export async function extRun(
  ws: Workspace,
  ref: string,
  tool: string,
  args: unknown,
): Promise<RunResult> {
  return run(ws, ["ext", "run", ref, tool, JSON.stringify(args)])
}

/** One line of `nulya ext list`: an extension directory, in the root that holds it. */
export interface ExtStoreEntry {
  id: string
  /** The `current` pointer, or null when the directory has no active version. */
  current: string | null
  /** The root spec it came from — `.nulya/extensions`, `~/.nulya/extensions`, … */
  root: string
  /** An earlier root already has this id active, so this copy is never used. */
  shadowed: boolean
}

/**
 * `nulya ext list` — every extension directory in every store root, in SEARCH
 * order, with the shadowing already decided (DESIGN §7.2).
 *
 * Root order and "first active holder wins" are kernel policy. The TUI reads
 * the roots it names rather than re-deriving them from a home directory and a
 * config chain, so a shadowed copy shows up here as exactly what the next
 * session will ignore.
 */
export async function extList(ws: Workspace): Promise<ExtStoreEntry[]> {
  const result = await run(ws, ["ext", "list"])
  if (result.code !== 0) fail("ext list failed", result)
  const entries: ExtStoreEntry[] = []
  for (const line of result.stdout.split("\n")) {
    const fields = line.trimEnd().split("\t")
    if (fields.length < 3) continue
    const [id, version, root] = fields as [string, string, string]
    entries.push({
      id,
      current: version === "(inactive)" ? null : version,
      root,
      // A trailing column, not a fixed one: an active row also carries
      // `[tools skills prompt]`, so position would be the wrong test.
      shadowed: fields.includes("(shadowed)"),
    })
  }
  return entries
}

/**
 * Appends in flight, per session. Two `session append` processes running at
 * once have no defined order in the inbox — the one that happens to finish
 * first is drained first — so turns typed as "first, second" could land as
 * "second, first". Serialising them here keeps the ledger's order the user's.
 */
const appends = new Map<string, Promise<void>>()

/**
 * `nulya session append` — the text goes through a scratch file rather than
 * argv: multi-line input and Windows quoting both stop being our problem. The
 * turn lands in the inbox and only enters the ledger at the next step boundary,
 * so the caller must treat it as queued until the matching `user_text` arrives.
 * Calls for the same session run one after another, in call order.
 */
export function sessionAppend(ws: Workspace, id: string, text: string): Promise<void> {
  // The id first: it has a fixed alphabet (`s-[A-Za-z0-9._-]+`), so `@` cannot
  // be part of it and the key is unambiguous whatever the directory contains.
  const key = `${id}@${ws.dir}`
  const previous = appends.get(key) ?? Promise.resolve()
  const mine = previous.then(
    () => appendNow(ws, id, text),
    () => appendNow(ws, id, text),
  )
  // The chain must never break on one failure; the caller sees its own.
  const settled = mine.then(
    () => undefined,
    () => undefined,
  )
  appends.set(key, settled)
  void settled.then(() => {
    if (appends.get(key) === settled) appends.delete(key)
  })
  return mine
}

async function appendNow(ws: Workspace, id: string, text: string): Promise<void> {
  const nonce = Math.random().toString(36).slice(2, 10)
  const rel = `.nulya/scratch/tui-${Date.now().toString(36)}-${nonce}.txt`
  await Bun.write(`${ws.dir}/${rel}`, text)
  const result = await run(ws, ["session", "append", id, "--file", rel])
  if (result.code !== 0) fail("session append failed", result)
}

/** `nulya session events` — the whole tail, already parsed, for open/resume. */
export async function sessionEvents(ws: Workspace, id: string, since = 0): Promise<LedgerEvent[]> {
  const args = ["session", "events", id]
  if (since > 0) args.push("--since", String(since))
  const result = await run(ws, args)
  if (result.code !== 0) fail("session events failed", result)
  const events: LedgerEvent[] = []
  for (const line of result.stdout.split("\n")) {
    const event = parseEventLine(line)
    if (event) events.push(event)
  }
  return events
}

/** `nulya session cancel` — the kernel consumes the marker at a step boundary. */
export async function sessionCancel(ws: Workspace, id: string): Promise<void> {
  const result = await run(ws, ["session", "cancel", id])
  if (result.code !== 0) fail("session cancel failed", result)
}

export interface FollowHandle {
  /** Ledger events as they are appended by whoever holds the writer lease. */
  events: AsyncGenerator<LedgerEvent>
  stop(): void
}

/**
 * `nulya session events <id> --since N --follow` — the observer's source.
 *
 * A session has exactly one writer (DESIGN §3.4). When that writer is somebody
 * else — a driver script, another TUI, a parent session's shell — this is how we
 * watch: a read-only tail that never opens a write handle and never blocks the
 * writer. The granularity is a ledger event, not a delta: deltas exist only on
 * the driver's own stdout (tui.md §5.6).
 */
export function sessionFollow(ws: Workspace, id: string, since = 0): FollowHandle {
  const args = ["session", "events", id, "--follow"]
  if (since > 0) args.push("--since", String(since))
  const proc = Bun.spawn({ cmd: [ws.bin, ...args], cwd: ws.dir, stdout: "pipe", stderr: "pipe" })

  async function* events(): AsyncGenerator<LedgerEvent> {
    for await (const raw of decodeLines(proc.stdout)) {
      const event = parseEventLine(raw)
      if (event) yield event
    }
  }

  return {
    events: events(),
    stop: () => {
      try {
        proc.kill()
      } catch {
        // Already gone.
      }
    },
  }
}

/**
 * `nulya ext activate|rollback` — a CLI action, not a session event. It moves
 * the store's `current` pointer (physics #5) and therefore changes nothing about
 * the session in front of us: composition froze at `session new` (DESIGN §7.5).
 */
export async function extSetCurrent(
  ws: Workspace,
  verb: "activate" | "rollback",
  id: string,
  version: string,
): Promise<string> {
  const result = await run(ws, ["ext", verb, id, version])
  const detail = (result.stdout.trim() || result.stderr.trim() || `exit ${result.code}`).split("\n")[0] ?? ""
  if (result.code !== 0) throw new Error(`ext ${verb} failed: ${detail}`)
  return detail
}

export interface StepHandle {
  /** Parsed stdout lines, in arrival order. Ends when the process exits. */
  lines: AsyncGenerator<StepLine>
  /** Exit code; 0 unless the kernel reported a `run error`. */
  exited: Promise<number>
  /** Anything the step wrote to stderr (a stream write failure, say). */
  stderr: Promise<string>
  /** Ctrl+C's second press: kill the step process (tui.md §1.2 D6). */
  kill(): void
}

export interface StepOptions {
  maxSteps?: number
  /**
   * Reasoning effort for this run (`--effort`). A generation option, not part
   * of the frozen identity (DESIGN §3): omitted means the profile / catalog
   * default the kernel resolves itself.
   */
  effort?: string
  /** Extra environment for the child, e.g. NULYA_SCRIPTED_MODE in tests. */
  env?: Record<string, string>
}

/**
 * `nulya session step <id> --stream`. The TUI owns this subprocess, so its
 * stdout is the live source for the whole step (tui.md §1.2 D2); the session
 * file stays the durable truth and both agree by construction — the ledger
 * lines in this stream are the very lines the kernel appended.
 */
export function sessionStep(ws: Workspace, id: string, options: StepOptions = {}): StepHandle {
  const args = ["session", "step", id, "--stream"]
  if (options.maxSteps !== undefined) args.push("--max-steps", String(options.maxSteps))
  if (options.effort) args.push("--effort", options.effort)
  const proc = Bun.spawn({
    cmd: [ws.bin, ...args],
    cwd: ws.dir,
    env: options.env ? { ...process.env, ...options.env } : process.env,
    stdout: "pipe",
    stderr: "pipe",
  })
  const stderr = new Response(proc.stderr).text()

  async function* lines(): AsyncGenerator<StepLine> {
    for await (const raw of decodeLines(proc.stdout)) {
      const parsed = parseStepLine(raw)
      if (parsed) yield parsed
    }
  }

  return {
    lines: lines(),
    exited: proc.exited,
    stderr,
    kill: () => killTree(proc),
  }
}

/**
 * Kill a step and whatever it spawned. `Bun.spawn().kill()` stops only the
 * process itself; on Windows the `shell` tool's child (a `zig build test`, say)
 * would outlive it, still working in the workspace after the user asked for
 * everything to stop. `taskkill /T` takes the whole tree; POSIX shells put the
 * child in the same process group, so the plain kill already reaches it there.
 * The ledger is safe either way: the next open repairs the interrupted batch
 * (`completeInterruptedToolBatch`).
 */
function killTree(proc: ReturnType<typeof Bun.spawn>): void {
  const plain = () => {
    try {
      proc.kill()
    } catch {
      // Already gone; nothing to stop.
    }
  }
  if (process.platform === "win32" && proc.pid) {
    try {
      // Tree first, then the plain kill as a backstop once taskkill has had its
      // look: killing the parent first would orphan the children before
      // taskkill could enumerate them.
      const sweep = Bun.spawn({
        cmd: ["taskkill", "/pid", String(proc.pid), "/t", "/f"],
        stdout: "ignore",
        stderr: "ignore",
      })
      void sweep.exited.then(plain, plain)
      return
    } catch {
      // taskkill unavailable; fall through to the plain kill.
    }
  }
  plain()
}
