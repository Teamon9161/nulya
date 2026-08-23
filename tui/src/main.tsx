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
import { loadTuiState, rememberAgentsAnswer, rememberStoreAsked } from "./state/tui_state.ts"
import { planLaunch } from "./launch.ts"
import {
  adoptStdEditPin,
  applyStoreAction,
  checkoutFollowUp,
  inventory,
  planCheckout,
  planProjectStore,
  samePath,
  storeTrusted,
  summarize,
  workspaceStorePath,
  type CheckoutAction,
  type ProjectStorePlan,
} from "./extensions.ts"
import { agentsDirOf, planProjectAgents, workspaceAgentFiles } from "./agents.ts"
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
  // session until someone has looked at it once (DESIGN §9), and a definition
  // in `.nulya/agents` is a system prompt a checkout wrote (tui.md §5.10).
  // Asked here, in the plain terminal, since the alternate screen has not been
  // entered yet — and asked as ONE question when both need a look (T2,
  // ext-review-2 §3b): `planCheckout` is what decides whether that is no
  // question, one of the two unchanged, or the merged one.
  const { projectStore, agentsTrusted } = await askAboutCheckout(ws, settings.extensions.sync_on_start)

  // The drafts the BINARY ships (`ext seed`, DESIGN §7.8) are NOT asked about
  // any more (tui.md §11, T23): they arrive in the user store — the person's own
  // directory — with the binary they just ran, three of them are zig builds, and
  // the question used to hold a bare terminal for a minute with `installing…` as
  // the only sign of life. It happens behind the screen now, on the status line,
  // and `/ext` turns any of it off with one key.

  // `edit` used to be a builtin and is now one of `std`'s tools: a pin list
  // written before that move is short by one. Once, before anything reads it —
  // and only once the std that is active here declares `edit`, else it waits.
  await adoptStdEditPin(ws)

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
          bundled: settings.extensions.sync_on_start,
        }}
        agentsTrusted={agentsTrusted}
      />
    ),
    { exitOnCtrlC: false, targetFps: 30 },
  )
}

/**
 * The one start-up question this checkout might need, before the screen
 * exists (T2, ext-review-2 §3b): the workspace extension store (DESIGN §9)
 * and the agent definitions beside it (tui.md §5.10) merged by `planCheckout`
 * — nothing to ask, today's question for whichever one side needs it,
 * unchanged, or the merged three-answer one when both do. This function is
 * the only glue: it gathers the two plans, prints `plan.text`, reads a key
 * (`readKey`) until `plan.apply` accepts one, then carries out and remembers
 * the answer.
 *
 * The store side is skipped ENTIRELY when `syncOnStart` is off — that
 * setting is the master switch for extension syncing, and a question about a
 * store nothing else will touch has no honest answer. The agent side has no
 * such switch: whether a checkout's personas may run is asked whenever they
 * exist, exactly as it always was.
 */
async function askAboutCheckout(
  ws: Workspace,
  syncOnStart: boolean,
): Promise<{ projectStore: "none" | "ready" | "answered"; agentsTrusted: boolean }> {
  const store = workspaceStorePath(ws)
  let storePlan: ProjectStorePlan = { kind: "none" }
  if (syncOnStart) {
    try {
      storePlan = planProjectStore(store, await inventory(ws, false), storeTrusted(store), loadTuiState().asked_stores ?? [])
    } catch {
      storePlan = { kind: "none" } // no store, no binary answer — the session's own gate still speaks
    }
  }

  const dir = agentsDirOf(ws, "workspace")
  const state = loadTuiState()
  const agentsAlreadyTrusted = (state.trusted_agents ?? []).some((known) => samePath(known, dir))
  const agentsPlan = planProjectAgents(dir, workspaceAgentFiles(ws), agentsAlreadyTrusted, state.asked_agents ?? [], samePath)

  const plan = planCheckout(storePlan, agentsPlan)
  if (plan.kind !== "ask") {
    return {
      projectStore: storePlan.kind === "ready" ? "ready" : "none",
      agentsTrusted: agentsPlan.kind === "ready",
    }
  }

  process.stdout.write(plan.text)
  let action: CheckoutAction | null = null
  while (action === null) {
    const key = await readKey()
    action = plan.apply(key)
    if (action !== null) process.stdout.write(`${key === "return" ? "" : key === "escape" ? "esc" : key}\n`)
  }

  if (storePlan.kind === "ask") rememberStoreAsked(store)
  if (agentsPlan.kind === "ask") rememberAgentsAnswer(dir, action.agentsTrust)

  let projectStore: "none" | "ready" | "answered" = storePlan.kind === "ready" ? "ready" : "none"
  if (action.store.sync) {
    projectStore = "answered"
    process.stdout.write("installing…\n")
    const report = await applyStoreAction(ws, action.store)
    if (report) process.stdout.write(`${summarize("this checkout", report)}\n`)
  } else if (storePlan.kind === "ask") {
    projectStore = "answered"
  }
  for (const line of checkoutFollowUp(action, storePlan.kind === "ask", agentsPlan.kind === "ask")) {
    process.stdout.write(`${line}\n`)
  }

  return { projectStore, agentsTrusted: action.agentsTrust || agentsPlan.kind === "ready" }
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
