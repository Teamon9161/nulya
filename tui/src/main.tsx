/**
 * Entry point: resolve the workspace and binary, pick or create the session,
 * then hand the whole screen to <App/>.
 *
 *   nulya-tui [--session <id>] [--new] [--model <profile>] [--workspace <dir>]
 *
 * With no arguments a fresh session is created — the same thing `nulya session
 * new` does, because the TUI is a client of that CLI and nothing more.
 */
import { render } from "@opentui/solid"
import { openWorkspace } from "./nulya/bin.ts"
import { sessionNew } from "./nulya/cli.ts"
import { sessionExists } from "./nulya/files.ts"
import { loadSettings } from "./state/settings.ts"
import { createStyle } from "./render/theme.ts"
import { createSessionState } from "./state/session.ts"
import { App } from "./ui/App.tsx"

interface Args {
  session?: string
  model?: string
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
    } else if (flag === "--model") {
      args.model = value
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
  id ??= await sessionNew(ws, args.model ? { model: args.model } : {})

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
      />
    ),
    { exitOnCtrlC: false, targetFps: 30 },
  )
}

await main()
