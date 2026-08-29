/**
 * `state/tui_state.ts`'s remote additions (tui.md §11 T101/T102): the
 * workspace that travels with `exec_env`, per-machine directory recents, and
 * the last `ext push` outcome per package.
 */
import { expect, test } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  execEnv,
  execWorkspace,
  lastPush,
  loadTuiState,
  remoteCwd,
  rememberExecEnv,
  rememberPush,
  rememberRemoteCwd,
} from "../src/state/tui_state.ts"

function statePath(): { path: string; cleanup(): void } {
  const dir = mkdtempSync(join(tmpdir(), "nulya-tuistate-"))
  return { path: join(dir, "tui-state.json"), cleanup: () => rmSync(dir, { recursive: true, force: true }) }
}

test("a remote spec and its workspace are remembered together, in the same call", () => {
  const state = statePath()
  try {
    rememberExecEnv("remote:ssh:box", state.path, "/srv/app")
    expect(execEnv(state.path)).toBe("remote:ssh:box")
    expect(execWorkspace(state.path)).toBe("/srv/app")
  } finally {
    state.cleanup()
  }
})

test("switching to a spec with no workspace clears a stale one — the pair travels together", () => {
  const state = statePath()
  try {
    rememberExecEnv("remote:ssh:box", state.path, "/srv/app")
    // Retyping `/env wsl` (no workspace argument at all) must not leave
    // `/srv/app` paired with a spec that was never chosen with it.
    rememberExecEnv("wsl", state.path)
    expect(execEnv(state.path)).toBe("wsl")
    expect(execWorkspace(state.path)).toBe("")
  } finally {
    state.cleanup()
  }
})

test("clearing the spec (local, or empty) clears the workspace too", () => {
  const state = statePath()
  try {
    rememberExecEnv("remote:ssh:box", state.path, "/srv/app")
    rememberExecEnv("local", state.path)
    expect(execEnv(state.path)).toBe("")
    expect(execWorkspace(state.path)).toBe("")
    expect(loadTuiState(state.path).exec_workspace).toBeUndefined()
  } finally {
    state.cleanup()
  }
})

test("an empty or whitespace workspace argument is treated as none", () => {
  const state = statePath()
  try {
    rememberExecEnv("remote:ssh:box", state.path, "   ")
    expect(execWorkspace(state.path)).toBe("")
  } finally {
    state.cleanup()
  }
})

test("remote_cwd remembers one directory per spec, and does not forget another machine's", () => {
  const state = statePath()
  try {
    expect(remoteCwd("remote:ssh:box", state.path)).toBeUndefined()
    rememberRemoteCwd("remote:ssh:box", "/srv/app", state.path)
    rememberRemoteCwd("remote:wsl:Ubuntu", "/home/me/proj", state.path)
    expect(remoteCwd("remote:ssh:box", state.path)).toBe("/srv/app")
    expect(remoteCwd("remote:wsl:Ubuntu", state.path)).toBe("/home/me/proj")
    // Picking a new directory on the same spec replaces its own entry only.
    rememberRemoteCwd("remote:ssh:box", "/srv/other", state.path)
    expect(remoteCwd("remote:ssh:box", state.path)).toBe("/srv/other")
    expect(remoteCwd("remote:wsl:Ubuntu", state.path)).toBe("/home/me/proj")
  } finally {
    state.cleanup()
  }
})

test("remote_pushed remembers the LAST push per package id, with a timestamp", () => {
  const state = statePath()
  try {
    expect(lastPush("lint", state.path)).toBeUndefined()
    rememberPush("lint", "remote:ssh:box", "lint@v-abc: pushed, 3 files", state.path)
    const first = lastPush("lint", state.path)
    expect(first).toBeDefined()
    expect(first!.spec).toBe("remote:ssh:box")
    expect(first!.said).toBe("lint@v-abc: pushed, 3 files")
    expect(typeof first!.at).toBe("string")
    // A second push overwrites the record — it is "last time", not a log.
    rememberPush("lint", "remote:ssh:box", "lint@v-abc: already there", state.path)
    expect(lastPush("lint", state.path)!.said).toBe("lint@v-abc: already there")
    // A different package's record is untouched.
    rememberPush("agent", "remote:wsl:Ubuntu", "agent@v-1: pushed, 5 files", state.path)
    expect(lastPush("lint", state.path)!.said).toBe("lint@v-abc: already there")
    expect(lastPush("agent", state.path)!.spec).toBe("remote:wsl:Ubuntu")
  } finally {
    state.cleanup()
  }
})

test("a file with malformed remote_cwd / remote_pushed entries drops only the malformed ones", async () => {
  const state = statePath()
  try {
    await Bun.write(
      state.path,
      JSON.stringify({
        remote_cwd: { good: "/srv/app", bad: 42 },
        remote_pushed: {
          good: { spec: "remote:ssh:box", said: "pushed", at: "2026-08-29T00:00:00Z" },
          bad: { spec: "remote:ssh:box" }, // missing `said`/`at`
          worse: "not even an object",
        },
      }),
    )
    const state_read = loadTuiState(state.path)
    expect(state_read.remote_cwd).toEqual({ good: "/srv/app" })
    expect(state_read.remote_pushed).toEqual({
      good: { spec: "remote:ssh:box", said: "pushed", at: "2026-08-29T00:00:00Z" },
    })
  } finally {
    state.cleanup()
  }
})
