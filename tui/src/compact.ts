/**
 * `/compact` — the front end's half of compaction.
 *
 * The procedure itself is NOT here any more. Summarise the old session, open a
 * new file whose header points back at it, carry the brief over as its first
 * turn: that is a driver procedure over `session append` + `session step` +
 * `session new --parent`, and it lives in the bundled `extensions/compact`
 * package (PLAN §3.4/§3.6), where it is versioned, readable and reusable by
 * anything that can spawn a process — `/goal` will call the same tool. This
 * module builds that package, runs it, and reads its answer.
 *
 * What stays on this side is only what the SCREEN needs: the two marker lines.
 * They are a convention between the driver and the front end — the kernel
 * stores both turns as ordinary `user_text` — so that a transcript can fold the
 * two turns that are machinery rather than conversation, and so a summary
 * nobody typed does not look typed. `extensions/compact/src/main.zig` declares
 * them as `pub const`; these two strings mirror it, and it is the source.
 */
import { extBuild, extRun } from "./nulya/cli.ts"
import type { Workspace } from "./nulya/bin.ts"
import type { TranscriptItem } from "./state/session.ts"

export const compact_request_marker = "<nulya:compact-request>"
export const compact_summary_marker = "<nulya:context-summary>"

/**
 * The compaction driver's draft, relative to the workspace — like
 * `evolution_draft`, it ships with nulya's source, so `/compact` works where
 * that source is.
 */
export const compact_draft = "extensions/compact"

export const compact_id = "compact"

/** Whether an item is one of the two machinery turns, for folded rendering. */
export function compactionMarker(item: TranscriptItem): "request" | "summary" | null {
  if (item.kind !== "user") return null
  if (item.text.startsWith(compact_request_marker)) return "request"
  if (item.text.startsWith(compact_summary_marker)) return "summary"
  return null
}

/** The marker line stripped off, for display. */
export function withoutMarker(text: string): string {
  const at = text.indexOf("\n")
  return at < 0 ? "" : text.slice(at + 1).trim()
}

/** What the compact tool reports: the session that continues, and from where. */
export interface CompactResult {
  session: string
  parent: { session: string; seq: number }
}

/**
 * Build the compaction driver and run it against `sessionId`.
 *
 * Building every time is deliberate and cheap for the same reason `/evolve`
 * does it: a version id is the hash of the draft, so an unchanged package
 * rebuilds to the version already in the store. Unlike the evolution package
 * this one is compiled, so the first build on a machine needs a toolchain —
 * the kernel says which sources it looked at when there is none, and that
 * message is passed through unchanged.
 *
 * While the tool runs it holds the session's writer lease, so the tab watching
 * that session flips itself to observer and follows the request and the summary
 * into the transcript as they land. Nothing here has to arrange that.
 */
export async function runCompact(
  ws: Workspace,
  sessionId: string,
  focus?: string,
): Promise<CompactResult> {
  const version = await extBuild(ws, compact_draft)
  const trimmed = focus?.trim()
  const call = await extRun(ws, `${compact_id}@${version}`, compact_id, {
    session: sessionId,
    ...(trimmed && trimmed.length > 0 ? { focus: trimmed } : {}),
  })
  // A refusal is the interesting case: the tool says why in the JSON-RPC error
  // the CLI prints, and that sentence ("nothing moved — the old session is
  // still the live one") is the one the user needs to read.
  if (call.code !== 0) throw new Error(said(call.stdout, call.stderr))

  let value: unknown
  try {
    value = JSON.parse(call.stdout.trim())
  } catch {
    throw new Error(`compact returned no result: ${said(call.stdout, call.stderr)}`)
  }
  const result = value as Partial<CompactResult>
  if (typeof result.session !== "string" || !result.session.startsWith("s-")) {
    throw new Error(`compact returned no session id: ${said(call.stdout, call.stderr)}`)
  }
  return {
    session: result.session,
    parent: {
      session: result.parent?.session ?? sessionId,
      seq: result.parent?.seq ?? 0,
    },
  }
}

/** The first line of whatever the call said — stdout first: `ext run` prints the extension's own error there. */
function said(stdout: string, stderr: string): string {
  const text = stdout.trim() || stderr.trim() || "no output"
  return text.split("\n")[0]!
}
