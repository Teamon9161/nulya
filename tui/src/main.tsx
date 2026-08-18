/**
 * Entry point: resolve the workspace and binary, decide what the first tab is,
 * then hand the whole screen to <App/>.
 *
 *   nulya-tui [--session <id>] [--new] [--profile <p>] [--model <id>] [--effort <e>] [--workspace <dir>]
 *
 * With no arguments NOTHING is created (tui.md §11, T22): the screen opens on a
 * draft, and `session new` runs at the first message. Composition freezes when a
 * session is created (physics #2), so creating one here would decide this tab's
 * tools, pins and model before the person has touched anything — and everything
 * they then did in `/ext` or `/model` would land on some later session instead.
 *
 * What the draft will run on is `launch.planLaunch`: the flags, else the last
 * pick made in `/model`, else the kernel's default; and if none of those can
 * actually run here, the picker is the first thing on screen (tui.md §1.2 D8).
 */
import { render } from "@opentui/solid"
import { openWorkspace, type Workspace } from "./nulya/bin.ts"
import { configShow } from "./nulya/cli.ts"
import { sessionExists } from "./nulya/files.ts"
import { loadSettings } from "./state/settings.ts"
import { loadTuiState, rememberBundledAsked, rememberStoreAsked } from "./state/tui_state.ts"
import { planLaunch } from "./launch.ts"
import {
  answerFor,
  applyAnswer,
  bundledPromptText,
  installBundled,
  inventory,
  planBundled,
  planProjectStore,
  promptText,
  storeTrusted,
  summarize,
  workspaceStorePath,
  type StoreAnswer,
} from "./extensions.ts"
import { createStyle } from "./render/theme.ts"
import { createSessionState } from "./state/session.ts"
import { App } from "./ui/App.tsx"
import type { ModelPick } from "./state/tui_state.ts"

interface Args {
  session?: string
  profile?: string
  model?: string
  effort?: string
  workspace?: string
  maxSteps?: number
  fresh?: boolean
}

function parseArgs(argv: string[]): Args {
  const args: Args = {}
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i]
    if (flag === "--new") {
      args.fresh = true
      continue
    }
    const value = argv[i + 1]
    if (!value) continue
    if (flag === "--session") {
      args.session = value
      i++
    } else if (flag === "--profile") {
      args.profile = value
      i++
    } else if (flag === "--model") {
      args.model = value
      i++
    } else if (flag === "--effort") {
      args.effort = value
      i++
    } else if (flag === "--workspace") {
      args.workspace = value
      i++
    } else if (flag === "--max-steps") {
      args.maxSteps = Number.parseInt(value, 10)
      i++
    }
  }
  return args
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const ws = openWorkspace(args.workspace ?? process.cwd())

  const id = args.session
  if (id && args.fresh) {
    process.stderr.write("--new and --session ask for different sessions; pick one\n")
    process.exit(1)
  }
  if (id && !sessionExists(ws, id)) {
    process.stderr.write(`no such session '${id}' in ${ws.dir}\n`)
    process.exit(1)
  }

  let effort = args.effort
  let pick: ModelPick | undefined
  let guide: string | undefined
  let guideOn: "model" | "provider" | undefined
  const settings = await loadSettings(ws.dir)

  // Before any session exists, because this is the one thing that can stop one
  // from being created: a store that came with the checkout takes part in no
  // session until someone has looked at it once (DESIGN §9). Asked here, in the
  // plain terminal, since the alternate screen has not been entered yet.
  const projectStore = settings.extensions.sync_on_start ? await askAboutProjectStore(ws) : "none"

  // The drafts the BINARY ships (`ext seed`, DESIGN §7.8), same place and same
  // reason: the user store is the person's own directory, so nothing lands in
  // it on nobody's word — one keypress, once per machine.
  if (settings.extensions.sync_on_start) await askAboutBundled(ws)

  // Read once, for two readers: the launch plan below, and the status bar's
  // context gauge (only `context_window` is taken from the catalog).
  const config = await configShow(ws)
  if (id === undefined) {
    const plan = planLaunch(args, loadTuiState().model, config)
    if (plan.refuse) {
      process.stderr.write(`${plan.refuse}\n`)
      process.exit(1)
    }
    // Nothing is created here any more, so nothing here can be refused: the
    // kernel's gates — a missing credential, an untrusted checkout store, a pin
    // that names nothing — are met at the first message, on screen, where the
    // way out is one key away instead of an exit code in a dead terminal.
    pick = plan.pick
    effort = plan.pick?.effort ?? effort
    guide = plan.guide
    guideOn = plan.guideOn
  }

  const style = createStyle(settings)
  const state = id === undefined ? undefined : createSessionState(id)

  await render(
    () => (
      <App
        ws={ws}
        id={id}
        state={state}
        pick={pick}
        style={style}
        driver={args.maxSteps !== undefined ? { maxSteps: args.maxSteps } : {}}
        effort={effort}
        guide={guide}
        guideOn={guideOn}
        models={config.models}
        profiles={config.profiles}
        pinnedTools={config.registry.pinned_native_tools}
        sync={{
          user: settings.extensions.sync_on_start,
          // The project store is only the background pass's business when it was
          // already trusted; a store that was just asked about has been dealt
          // with above, on the answer the person actually gave.
          project: settings.extensions.sync_on_start && projectStore === "ready",
          activate: settings.extensions.auto_activate,
        }}
      />
    ),
    { exitOnCtrlC: false, targetFps: 30 },
  )
}

