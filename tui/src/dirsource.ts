/**
 * Two implementations of `browsedir.ts`'s `DirSource` — one line of real I/O
 * each, everything else already lives in the pure functions the browser
 * drives (`browseAt`, `browserRows`). This is the whole of what makes local
 * and remote directory browsing the same component (tui.md §11 T101,
 * goals/remote-env.md §3.9).
 */
import { readdirSync, statSync } from "node:fs"
import { basename as basenameLocal, dirname as dirnameLocal, join as joinLocal } from "node:path"
import { basename as basenamePosix, dirname as dirnamePosix, join as joinPosix } from "node:path/posix"
import type { Workspace } from "./nulya/bin.ts"
import { remoteLs } from "./nulya/cli.ts"
import { expandPath, type DirChild, type DirSource } from "./browsedir.ts"

/** Whether a directory already holds a `.nulya/` — "this one is already a workspace". Local only (see `remoteDirSource`). */
export function holdsWorkspace(dir: string): boolean {
  try {
    return statSync(joinLocal(dir, ".nulya")).isDirectory()
  } catch {
    return false
  }
}

/** This machine's disk — what `/cwd` has always read (moved here from `DirBrowser.tsx`, unchanged). */
export function localDirSource(): DirSource {
  return {
    async list(dir) {
      try {
        const out: DirChild[] = []
        for (const entry of readdirSync(dir, { withFileTypes: true })) {
          if (!entry.isDirectory()) continue
          out.push({ name: entry.name, workspace: holdsWorkspace(joinLocal(dir, entry.name)) })
        }
        return out
      } catch {
        return []
      }
    },
    async exists(path) {
      try {
        return statSync(path).isDirectory()
      } catch {
        return false
      }
    },
    join: joinLocal,
    dirname: dirnameLocal,
    basename: basenameLocal,
    expand: expandPath,
  }
}

/**
 * The machine `spec` names, read over `nulya remote ls`
 * (goals/remote-env.md §3.9). Path arithmetic is always POSIX
 * (`node:path/posix`) — a `remote:` target is `wsl` or `ssh`, which means
 * Linux on the far side even when this host is Windows, and `node:path`'s
 * own `join` on a win32 host hands back backslashes no shell over there
 * would understand.
 *
 * Never marks a directory as a workspace (`workspace` is always `false`):
 * answering that honestly would be a second remote round trip per row, for a
 * mark that — in a picker whose whole purpose is choosing where a session's
 * workspace goes — would have nothing left to distinguish, since every row
 * in it is a directory about to become one.
 *
 * `exists` is answered the only way it can be for a machine this process
 * cannot `stat`: try to list the path and see whether the agent says yes.
 * Both `list` and `exists` share one cache keyed by path, so typing the same
 * line more than once (editing, then editing back) costs one round trip, not
 * one per keystroke — a browser session is short-lived, so the cache is never
 * invalidated within it.
 */
export function remoteDirSource(ws: Workspace, spec: string): DirSource {
  const cache = new Map<string, DirChild[] | null>()
  const load = async (dir: string): Promise<DirChild[] | null> => {
    const cached = cache.get(dir)
    if (cached !== undefined) return cached
    const result = await remoteLs(ws, spec, dir)
      .then((entries) => entries.filter((entry) => entry.dir).map((entry) => ({ name: entry.name, workspace: false })))
      .catch(() => null)
    cache.set(dir, result)
    return result
  }
  return {
    async list(dir) {
      return (await load(dir)) ?? []
    },
    async exists(path) {
      return (await load(path)) !== null
    },
    join: joinPosix,
    dirname: dirnamePosix,
    basename: basenamePosix,
    expand(input, base) {
      const raw = input.trim()
      if (raw.length === 0) return base
      return raw.startsWith("/") ? raw : joinPosix(base, raw)
    },
  }
}
