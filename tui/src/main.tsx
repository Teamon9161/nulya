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
import { openWorkspace } from "./nulya/bin.ts"
import { configShow, sessionNew } from "./nulya/cli.ts"
import { sessionExists } from "./nulya/files.ts"
import { loadSettings } from "./state/settings.ts"
import { loadTuiState } from "./state/tui_state.ts"
import { planLaunch } from "./launch.ts"
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
  // Read once, for two readers: the launch plan below, and the status bar's
  // context gauge (only `context_window` is taken from the catalog).
  const config = await configShow(ws)
  if (id === undefined) {
    const plan = planLaunch(args, loadTuiState().model, config)
    if (plan.refuse) {
      process.stderr.write(`${plan.refuse}\n`)
      process.exit(1)
    }
    id = await sessionNew(ws, plan.pick ? { profile: plan.pick.profile, model: plan.pick.model } : {})
    effort = plan.pick?.effort
    guide = plan.guide
  }

  const settings = await loadSettings(ws.dir)
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
      />
    ),
    { exitOnCtrlC: false, targetFps: 30 },
  )
}

await main()
