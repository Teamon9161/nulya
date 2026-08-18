/**
 * Entry point: resolve the workspace and binary, pick or create the session,
 * then hand the whole screen to <App/>.
 *
 *   nulya-tui [--session <id>] [--new] [--profile <p>] [--model <id>] [--effort <e>] [--workspace <dir>]
 *
 * With no arguments a fresh session is created — the same thing `nulya session
 * new` does, because the TUI is a client of that CLI and nothing more. Which
 * model it runs on is `launch.planLaunch`: the flags, else the last pick made
 * in `/model`, else the kernel's default; and if none of those can actually run
 * here, the picker is the first thing on screen (tui.md §1.2 D8).
 */
import { render } from "@opentui/solid"
import { openWorkspace, type Workspace } from "./nulya/bin.ts"
import { configShow, sessionNew } from "./nulya/cli.ts"
import { sessionExists } from "./nulya/files.ts"
import { loadSettings } from "./state/settings.ts"
import { loadTuiState, rememberStoreAsked } from "./state/tui_state.ts"
import { planLaunch } from "./launch.ts"
import {
  answerFor,
  applyAnswer,
  inventory,
  planProjectStore,
  promptText,
  storeTrusted,
  summarize,
  workspaceStorePath,
} from "./extensions.ts"
import { createStyle } from "./render/theme.ts"
import { createSessionState } from "./state/session.ts"
import { App } from "./ui/App.tsx"

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

  let id = args.session
  if (id && args.fresh) {
    process.stderr.write("--new and --session ask for different sessions; pick one\n")
    process.exit(1)
  }
  if (id && !sessionExists(ws, id)) {
    process.stderr.write(`no such session '${id}' in ${ws.dir}\n`)
    process.exit(1)
  }

  // Created here, not opened by name: if it is still empty when the TUI quits
  // it is un-created again (`files.discardIfUntouched`), so a look-and-leave
  // does not leave a row in `/sessions`.
  const created = id === undefined
  let effort = args.effort
  let guide: string | undefined
  const settings = await loadSettings(ws.dir)

  // Before any session exists, because this is the one thing that can stop one
  // from being created: a store that came with the checkout takes part in no
  // session until someone has looked at it once (DESIGN §9). Asked here, in the
  // plain terminal, since the alternate screen has not been entered yet.
  const projectStore = settings.extensions.sync_on_start ? await askAboutProjectStore(ws) : "none"

  // Read once, for two readers: the launch plan below, and the status bar's
  // context gauge (only `context_window` is taken from the catalog).
  const config = await configShow(ws)
  if (id === undefined) {
    const plan = planLaunch(args, loadTuiState().model, config)
    if (plan.refuse) {
      process.stderr.write(`${plan.refuse}\n`)
      process.exit(1)
    }
    // A refusal here is an answer, not a crash: the commonest one is the store
    // gate — a checkout whose extensions nobody has vouched for, possibly the
    // question just declined above. It deserves the kernel's sentence, not a
    // stack trace through the spawn helper.
    try {
      id = await sessionNew(ws, plan.pick ? { profile: plan.pick.profile, model: plan.pick.model } : {})
    } catch (error) {
      // The kernel's refusal is several lines; only its first reaches here, and
      // it is the one that names the store. A dangling ":" from the list header
      // it introduced is noise once the list is not coming.
      const message = (error instanceof Error ? error.message : String(error)).replace(/:\s*$/, "")
      process.stderr.write(`${message}\n`)
      if (message.includes("not trusted")) {
        process.stderr.write("look with `nulya ext list`, then `nulya ext trust` to allow it\n")
      }
      process.exit(1)
    }
    effort = plan.pick?.effort
    guide = plan.guide
  }

  const style = createStyle(settings)
  const state = createSessionState(id)

  await render(
    () => (
      <App
        ws={ws}
        id={id}
        state={state}
        style={style}
        driver={args.maxSteps !== undefined ? { maxSteps: args.maxSteps } : {}}
        created={created}
        effort={effort}
        guide={guide}
        models={config.models}
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
  const answer = answerFor(await readKey())
  rememberStoreAsked(store)
  if (!answer || answer === "skip") {
    process.stdout.write("left alone · `nulya ext trust` whenever you mean to\n")
    return "answered"
  }
  process.stdout.write("installing…\n")
  const report = await applyAnswer(ws, answer)
  if (report) process.stdout.write(`${summarize("this checkout", report)}\n`)
  return "answered"
}

/** One keypress from the terminal, lowercased. `escape` and `return` by name. */
async function readKey(): Promise<string> {
  const stdin = process.stdin
  if (!stdin.isTTY) return "n" // not a person: never install on nobody's word
  stdin.setRawMode(true)
  stdin.resume()
  try {
    const chunk: Buffer = await new Promise((resolve) => stdin.once("data", resolve))
    const byte = chunk[0] ?? 0
    if (byte === 27) return "escape"
    if (byte === 13 || byte === 10) return "return"
    if (byte === 3) process.exit(130) // Ctrl+C means Ctrl+C, even here
    return String.fromCharCode(byte).toLowerCase()
  } finally {
    stdin.setRawMode(false)
    stdin.pause()
  }
}

await main()
