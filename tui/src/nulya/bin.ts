/**
 * Where the `nulya` binary and the workspace live. The TUI is a driver client
 * over a process boundary, so "which binary" and "which
 * workspace" are the two coordinates everything else in `src/nulya/` needs.
 */
import { existsSync } from "node:fs"
import { dirname, isAbsolute, join, resolve } from "node:path"

export interface Workspace {
  /** Absolute directory that owns `.nulya/`; every CLI call runs with this cwd. */
  readonly dir: string
  /** Absolute path to the `nulya` executable. */
  readonly bin: string
}

const exe = process.platform === "win32" ? "nulya.exe" : "nulya"

/** Walk up from `start` looking for `zig-out/bin/nulya[.exe]`. */
function findBuiltBinary(start: string): string | null {
  let dir = resolve(start)
  for (;;) {
    const candidate = join(dir, "zig-out", "bin", exe)
    if (existsSync(candidate)) return candidate
    const up = dirname(dir)
    if (up === dir) return null
    dir = up
  }
}

/**
 * NULYA_BIN wins; then a `zig-out/bin/` build at or above the workspace; then
 * one at or above this package (running the TUI from `tui/` inside the repo);
 * then PATH. Throws with all three candidates named when nothing resolves —
 * "binary not found" is the first thing a new user hits.
 */
export function resolveBin(workspaceDir: string, env: Record<string, string | undefined> = process.env): string {
  const explicit = env["NULYA_BIN"]
  if (explicit && explicit.length > 0) {
    const path = isAbsolute(explicit) ? explicit : resolve(workspaceDir, explicit)
    if (!existsSync(path)) throw new Error(`NULYA_BIN points at '${path}', which does not exist`)
    return path
  }
  const built = findBuiltBinary(workspaceDir) ?? findBuiltBinary(import.meta.dir)
  if (built) return built
  const onPath = Bun.which(exe) ?? Bun.which("nulya")
  if (onPath) return onPath
  throw new Error(
    `cannot find the nulya binary: set NULYA_BIN, run \`zig build\` in the repo, or put ${exe} on PATH`,
  )
}

export function openWorkspace(dir: string = process.cwd(), env: Record<string, string | undefined> = process.env): Workspace {
  const abs = resolve(dir)
  return { dir: abs, bin: resolveBin(abs, env) }
}
