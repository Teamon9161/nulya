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
  /** `--gate`: this call is waiting for a verdict on stdin (DESIGN §14). */
  | { stream: "gate"; event: "request"; call_id: string; tool: string; args: string }
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

async function* decodeLines(
  stream: ReadableStream<Uint8Array>,
  stopAfter?: Promise<unknown>,
): AsyncGenerator<string> {
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let buffered = ""
  const stopped = stopAfter
    ? stopAfter.then(
        () => new Promise<"stop">((resolve) => setTimeout(() => resolve("stop"), 100)),
        () => new Promise<"stop">((resolve) => setTimeout(() => resolve("stop"), 100)),
      )
    : null
  try {
    for (;;) {
      const read = reader.read().then(
        (result) => ({ kind: "read" as const, result }),
        (error) => ({ kind: "error" as const, error }),
      )
      const next = stopped ? await Promise.race([read, stopped]) : await read
      if (next === "stop") {
        await reader.cancel().catch(() => {})
        break
      }
      if (next.kind === "error") throw next.error
      const { done, value } = next.result
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

/**
 * A command that refused, with BOTH readings of what it said.
 *
 * `message` is one line, because most callers put it on the status bar and that
 * line is one row shared with the model and the cost. `detail` is everything
 * the command printed, because some refusals are a paragraph — `session new`
 * naming the store it will not trust and listing what is in it, or naming every
 * pin when one of them is bad — and a reader who only ever sees the first 70
 * columns of that cannot act on it. Whoever has room shows `detail`
 * (`ErrorNotice`); nobody has to.
 */
export class CliError extends Error {
  readonly detail: string
  constructor(message: string, detail: string) {
    super(message)
    this.name = "CliError"
    this.detail = detail
  }
}

function fail(what: string, result: RunResult): never {
  const said = result.stderr.trim() || result.stdout.trim() || `exit ${result.code}`
  throw new CliError(`${what}: ${said.split("\n")[0]}`, `${what}\n${said}`)
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
  /**
   * `--pin ext:<id>/<tool>`, repeatable: put an extension tool on THIS session's
   * native tool face. Unioned with `registry.pinned_native_tools` by the kernel
   * (DESIGN §5.1) — a union only adds, so this can never take a configured pin
   * away. The TUI's own pin panel writes these from `tui-state.json`.
   */
  pin?: readonly string[]
  /**
   * `--bare`: compose from these flags alone, ignoring the config's standing
   * `[extensions] with` and `registry.pinned_native_tools` (DESIGN §14). What a
   * delegated sub-agent session gets, whose whole capability list is its own
   * definition — `extensions/agent`'s `render` returns it, so the TUI passes
   * through whatever that says rather than deciding here.
   */
  bare?: boolean
  /**
   * `--prompt <file>`, repeatable: freeze a file's bytes into THIS session's
   * system blocks (DESIGN §3, §5). Nothing is installed and nothing is
   * versioned — which is the whole difference from `with`: text that only this
   * session has a use for lives in this session's header, so no later `ext
   * prune` can take it away from a resume. A sub-agent persona is the first
   * caller (`agents.ts`).
   */
  prompt?: readonly string[]
  /**
   * `--env <spec>`: where this session's `shell` commands run — `local` (or
   * absent), `wsl`, `wsl:<distro>` (DESIGN §8.1), or a `remote:…` spec (§8.2)
   * that moves the whole workspace. Frozen in the header, so there is no
   * per-step twin: a resume runs the commands where the session says or
   * refuses to run them at all.
   *
   * The spec is passed through unvalidated on purpose. The kernel already
   * refuses a bad one before creating anything, and its refusal names both the
   * vocabulary and the reason; a second parser here would be a second answer to
   * "is this spelling any good".
   */
  execEnv?: string
  /**
   * `--workspace <dir>`: the remote machine's absolute directory this
   * session's `shell` and every workspace-reading tool run against (DESIGN
   * §8.2, goals/remote-env.md §3.3). Only meaningful alongside a `remote:`
   * `execEnv` — the kernel is the one that enforces that, same reasoning as
   * `execEnv` itself: it already refuses the combination it does not like, so
   * this is passed through rather than checked twice.
   */
  workspace?: string
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
  if (options.bare) args.push("--bare")
  if (options.execEnv) args.push("--env", options.execEnv)
  if (options.workspace) args.push("--workspace", options.workspace)
  for (const ref of options.with ?? []) args.push("--with", ref)
  for (const pin of options.pin ?? []) args.push("--pin", pin)
  for (const file of options.prompt ?? []) args.push("--prompt", file)
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
   * the user file), `env` (`api_key_env` is set), `file` (the user credential
   * file answers that same variable name — DESIGN §9.5, the one source a spawned
   * process can still reach, since secrets are stripped from every child's
   * environment), `login` (codex auth file), `builtin` (scripted), `none`.
   */
  credential_source: "config" | "env" | "file" | "login" | "builtin" | "none"
  /** Default model id and the selectable list (the default is always in it). */
  model: string
  models: string[]
  /** Profile-wide effort override, or null. */
  effort: string | null
  /**
   * What THIS endpoint reports about the models it serves, when it reports
   * anything — today only `codex`, from the Codex CLI's own model cache. Null
   * everywhere else, and null from any binary that predates the field.
   *
   * It exists because one id can mean two different things: `gpt-5.6-sol` on a
   * ChatGPT subscription is a different context window and a different effort
   * ladder from `gpt-5.6-sol` on the public API, and the global `[[models]]`
   * catalog can only describe one of them. So a row prefers its own profile's
   * entry and falls back to the catalog (`ModelView.modelRows`).
   */
  catalog: ModelView[] | null
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
  /** Whether the catalog explicitly permits `session append --image`. */
  vision: boolean
}

/**
 * The merged `[registry]`: the tool face this workspace opens a session with.
 * Effective values, not layers — the projection deliberately does not say which
 * config file contributed a pin, so a panel that needs to know reads the user
 * file itself (`pins.ts`), which is the one file it may write.
 */
export interface RegistryView {
  max_tools: number
  pinned_native_tools: string[]
}

/**
 * The merged `[extensions]`, projected for the same reason `[registry]` is:
 * which packages are a member of every session opened here (DESIGN §5.1) is
 * not something a front end should read three config files to learn — and one
 * of those layers may hold an inline `api_key`.
 *
 * `paths` is deliberately not in the projection: it names directories code may
 * come from, which `ext list` already answers by showing each root.
 */
export interface ExtensionsView {
  with: string[]
}

export interface ConfigView {
  paths: ConfigPaths
  active_profile: string
  profiles: ProfileView[]
  models: ModelView[]
  registry: RegistryView
  extensions: ExtensionsView
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
  const registry = (record["registry"] ?? {}) as Partial<RegistryView>
  const extensions = (record["extensions"] ?? {}) as Partial<ExtensionsView>
  return {
    registry: {
      max_tools: typeof registry.max_tools === "number" ? registry.max_tools : 8,
      pinned_native_tools: Array.isArray(registry.pinned_native_tools) ? registry.pinned_native_tools : [],
    },
    // Absent means an older binary that did not project it, which reads the
    // same as "nothing joins every session here" — the safe direction: a
    // package this front end fails to notice as standing is one it offers to
    // add, never one it silently assumes is already there.
    extensions: { with: Array.isArray(extensions.with) ? extensions.with : [] },
    paths: { system: paths.system ?? "", user: paths.user ?? "", project: paths.project ?? "" },
    active_profile: typeof record["active_profile"] === "string" ? record["active_profile"] : "",
    profiles: profiles.map((p) => ({
      ...p,
      credential_source: p.credential_source ?? (p.credential ? "env" : "none"),
      models: Array.isArray(p.models) ? p.models : [],
      effort: p.effort ?? null,
      // Absent (an older binary) or malformed is "this endpoint says nothing",
      // which is exactly what every non-codex profile means by it.
      catalog: Array.isArray(p.catalog) ? p.catalog.map(model) : null,
    })),
    models: models.map(model),
  }
}

/** One catalog entry, with the optional columns filled in. Two callers: the
 * global `[[models]]` list and a profile's own `catalog`. */
function model(m: ModelView): ModelView {
  return {
    ...m,
    label: m.label ?? "",
    efforts: Array.isArray(m.efforts) ? m.efforts : [],
    default_effort: m.default_effort ?? null,
    context_window: m.context_window ?? null,
    vision: m.vision ?? false,
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
  composition: {
    active: string[]
    native_tools: string[]
    /**
     * The per-session system prompts frozen into this session's header
     * (`session new --prompt`, DESIGN §3): their labels and sizes, never the
     * text — a listing says WHICH session is which. A sub-agent persona is the
     * first thing that shows up here (`agents.ts`).
     */
    prompts: { source: string; bytes: number }[]
  }
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
      prompts: row.composition?.prompts ?? [],
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
 * One row of `nulya task list --json` (DESIGN §6.1 / §14).
 *
 * `state` is the kernel's own projection and the TUI does not re-derive any of
 * it: `starting` is a task whose supervisor has not written its status yet and
 * `lost` is one that says `running` while nothing holds its lease — two answers
 * that need the lock and the directory together, which is exactly the kind of
 * thing `/sessions` stopped re-deriving in T8. A task retargeted here by a
 * compaction is listed by the same command (its `notify` names this session), so
 * even "which tasks are mine" is the kernel's answer, not ours.
 */
export interface TaskEntry {
  /** Full name `<session>/t<N>` — what every `nulya task` verb takes. */
  task: string
  /** The session that STARTED it; `notify` is where its report goes. */
  session: string
  state: "starting" | "running" | "done" | "lost"
  /** Workspace-relative path of the whole captured output. */
  log: string
  notify: string | null
  command: string
  cwd: string
  started: string
  timeout_ms: number | null
  pid: number | null
  supervisor_pid: number | null
  exit_code: number | null
  ended_by: "exit" | "timeout" | "kill" | null
  finished: string | null
  /** Set once it ended; `elapsed_s` is set while it has not. */
  duration_ms: number | null
  elapsed_s: number | null
}

export function taskIsDone(task: TaskEntry): boolean {
  return task.state === "done" || task.state === "lost"
}

/**
 * `nulya task list --session <id> --json` — the background tasks of one session.
 *
 * Scoped to a session on purpose: `/tasks` is a view of the tab in front of you,
 * and the workspace-wide answer is `nulya task list` in a terminal (tui.md §5.9).
 */
export async function taskList(ws: Workspace, id: string, env?: Record<string, string>): Promise<TaskEntry[]> {
  const result = await run(ws, ["task", "list", "--session", id, "--json"], env)
  if (result.code !== 0) fail("task list failed", result)
  let value: unknown
  try {
    value = JSON.parse(result.stdout)
  } catch {
    fail("task list returned no JSON", result)
  }
  const rows = (value as { tasks?: unknown }).tasks
  return Array.isArray(rows) ? (rows as TaskEntry[]) : []
}

/**
 * `nulya task kill <task>` — write the kill marker; the supervisor takes the
 * whole process tree down at its next look (DESIGN §6.1). Idempotent, and a task
 * that already finished is told so rather than treated as an error.
 */
export async function taskKill(ws: Workspace, task: string): Promise<string> {
  const result = await run(ws, ["task", "kill", task])
  if (result.code !== 0) fail("task kill failed", result)
  return result.stdout.trim()
}

/**
 * `nulya ext build <path>` — freeze a draft into the store and return the
 * version it sealed to. Content-addressed, so building an unchanged draft twice
 * yields the same version and no second copy (physics #5).
 */
export async function extBuild(ws: Workspace, path: string, options: { user?: boolean } = {}): Promise<string> {
  const args = ["ext", "build", path]
  // `--user` decides the DESTINATION root, not the source: a draft staged
  // anywhere can be frozen into the user store (DESIGN §7.4). Which is how a
  // persona defined in `~/.nulya/agents` stays on this machine rather than
  // accumulating in whatever workspace happened to run it (`agents.ts`).
  if (options.user) args.push("--user")
  const result = await run(ws, args)
  const version = /v-[0-9a-zA-Z]+/.exec(result.stdout)?.[0]
  if (result.code !== 0 || !version) fail("ext build failed", result)
  return version
}

/**
 * What `nulya ext seed` reports: what became of each bundled draft in that root
 * (DESIGN §7.8).
 *
 * Four answers, and the difference between the middle two is the whole point:
 * a draft the binary itself wrote and nobody has touched is carried forward
 * (`updated`), while one that has been edited — or that arrived by a hand the
 * store has no record of — is left where it is (`mine`) and named.
 */
export interface SeedReport {
  /** Drafts written where there was none (or, under `--dry-run`, that would be). */
  seeded: number
  /** Ids left alone because they are already what this binary ships. */
  already: number
  /** The ids counted in `seeded`, in the order the kernel printed them. */
  ids: string[]
  /** Ids moved forward to this binary's source, having been its own copy. */
  updated: string[]
  /** Ids that differ from this binary and are somebody's: left untouched. */
  mine: string[]
  text: string
}

/**
 * `nulya ext seed` — write the extension drafts the BINARY ships into a store
 * root (DESIGN §7.8). Source only: building stays `ext sync`'s job.
 *
 * Safe to call on every start: it writes what is missing, refreshes what it
 * wrote itself and nobody has since touched, and never overwrites an edited
 * draft without `--force`.
 */
export async function extSeed(
  ws: Workspace,
  options: {
    user?: boolean
    ids?: string[]
    dryRun?: boolean
    force?: boolean
    env?: Record<string, string>
  } = {},
): Promise<SeedReport> {
  const args = ["ext", "seed"]
  if (options.user) args.push("--user")
  if (options.ids) args.push(...options.ids)
  if (options.force) args.push("--force")
  if (options.dryRun) args.push("--dry-run")
  const result = await run(ws, args, options.env)
  if (result.code !== 0) fail("ext seed failed", result)
  const summary = /(\d+) seeded, (\d+) updated, (\d+) up to date, (\d+) left alone/.exec(result.stdout)
  const ids: string[] = []
  const updated: string[] = []
  const mine: string[] = []
  for (const line of result.stdout.split("\n")) {
    const done = /^([^\s:]+): (seeded|would seed|updated|would update|replaced|would replace|differs) /.exec(line.trim())
    if (!done) continue
    const [, id, verb] = done as unknown as [string, string, string]
    if (verb === "differs") mine.push(id)
    else if (verb === "seeded" || verb === "would seed") ids.push(id)
    else updated.push(id)
  }
  return {
    seeded: summary ? Number.parseInt(summary[1]!, 10) : 0,
    already: summary ? Number.parseInt(summary[3]!, 10) : 0,
    ids,
    updated,
    mine,
    text: result.stdout,
  }
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
   * pointer alone — someone pointed it somewhere on purpose), or null.
   */
  activation: "active" | "activated" | "kept" | null
  /** The failure reason, or the version a `kept` pointer names. */
  detail: string | null
}

export interface SyncReport {
  lines: SyncLine[]
  built: number
  already: number
  /**
   * The kernel's own failure total — which counts `needs zig` drafts too
   * (`cli/ext.zig`: `ZigVersionUnreadable` does `failed += 1`). Kept as it
   * arrives, because it is the authority on how many drafts got no version;
   * `needsZig` below is what splits it back apart.
   */
  failed: number
  /**
   * How many of `failed` are only missing a toolchain — counted from the lines
   * rather than given by the summary, because the kernel merges the two there.
   *
   * They are different problems with different repairs: a draft that does not
   * compile wants its diagnostics read, one that needs zig wants a toolchain
   * installed, and nothing the person does about one helps the other. A single
   * `2 failed` sent a reader to check their zig install when their zig was
   * fine.
   */
  needsZig: number
  /** Everything the command printed, for a view that wants the raw text. */
  text: string
}

const empty_report: SyncReport = { lines: [], built: 0, already: 0, failed: 0, needsZig: 0, text: "" }

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
  // Counted here, not summed alongside `failed`: a line the parser did not
  // recognise must not quietly turn a compile failure into a toolchain one.
  // Miscounting this way over-reports "failed", which is the safe direction —
  // the other would hide a broken draft behind "install zig".
  report.needsZig = report.lines.filter((line) => line.state === "needs zig").length
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
 * a tool REFUSES — `ext run` prints the extension's own message on stdout —
 * and the caller usually wants that sentence (`toolSaid`), not an exception
 * with the wrong words in it.
 */
export async function extRun(
  ws: Workspace,
  ref: string,
  tool: string,
  args: unknown,
): Promise<RunResult> {
  return run(ws, ["ext", "run", ref, tool, JSON.stringify(args)])
}

/**
 * The one sentence a failed `ext run` said.
 *
 * On the `plain` wire (DESIGN §7.3) a refusal is the tool's message on its
 * stderr and a non-zero exit, which the CLI prints on ITS stdout as
 * `exit <code>`, a `stderr:` line, then the message (and a `stdout:` section
 * after that when the tool printed something before failing). The framing is
 * the kernel's bookkeeping; the message is what a person, or the model, should
 * read — so this skips the two framing lines when they are there and takes
 * the first line after them. A tool that wrote nothing to stderr is reported
 * by its exit line, which is then all there is to say.
 */
export function toolSaid(result: { stdout: string; stderr: string }): string {
  const text = result.stdout.trim() || result.stderr.trim() || "no output"
  const lines = text.split("\n")
  let at = 0
  if (/^exit -?\d+$/.test(lines[0]!.trim())) at = 1
  if (lines[at]?.trim() === "stderr:") at += 1
  return lines[at]?.trim() || lines[0]!.trim()
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
  /**
   * The `standing` word in the contribution marker: the kernel composes this id
   * into every fresh session for as long as it has a `current` (DESIGN §5.1).
   *
   * This is the EFFECTIVE state, and it comes from the `current` record the
   * activation wrote after verifying the manifest — not from re-reading `apply`
   * out of some version's manifest, which is only what that one version
   * DECLARES. The two can differ (a pointer written before the record existed,
   * a version directory edited by hand), and when they do the kernel's record
   * is the one describing the sessions people are actually going to get.
   */
  standing: boolean
}

/**
 * `standing` inside the `[tools skills prompt standing]` marker.
 *
 * The marker is a trailing field, not a fixed column — `[with]` and
 * `(shadowed)` can follow it — so this reads whichever bracketed field carries
 * the word rather than counting positions.
 */
function standingMarker(fields: readonly string[]): boolean {
  return fields.some(
    (field) =>
      field.startsWith("[") && field.endsWith("]") && field.slice(1, -1).split(" ").includes("standing"),
  )
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
      // `(no current)` is the kernel's word for "this id points at no version";
      // `(inactive)` was the same column before K8 renamed it, and is still
      // read so a newer TUI against an older binary does not report every
      // unpointed package as one pointing at a version called `(inactive)`.
      current: version === "(no current)" || version === "(inactive)" ? null : version,
      root,
      // A trailing column, not a fixed one: an active row also carries
      // `[tools skills prompt]` and possibly `[with]`, so position would be the
      // wrong test.
      shadowed: fields.includes("(shadowed)"),
      standing: standingMarker(fields),
    })
  }
  return entries
}

