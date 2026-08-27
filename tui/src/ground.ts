/**
 * The facts a session starts from (`docs/goals/ground.md`).
 *
 * The bundled `ground` package has one tool, and it never appears on a model
 * face: it writes this workspace's layout, instruction files, environment and
 * git state to a file and answers where that file is. This module is the one
 * call that turns that into a `session new --prompt`.
 *
 * **Why it is not `[extensions] session_with`.** Membership brings a package's
 * frozen contributions into a session — the same bytes every time, on every
 * machine. These facts are the opposite: today's date, this branch, this
 * directory. They belong to one session and nothing else, which is exactly what
 * `--prompt` is for. So `ground` is composed into no session at all; it is a
 * renderer this front end calls just before creating one.
 *
 * A failure here costs the session nothing. The session starts ungrounded and
 * says so, the way a `session_with` package that will not resolve does.
 */
import type { Workspace } from "./nulya/bin.ts"
import { extRun } from "./nulya/cli.ts"
import { formatWithRef, type WithRef } from "./with.ts"

/** The bundled package this front end renders a session's context with. */
export const ground_id = "ground"

/**
 * Render this workspace's starting context and answer the workspace-relative
 * path to pass to `session new --prompt`.
 *
 * Called at the moment a draft becomes a session, never earlier: the branch,
 * the working tree and the project's own instruction files are read then, so
 * what the session freezes is what was true when it started.
 */
export async function renderGround(ws: Workspace, pkg: WithRef): Promise<string> {
  const call = await extRun(ws, formatWithRef(pkg), "render", {})
  if (call.code !== 0) throw new Error(said(call.stdout, call.stderr))
  let value: unknown
  try {
    value = JSON.parse(call.stdout.trim())
  } catch {
    throw new Error(`ground returned no result: ${said(call.stdout, call.stderr)}`)
  }
  const prompt = (value as { prompt?: unknown }).prompt
  if (typeof prompt !== "string" || prompt.length === 0) {
    throw new Error(`ground wrote no context file: ${said(call.stdout, call.stderr)}`)
  }
  return prompt
}

function said(stdout: string, stderr: string): string {
  const text = stderr.trim() || stdout.trim()
  return text.length > 0 ? text : "no output"
}
