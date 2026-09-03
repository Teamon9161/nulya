/**
 * `state/tui_state.ts`'s remote fields: the
 * workspace that travels with `exec_env`, per-machine directory recents, and
 * the last `ext push` outcome per package.
 */
import { expect, test } from "bun:test"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  execEnv,
  execWorkspace,
  forgetRemoteEnv,
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
    // Retyping `/env remote:wsl:Ubuntu` (no workspace argument at all) must
    // not leave `/srv/app` paired with a spec that was never chosen with it.
    rememberExecEnv("remote:wsl:Ubuntu", state.path)
    expect(execEnv(state.path)).toBe("remote:wsl:Ubuntu")
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

test("a remembered bare ssh: exec target (retired 2026-08-30) is dropped back to local, not rewritten", () => {
  const state = statePath()
  try {
    // Written directly, not through `rememberExecEnv`: this is state left
    // behind by an OLDER build, from before `ssh:<dest>` was refused as an
    // exec target — the load path is what has to
    // cope with it, not the write path.
    writeFileSync(state.path, JSON.stringify({ exec_env: "ssh:box" }))
    expect(loadTuiState(state.path).exec_env).toBeUndefined()
    expect(execEnv(state.path)).toBe("")
    // `remote:ssh:` is a DIFFERENT spec (moves the workspace, not just the
    // shell) — dropping must never silently upgrade one into the other.
    writeFileSync(state.path, JSON.stringify({ exec_env: "remote:ssh:box" }))
    expect(execEnv(state.path)).toBe("remote:ssh:box")
  } finally {
    state.cleanup()
  }
})

test("a remembered bare wsl exec target (retired 2026-09-02) is dropped back to local, not rewritten", () => {
  const state = statePath()
  try {
    // Written directly, not through `rememberExecEnv`: state left behind by
    // an OLDER build, from before `wsl[:<distro>]` was refused as an exec
    // target.
    writeFileSync(state.path, JSON.stringify({ exec_env: "wsl" }))
    expect(loadTuiState(state.path).exec_env).toBeUndefined()
    expect(execEnv(state.path)).toBe("")
    writeFileSync(state.path, JSON.stringify({ exec_env: "wsl:Ubuntu" }))
    expect(execEnv(state.path)).toBe("")
    // `remote:wsl:` is a DIFFERENT spec (moves the workspace too) — dropping
    // must never silently upgrade one into the other.
    writeFileSync(state.path, JSON.stringify({ exec_env: "remote:wsl:Ubuntu" }))
    expect(execEnv(state.path)).toBe("remote:wsl:Ubuntu")
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

test("start-up forgets a remote target and its workspace, and keeps everything else", () => {
  const state = statePath()
  try {
    rememberExecEnv("remote:ssh:box", state.path, "/srv/app")
    rememberRemoteCwd("remote:ssh:box", "/srv/app", state.path)
    forgetRemoteEnv(state.path)
    // The connection is gone with the process that held it, and so is the
    // password that opened it: a remembered spec only buys a first message
    // that fails.
    expect(execEnv(state.path)).toBe("")
    expect(execWorkspace(state.path)).toBe("")
    // WHERE on that machine is worth keeping — picking it again lands there.
    expect(remoteCwd("remote:ssh:box", state.path)).toBe("/srv/app")
  } finally {
    state.cleanup()
  }
})

test("start-up leaves a local choice alone", () => {
  const state = statePath()
  try {
    rememberExecEnv("local", state.path)
    forgetRemoteEnv(state.path)
    expect(execEnv(state.path)).toBe("")
    rememberPush("std", "remote:ssh:box", "pushed", state.path)
    forgetRemoteEnv(state.path)
    expect(lastPush("std", state.path)?.said).toBe("pushed")
  } finally {
    state.cleanup()
  }
})
