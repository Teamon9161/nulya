/**
 * `src/browsedir.ts`'s `DirSource` seam (tui.md §11 T101): the one function
 * — `browseAt` — that local and remote directory browsing both call, proven
 * here with two FAKE sources rather than real disk or a real channel. One
 * fake speaks the way `local` does (drive letters, `~`, backslash-ish join);
 * the other speaks the way `remote:` does (POSIX-only, no host `~` to
 * expand). If the two disagree about what the same typed line means, this is
 * where that would show up — `dirsource.test.ts` covers the REAL
 * implementations wired to real disk and a real channel.
 */
import { expect, test } from "bun:test"
import { basename as basenamePosix, dirname as dirnamePosix, join as joinPosix } from "node:path/posix"
import { basename as basenameWin, dirname as dirnameWin, join as joinWin } from "node:path/win32"
import { browseAt, browserRows, resolveTypedAsync, type DirChild, type DirSource } from "../src/browsedir.ts"

/** An in-memory tree, read the way a source with no real disk would: exact path match, nothing speculative. */
function fakeSource(tree: Record<string, string[]>, style: "posix" | "win32"): DirSource & { calls: string[] } {
  const calls: string[] = []
  const known = new Set(Object.keys(tree))
  const { join, dirname, basename } = style === "posix"
    ? { join: joinPosix, dirname: dirnamePosix, basename: basenamePosix }
    : { join: joinWin, dirname: dirnameWin, basename: basenameWin }
  return {
    calls,
    async list(dir) {
      calls.push(`list:${dir}`)
      const names = tree[dir] ?? []
      return names.map((name): DirChild => ({ name, workspace: false }))
    },
    async exists(path) {
      calls.push(`exists:${path}`)
      return known.has(path)
    },
    join,
    dirname,
    basename,
    expand(input, base) {
      const raw = input.trim()
      if (raw.length === 0) return base
      if (style === "posix") {
        const absolute = raw.startsWith("/") ? raw : join(base, raw)
        // Normalise away a trailing separator, the same as `resolve()` does
        // for the local source's `expandPath` — a fake that kept it would be
        // testing its own quirk, not the contract `resolveTypedAsync` relies
        // on (an absolute answer, ready to compare against `exists`).
        return absolute.length > 1 ? absolute.replace(/\/+$/, "") : absolute
      }
      // The win32-like fake: a drive letter is absolute, everything else is
      // relative to `base` — deliberately NOT `expandPath`'s `~` handling,
      // so this stays a fake with its own rules rather than a re-import of
      // the local source under another name.
      return /^[A-Za-z]:[\\/]/.test(raw) ? raw : join(base, raw)
    },
  }
}

test("browseAt drives a POSIX-shaped fake and a drive-letter-shaped fake through the exact same code", async () => {
  const posix = fakeSource(
    { "/home/me": ["project", "notes"], "/home/me/project": ["src"] },
    "posix",
  )
  const win = fakeSource(
    { "C:\\Users\\me": ["project", "notes"], "C:\\Users\\me\\project": ["src"] },
    "win32",
  )

  const onPosix = await browseAt("", "/home/me", posix)
  expect(onPosix.dir).toBe("/home/me")
  expect(onPosix.children.map((c) => c.name).sort()).toEqual(["notes", "project"])

  const onWin = await browseAt("", "C:\\Users\\me", win)
  expect(onWin.dir).toBe("C:\\Users\\me")
  expect(onWin.children.map((c) => c.name).sort()).toEqual(["notes", "project"])

  // Typing a name that resolves to a real subdirectory navigates into it —
  // same behaviour, different separators.
  const intoPosix = await browseAt("project", "/home/me", posix)
  expect(intoPosix.dir).toBe("/home/me/project")
  expect(intoPosix.filter).toBe("")

  const intoWin = await browseAt("project", "C:\\Users\\me", win)
  expect(intoWin.dir).toBe("C:\\Users\\me\\project")
  expect(intoWin.filter).toBe("")
})

test("resolveTypedAsync: an unresolved name is a filter on its parent, for either shape", async () => {
  const posix = fakeSource({ "/home/me": ["project"] }, "posix")
  const resolved = await resolveTypedAsync("proj", "/home/me", posix)
  expect(resolved).toEqual({ dir: "/home/me", filter: "proj" })

  const win = fakeSource({ "C:\\Users\\me": ["project"] }, "win32")
  const resolvedWin = await resolveTypedAsync("proj", "C:\\Users\\me", win)
  expect(resolvedWin).toEqual({ dir: "C:\\Users\\me", filter: "proj" })
})

test("resolveTypedAsync: a trailing separator means 'inside this one', even before it exists", async () => {
  const posix = fakeSource({}, "posix")
  expect(await resolveTypedAsync("/home/me/fresh/", "/home/me", posix)).toEqual({
    dir: "/home/me/fresh",
    filter: "",
  })
})

test("browserRows: join/dirname are the SOURCE's, not node:path's default — a Windows host browsing a remote: target must not get backslashes", () => {
  const posix = fakeSource({ "/srv/app": ["logs"] }, "posix")
  const rows = browserRows({
    dir: "/srv/app",
    children: [{ name: "logs", workspace: false }],
    recents: [],
    homeDir: "/home/me",
    label: (dir) => dir,
    join: posix.join,
    dirname: posix.dirname,
  })
  const child = rows.find((row) => row.kind === "child")!
  expect(child.path).toBe("/srv/app/logs")
  expect(child.path).not.toContain("\\")
  const parent = rows.find((row) => row.kind === "parent")!
  expect(parent.path).toBe("/srv")

  // Omitting the overrides falls back to the host's own `node:path` — the
  // exact behaviour every caller had before this seam existed. On this test
  // host (Windows) that means the SAME inputs come back joined with `\`,
  // which is exactly the bug this seam exists to keep out of a remote
  // listing: the override is not cosmetic, it changes the separator.
  const defaulted = browserRows({
    dir: "/srv/app",
    children: [{ name: "logs", workspace: false }],
    recents: [],
    homeDir: "/home/me",
    label: (dir) => dir,
  })
  const defaultedChild = defaulted.find((row) => row.kind === "child")!.path
  if (process.platform === "win32") {
    expect(defaultedChild).not.toBe(child.path)
    expect(defaultedChild).toContain("\\")
  } else {
    // On a POSIX test host, `node:path`'s default already agrees with the
    // posix fake — there is nothing to keep out here, which is the point.
    expect(defaultedChild).toBe(child.path)
  }
})

test("browseAt only asks the source about the directories it actually needs to", async () => {
  const source = fakeSource({ "/home/me": ["a", "b"], "/home/me/a": ["c"] }, "posix")
  await browseAt("a", "/home/me", source)
  // `expand("a", base)` is not absolute, so `exists` is asked about
  // `/home/me/a`, and — since it exists — `list` is asked about it too.
  // Nothing was asked about `/home/me/b` or anywhere else in the tree.
  expect(source.calls).toEqual(["exists:/home/me/a", "list:/home/me/a"])
})