/**
 * The workspace store, before the screen exists: nothing to install, already
 * trusted (leave it to the background pass), or a question.
 *
 * A question is a real one — a single keypress, with what the store holds
 * printed above it — and it is asked once per store whatever the answer, so
 * declining a checkout does not become a prompt every morning.
 */
async function askAboutProjectStore(ws: Workspace): Promise<"none" | "ready" | "answered"> {
  const store = workspaceStorePath(ws)
  let plan
  try {
    plan = planProjectStore(store, await inventory(ws, false), storeTrusted(store), loadTuiState().asked_stores ?? [])
  } catch {
    return "none" // no store, no binary answer — the session's own gate still speaks
  }
  if (plan.kind !== "ask") return plan.kind === "ready" ? "ready" : "none"

  process.stdout.write(promptText(plan))
  const answer = await readAnswer()
  rememberStoreAsked(store)
  if (answer === "skip") {
    process.stdout.write("left alone · `nulya ext trust` whenever you mean to\n")
    return "answered"
  }
  process.stdout.write("installing…\n")
  const report = await applyAnswer(ws, answer)
  if (report) process.stdout.write(`${summarize("this checkout", report)}\n`)
  return "answered"
}

/**
 * The bundled extensions, before the screen exists. Nothing to do when the
 * question was already put on this machine, when everything is already in the
 * user store, or when no person is at the keyboard. An old `nulya` binary that
 * lacks `ext seed` answers with an error — treated as "nothing to offer".
 */
async function askAboutBundled(ws: Workspace): Promise<void> {
  if (loadTuiState().asked_bundled) return
  if (!process.stdin.isTTY) return
  let plan
  try {
    plan = await planBundled(ws)
  } catch {
    return
  }
  if (plan.seeded === 0) return

  process.stdout.write(bundledPromptText(plan))
  const answer = await readAnswer()
  rememberBundledAsked()
  if (answer === "skip") {
    process.stdout.write("left alone · `nulya ext seed --user` whenever you mean to\n")
    return
  }
  process.stdout.write("installing…\n")
  try {
    const summary = await installBundled(ws, answer)
    if (summary) process.stdout.write(`${summary}\n`)
  } catch (error) {
    process.stdout.write(`${error instanceof Error ? error.message : String(error)}\n`)
  }
}

/**
 * The answer to a `choicesText` question: keys until one of them IS an answer,
 * then that key echoed on the `› ` line with a newline after it.
 *
 * Both halves matter. Raw mode swallows the echo, so without ours the keypress
 * is invisible — the screen shows the same bare cursor before and after, and a
 * `t` followed by a minute of zig building the std extension looks exactly like
 * a hang. And a byte that is not one of the three keys is not a "no": a
 * terminal's reply to a query, a focus event, an IME's partial sequence, an
 * empty first chunk all arrive on the same stream, and every one of them used to
 * be read as "not now" — silently, once, never to be asked again.
 */
async function readAnswer(): Promise<StoreAnswer> {
  for (;;) {
    const key = await readKey()
    const answer = answerFor(key)
    if (!answer) continue
    process.stdout.write(`${key === "return" ? "" : key === "escape" ? "esc" : key}\n`)
    return answer
  }
}

/**
 * One keypress from the terminal, lowercased. `escape` and `return` by name;
 * an escape SEQUENCE (a cursor key, a terminal reply) is `sequence`, which no
 * question accepts, rather than a lone Esc that every question takes as no.
 */
async function readKey(): Promise<string> {
  const stdin = process.stdin
  if (!stdin.isTTY) return "n" // not a person: never install on nobody's word
  stdin.setRawMode(true)
  stdin.resume()
  try {
    const chunk: Buffer = await new Promise((resolve) => stdin.once("data", resolve))
    const byte = chunk[0] ?? 0
    if (byte === 27) return chunk.length === 1 ? "escape" : "sequence"
    if (byte === 13 || byte === 10) return "return"
    if (byte === 3) process.exit(130) // Ctrl+C means Ctrl+C, even here
    return String.fromCharCode(byte).toLowerCase()
  } finally {
    stdin.setRawMode(false)
    stdin.pause()
  }
}

await main()
