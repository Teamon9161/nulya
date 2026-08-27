/**
 * Packages that RENDER a session's opening text rather than contribute it
 * (`docs/goals/ground.md`).
 *
 * A contributed `system_prompt` is bytes frozen inside a version: the same text
 * in every session, on every machine. Some opening text is the opposite —
 * today's date, this branch, this directory — and belongs to one session and
 * nothing else. That is what `session new --prompt` takes, and a package that
 * wants to supply it is a RENDERER: it writes a file and answers where.
 *
 * The convention, and the whole of it:
 *
 *   nulya ext run <id>@<v> render     →  {"prompt": "<workspace-relative path>"}
 *
 * `[extensions] session_prompts` in `tui.toml` lists which packages this front
 * end asks, the way `session_with` lists which it composes. The bundled
 * `ground` is the first entry and, today, the only one — but it is an entry,
 * not a branch: this module knows no package's name, and a second renderer
 * (workspace memory, repo policy) is a line of config rather than a
 * `renderFoo()` beside this one. The alternative was three pieces of
 * ground-specific knowledge in the front end — an id constant, a boolean, and a
 * named function — which is the abstraction bought and then walked back.
 */
import type { Workspace } from "./nulya/bin.ts"
import { extRun } from "./nulya/cli.ts"
import { formatWithRef, type WithRef } from "./with.ts"

/**
 * Ask one renderer for this session's opening text; answer the workspace-
 * relative path to pass to `session new --prompt`.
 *
 * Called at the moment a draft becomes a session, never earlier: whatever it
 * reports is read then, so what the session freezes is what was true when it
 * started.
 *
 * Throws with a sentence worth showing. The caller decides whether a session
 * starts without it — it always should — but the reason has to survive that
 * decision, or a renderer that is failing for its own reasons is reported as a
 * package that could not be found.
 */
export async function renderSessionPrompt(ws: Workspace, pkg: WithRef): Promise<string> {
  const call = await extRun(ws, formatWithRef(pkg), "render", {})
  if (call.code !== 0) throw new Error(`${pkg.id}: ${said(call.stdout, call.stderr)}`)
  let value: unknown
  try {
    value = JSON.parse(call.stdout.trim())
  } catch {
    throw new Error(`${pkg.id}: render returned no result — ${said(call.stdout, call.stderr)}`)
  }
  const prompt = (value as { prompt?: unknown }).prompt
  if (typeof prompt !== "string" || prompt.length === 0) {
    throw new Error(`${pkg.id}: render wrote no prompt file — ${said(call.stdout, call.stderr)}`)
  }
  return prompt
}

function said(stdout: string, stderr: string): string {
  const text = stderr.trim() || stdout.trim()
  return text.length > 0 ? text : "no output"
}
