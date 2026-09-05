/**
 * `acp.toml` — the standing approval tables for the editor-facing agent.
 *
 * A separate file from `tui.toml` because this is a separate driver, not a
 * second face of the screen: what a person tolerates in a terminal they are
 * watching and in an editor plugin they are not are different answers, and
 * `tui.toml` is otherwise full of theme, keys and transcript settings that mean
 * nothing here. Same two layers as every other config in this project — user
 * (`$NULYA_HOME` or `~/.nulya`), then the workspace's own — and the same
 * discipline: a nearer layer REPLACES a field rather than merging into it, so
 * narrowing is always available.
 *
 * `[approvals]` is the only section. The permission MODE is `--mode` on the
 * command line: an editor spawns this process per workspace already, so the
 * launch line is where that choice naturally lives, and a second place to say it
 * would be a second answer.
 *
 * Read-only, and never written: this file is a person's own text. Unreadable or
 * unparseable is "nothing said" — a driver that refused to start over its own
 * settings file would be worse than one that runs on the defaults and says so.
 */
import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { applyApprovals, default_rules, type ApprovalRules } from "../approvals.ts"
import { userConfigDir } from "../state/settings.ts"

export const file_name = "acp.toml"

/** User layer first, then the workspace's own; nearer wins. */
export function approvalPaths(workspaceDir: string, env: Record<string, string | undefined> = process.env): string[] {
  return [join(userConfigDir(env), file_name), join(workspaceDir, ".nulya", file_name)]
}

function tableOf(path: string, warn: (line: string) => void): Record<string, unknown> | undefined {
  if (!existsSync(path)) return undefined
  try {
    const parsed = Bun.TOML.parse(readFileSync(path, "utf8")) as Record<string, unknown>
    return parsed["approvals"] as Record<string, unknown> | undefined
  } catch (error) {
    warn(`${path}: ${error instanceof Error ? error.message : String(error)} — ignored`)
    return undefined
  }
}

/**
 * A reader keyed by workspace. The user layer is the same for every session this
 * process serves; the workspace layer is not, because each ACP session names its
 * own `cwd`. Cached per directory: a session asks once, and re-reading on every
 * call would let the tables change under a conversation already in flight.
 */
export function acpRules(
  env: Record<string, string | undefined> = process.env,
  warn: (line: string) => void = () => {},
): (workspaceDir: string) => ApprovalRules {
  const cache = new Map<string, ApprovalRules>()
  return (workspaceDir) => {
    const held = cache.get(workspaceDir)
    if (held) return held
    const rules: ApprovalRules = { ...default_rules }
    for (const path of approvalPaths(workspaceDir, env)) applyApprovals(tableOf(path, warn), rules)
    cache.set(workspaceDir, rules)
    return rules
  }
}