/** One row of `nulya skill list` (TSV): a frozen skill in the active catalog. */
export interface SkillEntry {
  /** `ext:<id>@<version>/<name>` — the frozen ref `skill load` takes. */
  ref: string
  name: string
  description: string
}

/**
 * `nulya skill list` — the skills contributed by the extensions ACTIVE across
 * the store roots (DESIGN §14). Not this session's catalog: composition froze
 * at `session new`, and what a `/name` typed now becomes is a turn in whatever
 * session it lands in, so the store's answer is the right one.
 */
export async function skillList(ws: Workspace): Promise<SkillEntry[]> {
  const result = await run(ws, ["skill", "list"])
  if (result.code !== 0) fail("skill list failed", result)
  const entries: SkillEntry[] = []
  for (const line of result.stdout.split("\n")) {
    const fields = line.trimEnd().split("\t")
    if (fields.length < 3) continue // "no skills", a blank tail
    const [ref, name, description] = fields as [string, string, string]
    entries.push({ ref, name, description })
  }
  return entries
}

/** `nulya skill load <ref>` — the frozen `SKILL.md` body behind a frozen ref. */
export async function skillLoad(ws: Workspace, ref: string): Promise<string> {
  const result = await run(ws, ["skill", "load", ref])
  // The kernel reports a failed load on stdout with exit 1, so the code is the
  // test and its own sentence is the message.
  if (result.code !== 0) fail("skill load failed", result)
  return result.stdout.replace(/\n$/, "")
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
export interface ImageInput {
  bytes: Uint8Array
  mediaType: "image/png" | "image/jpeg"
}

export function sessionAppend(ws: Workspace, id: string, text: string, images: readonly ImageInput[] = []): Promise<void> {
  // The id first: it has a fixed alphabet (`s-[A-Za-z0-9._-]+`), so `@` cannot
  // be part of it and the key is unambiguous whatever the directory contains.
  const key = `${id}@${ws.dir}`
  const previous = appends.get(key) ?? Promise.resolve()
  const mine = previous.then(
    () => appendNow(ws, id, text, images),
    () => appendNow(ws, id, text, images),
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

async function appendNow(ws: Workspace, id: string, text: string, images: readonly ImageInput[]): Promise<void> {
  const nonce = Math.random().toString(36).slice(2, 10)
  const stem = `.nulya/scratch/tui-${Date.now().toString(36)}-${nonce}`
  const textPath = `${stem}.txt`
  await Bun.write(`${ws.dir}/${textPath}`, text)
  const args = ["session", "append", id, "--file", textPath]
  for (let index = 0; index < images.length; index++) {
    const image = images[index]!
    const path = `${stem}-${index}.${image.mediaType === "image/png" ? "png" : "jpg"}`
    await Bun.write(`${ws.dir}/${path}`, image.bytes)
    args.push("--image", path)
  }
  const result = await run(ws, args)
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
  const proc = Bun.spawn({ cmd: [ws.bin, ...args], cwd: ws.dir, env: process.env, stdout: "pipe", stderr: "pipe" })

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
 * `nulya ext activate` — a CLI action, not a session event. It moves
 * the store's `current` pointer (physics #5) and therefore changes nothing about
 * the session in front of us: composition froze at `session new` (DESIGN §7.5).
 *
 * `session` names a live session's FILE (relative to the workspace), and it is
 * the one thing here that reaches the running conversation: with `NULYA_SESSION`
 * set the kernel deposits a capability note into that session's inbox when the
 * activation takes effect (DESIGN §5.3), so the model learns at its next step
 * boundary that a new version is there to run via `ext run`. Nothing else in
 * this panel gets a note — a pin or a deactivation carries no information this
 * session could act on, since its tool face froze at the start.
 */
export async function extSetCurrent(
  ws: Workspace,
  verb: "activate",
  id: string,
  version: string,
  options: { user?: boolean; session?: string } = {},
): Promise<string> {
  const args = ["ext", verb]
  if (options.user) args.push("--user")
  args.push(id, version)
  const result = await run(ws, args, options.session ? { NULYA_SESSION: options.session } : undefined)
  const detail = (result.stdout.trim() || result.stderr.trim() || `exit ${result.code}`).split("\n")[0] ?? ""
  if (result.code !== 0) throw new Error(`ext ${verb} failed: ${detail}`)
  return detail
}

/**
 * `nulya ext deactivate [--user] <id>` — clear the `current` pointer, so the
 * NEXT session composes without this extension's skills and system prompts
 * (DESIGN §7.2). The versions all stay; deactivating is a pointer move like
 * every other one here (physics #5).
 *
 * Membership, not pins: an extension can be deactivated while a pin still names
 * one of its tools, and then `session new` refuses by name — which is the honest
 * outcome, and the panel shows the kernel's sentence for it.
 */
export async function extDeactivate(ws: Workspace, id: string, options: { user?: boolean } = {}): Promise<string> {
  const args = ["ext", "deactivate"]
  if (options.user) args.push("--user")
  args.push(id)
  const result = await run(ws, args)
  if (result.code !== 0) fail("ext deactivate failed", result)
  return result.stdout.trim()
}

// ── remote environment (DESIGN §8.2, goals/remote-env.md §3.9) ─────────────

/** `nulya remote check --env <spec> --json`: one round trip, answered by whatever agent is on the other end of that channel. */
export interface RemoteHello {
  nulya: string
  os: string
  arch: string
  /** Empty when the agent could not say — never invented. */
  home: string
  /** The directory the agent started in; the workspace a session with no `--workspace` would use. */
  cwd: string
  dialect: string
}

/**
 * `nulya remote check --env <spec> --json` — open a channel and report what
 * answered, without starting a session. The one thing this front end uses it
 * for is a starting point for the remote directory browser (`dirsource.ts`'s
 * `remoteDirSource`) when nothing is remembered for `spec` yet
 * (`tui_state.ts`'s `remote_cwd`): `home`, falling back to `cwd` when the
 * agent has no `$HOME` to report.
 *
 * Throws on refusal — a bad spec, an unreachable machine, a version mismatch
 * — with the kernel's own sentence, which already names what to do about it
 * (`CliError`'s `detail`).
 */
export async function remoteCheck(ws: Workspace, spec: string, env?: Record<string, string>): Promise<RemoteHello> {
  const result = await run(ws, ["remote", "check", "--env", spec, "--json"], env)
  if (result.code !== 0) fail(`could not reach ${spec}`, result)
  try {
    return JSON.parse(result.stdout) as RemoteHello
  } catch {
    fail(`could not reach ${spec}`, result)
  }
}

/** One entry of `nulya remote ls --json` — a name and whether it is a directory. */
export interface RemoteEntry {
  name: string
  dir: boolean
}

/**
 * `nulya remote ls --env <spec> [<path>] --json` — one directory's children on
 * the machine `spec` names, read exactly (DESIGN §8.2): a protocol verb
 * rather than a parsed `ls -1p`, because a file name may contain a newline.
 *
 * Throws on refusal, same as `remoteCheck` — `state/dirsource.ts`'s
 * `remoteDirSource` is the one caller, and it catches this to answer "cannot
 * list this path" the same way the local reader answers a directory it
 * cannot open: a shorter listing, never a crash.
 */
export async function remoteLs(
  ws: Workspace,
  spec: string,
  path: string,
  env?: Record<string, string>,
): Promise<RemoteEntry[]> {
  const result = await run(ws, ["remote", "ls", "--env", spec, path, "--json"], env)
  if (result.code !== 0) fail(`could not list ${path} on ${spec}`, result)
  try {
    return JSON.parse(result.stdout) as RemoteEntry[]
  } catch {
    fail(`could not list ${path} on ${spec}`, result)
  }
}

/**
 * `nulya ext push <id>@<version> --env <spec>` — copy that built version into
 * the machine `spec` names, content-addressed and idempotent: pushing what is
 * already there is a no-op the kernel itself reports (DESIGN §7.4). The
 * sentence returned is the kernel's own — "already there" or "pushed" or a
 * refusal — because that sentence is what `/ext`'s push action shows, and a
 * second wording here would be a second answer to what the kernel already
 * said once.
 */
export async function extPush(ws: Workspace, ref: string, spec: string, env?: Record<string, string>): Promise<string> {
  const result = await run(ws, ["ext", "push", ref, "--env", spec], env)
  const said = (result.stdout.trim() || result.stderr.trim() || `exit ${result.code}`).split("\n")[0] ?? ""
  if (result.code !== 0) throw new CliError(`ext push failed: ${said}`, result.stderr.trim() || result.stdout.trim())
  return said
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
  /**
   * Answer the kernel's per-call gate (`--gate`, DESIGN §14). Given, the step
   * runs gated: every tool call is offered here first and only runs on `allow`.
   * The kernel is blocked on our answer while this promise is pending, which is
   * exactly the point — the model's connection is already closed, so a person
   * may take as long as they like.
   *
   * Absent, no `--gate` is passed and the step behaves as it always has.
   */
  gate?: (request: GateRequest) => Promise<GateVerdict>
}

/**
 * What the kernel offers for approval: one call as the model wrote it, plus
 * what this session FROZE about the tool it names (DESIGN §4).
 */
export interface GateRequest {
  call_id: string
  tool: string
  /**
   * The stable id (`ext:<id>/<tool>`, or the builtin's), or null for a name this
   * session's tool face does not declare. The kernel's own answer to "which
   * package is this from" — reading it here is what retired a front-end
   * derivation over the frozen manifests.
   */
  tool_id: string | null
  /**
   * The package's `readonly` claim for this tool. `null` is not `false`: the
   * builtin makes no claim and neither does a manifest that said nothing.
   */
  readonly: boolean | null
  args: string
}

/** The two answers the wire has; the note reaches the model in the result. */
export type GateVerdict = { allow: true } | { allow: false; note?: string }

/** The verdict line the kernel reads on stdin: `allow` / `deny` / `deny <note>`. */
export function verdictLine(verdict: GateVerdict): string {
  if (verdict.allow) return "allow\n"
  // One line is the whole protocol, so a note with newlines in it would be read
  // as a verdict and then some. Flattened here rather than refused: a person's
  // sentence should reach the model, and its line breaks carry nothing.
  const note = verdict.note?.replace(/\s+/g, " ").trim()
  return note && note.length > 0 ? `deny ${note}\n` : "deny\n"
}

function gateRequestOf(line: StreamLine): GateRequest | null {
  if (line.stream !== "gate" || line.event !== "request") return null
  const record = line as unknown as Partial<GateRequest>
  if (typeof record.call_id !== "string" || typeof record.tool !== "string") return null
  return {
    call_id: record.call_id,
    tool: record.tool,
    // Absent is read as "not said", the same as an explicit null: a kernel that
    // predates these columns has made no claim, and only an explicit `true`
    // ever waves anything through.
    tool_id: typeof record.tool_id === "string" ? record.tool_id : null,
    readonly: typeof record.readonly === "boolean" ? record.readonly : null,
    args: typeof record.args === "string" ? record.args : "{}",
  }
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
  if (options.gate) args.push("--gate")
  const proc = Bun.spawn({
    cmd: [ws.bin, ...args],
    cwd: ws.dir,
    env: options.env ? { ...process.env, ...options.env } : process.env,
    // A gated step reads its verdicts here. Without a gate the child is handed
    // nothing to read, exactly as before.
    stdin: options.gate ? "pipe" : "ignore",
    stdout: "pipe",
    stderr: "pipe",
  })
  const stderr = new Response(proc.stderr).text()

  /**
   * Answer one request and write the verdict back. A gate line never reaches
   * the consumer: it is machinery between this module and the kernel, and the
   * caller hears about the call through its own `gate` callback — which is what
   * draws the card and waits for the key.
   *
   * A gate that throws denies. The kernel fails closed when the channel goes
   * quiet, and this side must not be the reason it waits forever instead.
   */
  async function answer(request: GateRequest): Promise<void> {
    let verdict: GateVerdict = { allow: false }
    try {
      verdict = await options.gate!(request)
    } catch {
      // Nothing said is not consent.
    }
    try {
      proc.stdin?.write(verdictLine(verdict))
      proc.stdin?.flush()
    } catch {
      // The child is gone; its own EOF path denies whatever is left.
    }
  }

  async function* lines(): AsyncGenerator<StepLine> {
    for await (const raw of decodeLines(proc.stdout, proc.exited)) {
      const parsed = parseStepLine(raw)
      if (!parsed) continue
      if (parsed.kind === "stream" && options.gate) {
        const request = gateRequestOf(parsed.line)
        if (request) {
          await answer(request)
          continue
        }
      }
      yield parsed
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
