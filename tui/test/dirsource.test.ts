/**
 * `src/dirsource.ts`'s two REAL implementations of `browsedir.ts`'s
 * `DirSource` (tui.md §11 T101): this machine's disk, and a channel to
 * another one. `browsedir.test.ts` proves the shared orchestration with
 * fakes; this proves the two real sources actually answer the questions
 * `browseAt` asks, and that the remote one is really a round trip rather
 * than a second local reader wearing a costume.
 *
 * The "remote" machine is `remote:exec:` pointed at this same binary — a
 * real channel, same trick the kernel's own e2e-remote uses (goals/
 * remote-env.md §5) — so `remoteDirSource` is exercised against production
 * code on both ends, not a stand-in.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { localDirSource, remoteDirSource } from "../src/dirsource.ts"
import { tempWorkspace, type TempWorkspace } from "./support.ts"

let ws: TempWorkspace
let spec: string

beforeAll(() => {
  ws = tempWorkspace()
  spec = `remote:exec:${ws.bin} remote serve`
})

afterAll(() => {
  ws.cleanup()
})

test("localDirSource: lists real subdirectories, never files, and answers exists() honestly", async () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-dirsource-"))
  try {
    mkdirSync(join(dir, "alpha"))
    mkdirSync(join(dir, "beta"))
    writeFileSync(join(dir, "a-file.txt"), "not a directory")
    const source = localDirSource()
    const children = await source.list(dir)
    expect(children.map((c) => c.name).sort()).toEqual(["alpha", "beta"])
    expect(await source.exists(join(dir, "alpha"))).toBe(true)
    expect(await source.exists(join(dir, "a-file.txt"))).toBe(false) // a file, not a directory
    expect(await source.exists(join(dir, "nope"))).toBe(false)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("localDirSource: an unreadable directory is a shorter listing, never a throw", async () => {
  const source = localDirSource()
  await expect(source.list(join(tmpdir(), "nulya-dirsource-does-not-exist"))).resolves.toEqual([])
})

test("remoteDirSource: lists the REMOTE machine's directory over a real channel, filtering files out the same way local does", async () => {
  const remote = mkdtempSync(join(tmpdir(), "nulya-dirsource-remote-"))
  try {
    mkdirSync(join(remote, "sub1"))
    mkdirSync(join(remote, "sub2"))
    writeFileSync(join(remote, "readme.txt"), "hi")
    const source = remoteDirSource(ws, spec)
    const children = await source.list(remote)
    expect(children.map((c) => c.name).sort()).toEqual(["sub1", "sub2"])
    // Never a workspace mark — the remote source has no cheap way to answer
    // that, and this picker's rows are all about-to-become one anyway.
    expect(children.every((c) => c.workspace === false)).toBe(true)
    expect(await source.exists(join(remote, "sub1"))).toBe(true)
    expect(await source.exists(join(remote, "not-there"))).toBe(false)
  } finally {
    rmSync(remote, { recursive: true, force: true })
  }
}, 30_000)

test("remoteDirSource: a channel that cannot be opened is a shorter listing, not a throw", async () => {
  const source = remoteDirSource(ws, "remote:exec:this-program-does-not-exist-anywhere")
  await expect(source.list("/tmp")).resolves.toEqual([])
  await expect(source.exists("/tmp")).resolves.toBe(false)
}, 30_000)

test("remoteDirSource: POSIX path arithmetic regardless of the HOST platform", () => {
  const source = remoteDirSource(ws, spec)
  // These are not disk operations — they must never depend on which OS this
  // test happens to run on, which is exactly the bug the module doc warns
  // about (`node:path`'s own `join` on win32 hands back backslashes).
  expect(source.join("/srv/app", "logs")).toBe("/srv/app/logs")
  expect(source.dirname("/srv/app/logs")).toBe("/srv/app")
  expect(source.basename("/srv/app/logs")).toBe("logs")
  expect(source.join("/srv/app", "logs")).not.toContain("\\")
})
