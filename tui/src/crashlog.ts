/**
 * Every error OpenTUI swallows, written down (BUGS.md #17).
 *
 * The renderer registers `process.on("uncaughtException")` and
 * `("unhandledRejection")` and handles both with `console.error` — which it
 * also intercepts, into an overlay this app keeps closed (`openConsoleOnError:
 * false`, for good reasons: it steals focus and Esc only blurs it). The sum of
 * those choices is that a fatal error is INVISIBLE: the process does not die,
 * the screen does not change, and the reactive graph the error tore through
 * stays broken. Both freezes in BUGS.md #17 ended exactly there — a live
 * renderer painting a dead UI, with the one sentence that explained it sitting
 * in a cache nobody can open.
 *
 * This module adds observers, not policy: OpenTUI's handlers stay, the process
 * still does not die. Everything lands in `.nulya/tui-crash.log` in the
 * workspace — timestamped, stack included, repeats collapsed into a count —
 * so the NEXT freeze arrives with its reason attached.
 *
 * `render:error` is subscribed with care: the renderer treats a listener's
 * presence as "somebody handled it" and skips its own logging, so this
 * listener must stay an observer in behaviour even though subscribing alone
 * changes the flag. The line still goes to the file either way.
 */
import { appendFileSync, mkdirSync } from "node:fs"
import { dirname, join } from "node:path"

export interface CrashSink {
  /** Write one entry. `source` names the hook that caught it. */
  note(source: string, error: unknown): void
  /** How many entries have been written (repeats included). */
  count(): number
  /** Unhook the process listeners — the App that installed them is going. */
  dispose(): void
}

/** One line, timestamped; the stack keeps its own newlines below it. */
export function formatCrash(at: Date, source: string, error: unknown): string {
  const stack = error instanceof Error ? (error.stack ?? error.message) : String(error)
  return `[${at.toISOString()}] ${source}: ${stack}\n`
}

export function createCrashLog(file: string, now: () => Date = () => new Date()): CrashSink {
  let entries = 0
  let lastBody = ""
  let repeats = 0
  const write = (text: string) => {
    try {
      mkdirSync(dirname(file), { recursive: true })
      appendFileSync(file, text)
    } catch {
      // A crash log that cannot be written must not become a second crash.
    }
  }
  return {
    note(source, error) {
      entries++
      const line = formatCrash(now(), source, error)
      const body = line.slice(line.indexOf("]") + 1)
      // A poisoned reactive graph can throw the same error on every timer
      // tick; a log that repeats it at 10Hz buries the first line — the one
      // that names the moment things broke. Collapse runs of the same error.
      if (body === lastBody) {
        repeats++
        if (repeats === 2 || repeats % 100 === 0) {
          write(`[${now().toISOString()}] (previous entry repeated, ×${repeats})\n`)
        }
        return
      }
      lastBody = body
      repeats = 1
      write(line)
    },
    count: () => entries,
    dispose() {},
  }
}

let current: CrashSink | null = null

/**
 * Write an entry to whatever crash log this process installed, if any.
 *
 * For the errors that never reach a process hook because something CAUGHT them
 * — the driver turns one into a red notice with no stack, and that is what made
 * BUGS.md #22 a mystery. Module-level because the sink belongs to the process,
 * not to the App: threading it into `state/` would invert the layering for a
 * log line.
 */
export function noteCrash(source: string, error: unknown): void {
  current?.note(source, error)
}

/**
 * Hook the three places OpenTUI makes errors disappear. Returns the sink so
 * the caller can add its own notes (the reactive-heartbeat verdict does) and
 * dispose the process hooks with the App that installed them — a process
 * listener per mount is a leak in any test that mounts the App twice.
 */
export function installCrashLog(
  workspaceDir: string,
  renderer: { on(event: string, fn: (e: unknown) => void): unknown; off?(event: string, fn: (e: unknown) => void): unknown },
): CrashSink {
  const sink = createCrashLog(join(workspaceDir, ".nulya", "tui-crash.log"))
  const onException = (error: unknown) => sink.note("uncaughtException", error)
  const onRejection = (reason: unknown) => sink.note("unhandledRejection", reason)
  const onRenderError = (event: unknown) => {
    const error = event && typeof event === "object" && "error" in event ? (event as { error: unknown }).error : event
    sink.note("render:error", error)
  }
  process.on("uncaughtException", onException)
  process.on("unhandledRejection", onRejection)
  renderer.on("render:error", onRenderError)
  const installed: CrashSink = {
    note: sink.note,
    count: sink.count,
    dispose() {
      process.off("uncaughtException", onException)
      process.off("unhandledRejection", onRejection)
      renderer.off?.("render:error", onRenderError)
      if (current === installed) current = null
    },
  }
  current = installed
  return installed
}
