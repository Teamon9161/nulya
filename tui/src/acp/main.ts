/**
 * Entry point: speak ACP over stdio.
 *
 *   nulya-acp [--profile <p>] [--model <id>] [--effort <e>] [--mode ask|unsafe]
 *   nulya-acp --settings-help   what `acp.toml` takes
 *
 * The standing approval tables come from `acp.toml` (see `settings.ts`),
 * user layer then the workspace each session names.
 *
 * An editor spawns this and drives it with JSON-RPC; every session it opens is
 * a real nulya session in the `cwd` the client names, so the same conversations
 * are on disk for `nulya session list`, for the TUI, and for a resume.
 *
 * stdout carries the protocol and nothing else — diagnostics go to stderr,
 * which is where a client's log reads them. There is still a `nulya` binary at
 * run time: this is a driver client over a process boundary, not a second
 * harness (`NULYA_BIN`, else a `zig-out/bin/nulya` at or above the session's
 * workspace, else PATH).
 */
import { ndJsonStream } from "@agentclientprotocol/sdk"
import { normalizeMode, type PermissionMode } from "../approvals.ts"
import { createAcpAgent } from "./agent.ts"
import { acpRules } from "./settings.ts"
import { acpSettingsHelp } from "../settingshelp.ts"

interface Args {
  profile?: string
  model?: string
  effort?: string
  mode?: PermissionMode
}

function parseArgs(argv: readonly string[]): Args {
  const args: Args = {}
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i]!
    const value = argv[i + 1]
    switch (flag) {
      case "--profile":
      case "--model":
      case "--effort": {
        if (value === undefined) throw new Error(`${flag} needs a value`)
        args[flag.slice(2) as "profile" | "model" | "effort"] = value
        i += 1
        break
      }
      case "--mode": {
        const mode = value === undefined ? null : normalizeMode(value)
        if (!mode) throw new Error("--mode takes `ask` or `unsafe`")
        args.mode = mode
        i += 1
        break
      }
      default:
        throw new Error(`unknown argument '${flag}'`)
    }
  }
  return args
}

/**
 * stdout as a stream the protocol can write to. Flushed per message: a client
 * is waiting on every one of them, and a buffered response is a hung editor.
 */
function stdoutStream(): WritableStream<Uint8Array> {
  const sink = Bun.stdout.writer()
  return new WritableStream<Uint8Array>({
    write(chunk) {
      sink.write(chunk)
      return Promise.resolve(sink.flush()).then(() => undefined)
    },
    close() {
      sink.end()
    },
  })
}

/**
 * What this program answers without speaking the protocol.
 */
function answeredOnStdout(argv: readonly string[]): string | null {
  if (argv.includes("--settings-help")) return acpSettingsHelp()
  if (argv.includes("--help") || argv.includes("-h")) {
    return [
      "nulya-acp [--profile <p>] [--model <id>] [--effort <e>] [--mode ask|unsafe]",
      "nulya-acp --settings-help          what `acp.toml` takes",
      "",
      "Speaks the Agent Client Protocol over stdio; an editor spawns it.",
    ].join("\n") + "\n"
  }
  return null
}

const answered = answeredOnStdout(Bun.argv.slice(2))
if (answered !== null) {
  process.stdout.write(answered)
  process.exit(0)
}

let args: Args
try {
  args = parseArgs(Bun.argv.slice(2))
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
  process.exit(2)
}

const warn = (line: string) => process.stderr.write(`${line}
`)
const connection = createAcpAgent({ ...args, rules: acpRules(process.env, warn) }).connect(ndJsonStream(stdoutStream(), Bun.stdin.stream()))
await connection.closed
