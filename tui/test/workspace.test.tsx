/**
 * One tab, one directory (goals/tui-shell.md §5.3b, tui.md §11 T71).
 *
 * Two halves, and they are two halves on purpose. The MODEL half needs no
 * terminal and no binary: which rows a directory browser draws at a given path,
 * what the home workspace resolves to, what the recents file remembers, and
 * when the sessions list grows workspace headings. The SCREEN half spends a
 * real `nulya` and asserts the one thing none of that can prove — that a tab's
 * workspace is what its spawns actually run in, which is the whole claim of
 * S1c.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { basename, join, resolve, sep } from "node:path"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { createStyle } from "../src/render/theme.ts"
import { browserRows, expandPath, resolveTyped, visibleChildren, type DirChild } from "../src/browsedir.ts"
import { loadRecents, rememberRecent, recentsPath } from "../src/state/recents.ts"
import { homeWorkspaceDir, isHomeWorkspaceDir, openWorkspaceAt, workspaceLabel } from "../src/workspaces.ts"
import {
  firstSelectable,
  groupedRows,
  nextSelectable,
  type ListRow,
  type SessionGroup,
} from "../src/ui/overlays/SessionsView.tsx"
import { loadTuiState, rememberTabs } from "../src/state/tui_state.ts"
import { sessionList } from "../src/nulya/cli.ts"
import type { SessionListEntry } from "../src/nulya/cli.ts"
import type { Workspace } from "../src/nulya/bin.ts"
import type { JSX } from "solid-js"
import { DirBrowser } from "../src/ui/overlays/DirBrowser.tsx"
import { CheckoutPrompt, choiceHint, promptLines } from "../src/ui/CheckoutPrompt.tsx"
import { planCheckout } from "../src/extensions.ts"
import { SessionsView } from "../src/ui/overlays/SessionsView.tsx"
import { StyleContext } from "../src/render/theme.ts"
import { FoldContext, createFoldStore } from "../src/state/folds.ts"
import { displayWidth } from "../src/ui/columns.ts"
import { sessionNew } from "../src/nulya/cli.ts"
import {
  frameLines,
  scripted_env,
  settle,
  tempWorkspace,
  unsafe_settings,
  until,
  type TempWorkspace,
} from "./support.ts"

// ── the home workspace (§5.3b point 5) ──────────────────────────────────────

test("the home workspace is one directory below the user layer, and NULYA_HOME moves it", () => {
  const env = { NULYA_HOME: join(sep, "somewhere", ".nulya") }
  const home = homeWorkspaceDir(env)
  // One directory DOWN, never `~/.nulya` itself: collapsing the user layer onto
  // a workspace store is what would make the kernel's trust gate refuse to open
  // a session at all (DESIGN §9).
  expect(home).toBe(join(sep, "somewhere", ".nulya", "home"))
  expect(home).not.toBe(env.NULYA_HOME)
  expect(isHomeWorkspaceDir(home, env)).toBe(true)
  expect(isHomeWorkspaceDir(env.NULYA_HOME, env)).toBe(false)
  expect(workspaceLabel(home, env)).toBe("no project")
  expect(workspaceLabel(join(sep, "src", "nulya"), env)).toBe("nulya")
})

test("opening the home workspace creates it; opening another directory creates nothing", () => {
  const box = mkdtempSync(join(tmpdir(), "nulya-home-"))
  try {
    const env = { ...process.env, NULYA_HOME: join(box, "user") }
    const home = openWorkspaceAt(homeWorkspaceDir(env), env)
    expect(existsSync(home.dir)).toBe(true)
    // Every other path is a directory somebody already has: this must never
    // conjure one, so a missing one stays missing and fails where it is used.
    const absent = join(box, "not-there")
    openWorkspaceAt(absent, env)
    expect(existsSync(absent)).toBe(false)
  } finally {
    rmSync(box, { recursive: true, force: true })
  }
})

// ── the path field (§5.3b point 2) ──────────────────────────────────────────

test("a typed path expands ~, drive letters and relatives", () => {
  // Resolved, so the expectations below are the same shape on both platforms:
  // on Windows a rooted path still carries a drive letter.
  const env = { HOME: resolve(sep, "home", "t"), USERPROFILE: resolve(sep, "home", "t") }
  const base = resolve(sep, "base", "dir")
  expect(expandPath("~", base, env)).toBe(env.HOME)
  expect(expandPath("~/src", base, env)).toBe(join(env.HOME, "src"))
  // A Windows drive letter is absolute even where `path.isAbsolute` says
  // otherwise: this browser gets pasted paths from the other platform all day.
  expect(expandPath("D:", base, env)).toBe(`D:${sep}`)
  expect(expandPath("D:\\src", base, env)).toBe("D:\\src")
  expect(expandPath("sub", base, env)).toBe(join(base, "sub"))
  // Nothing typed is where you already are, never the filesystem root.
  expect(expandPath("   ", base, env)).toBe(base)
})

test("typing narrows the listing instead of emptying it", () => {
  const base = resolve(sep, "base")
  const src = join(base, "src")
  const here = (path: string) => path === src
  // A complete, existing directory: browse it, nothing left over.
  expect(resolveTyped(src, base, here)).toEqual({ dir: src, filter: "" })
  // Half a name: the parent is listed and the rest is a filter, which is what
  // makes "type a bit, then click" work.
  const partial = resolveTyped(join(base, "sr"), base, here)
  expect(partial.dir).toBe(base)
  expect(partial.filter).toBe("sr")
  // A trailing separator means "inside this one" even before it exists, so the
  // last component does not flicker into a filter as it is finished.
  expect(resolveTyped(`${src}${sep}`, base, () => false).filter).toBe("")
})

test("only directories, sorted, and never a dot-directory", () => {
  const children: DirChild[] = [
    { name: "zeta", workspace: false },
    { name: ".git", workspace: false },
    { name: "alpha", workspace: true },
    { name: "beta", workspace: false },
  ]
  expect(visibleChildren(children).map((child) => child.name)).toEqual(["alpha", "beta", "zeta"])
  expect(visibleChildren(children, "b").map((child) => child.name)).toEqual(["beta"])
})

// ── the browser's rows (§5.3b point 2) ──────────────────────────────────────

const home_dir = join(sep, "user", ".nulya", "home")

function rowsAt(dir: string, children: DirChild[], recents: string[] = []) {
  return browserRows({
    dir,
    children,
    recents,
    homeDir: home_dir,
    label: (path) => (path === home_dir ? "no project" : path.split(/[\\/]/).filter(Boolean).pop() ?? path),
    isWorkspace: (path) => path === join(sep, "src", "nulya"),
  })
}

test("no project is always the first row, and `..` always heads the subdirectories", () => {
  const rows = rowsAt(join(sep, "src"), [
    { name: "nulya", workspace: true },
    { name: "notes", workspace: false },
  ], [join(sep, "src", "nulya")])
  expect(rows[0]!.kind).toBe("home")
  expect(rows[0]!.label).toBe("no project")
  expect(rows[0]!.path).toBe(home_dir)
  // The recents come after it and before the current directory's own row.
  expect(rows.map((row) => row.kind)).toEqual(["home", "recent", "use", "parent", "child", "child"])
  const subdirs = rows.filter((row) => row.section === "subdirs")
  expect(subdirs[0]!.label).toBe("..")
  expect(subdirs.slice(1).map((row) => row.label)).toEqual(["notes", "nulya"])
  // A directory row is entered; the standing answers are chosen. The
  // distinction is data, so a click and an `Enter` cannot disagree about it.
  expect(subdirs[0]!.action).toBe("enter")
  expect(rows.find((row) => row.kind === "use")!.action).toBe("choose")
})

test("a directory that already holds a .nulya/ is marked", () => {
  const rows = rowsAt(join(sep, "src"), [
    { name: "nulya", workspace: true },
    { name: "notes", workspace: false },
  ])
  expect(rows.find((row) => row.label === "nulya")!.workspace).toBe(true)
  expect(rows.find((row) => row.label === "notes")!.workspace).toBe(false)
})

test("no place is offered twice on one screen", () => {
  const here = join(sep, "src", "nulya")
  const rows = rowsAt(here, [], [here, home_dir, join(sep, "src", "notes")])
  // The home workspace has its standing row and the browsed directory has
  // `use this directory`; neither is repeated among the recents.
  expect(rows.filter((row) => row.path === home_dir)).toHaveLength(1)
  expect(rows.filter((row) => row.path === here)).toHaveLength(1)
  expect(rows.filter((row) => row.kind === "recent").map((row) => row.path)).toEqual([join(sep, "src", "notes")])
})

test("the filesystem root has no parent row", () => {
  const rows = rowsAt(sep, [{ name: "usr", workspace: false }])
  expect(rows.some((row) => row.label === "..")).toBe(false)
})

// ── recents, in the user layer (§5.3b point 3) ──────────────────────────────

test("recents remember newest first, drop repeats, and never record no project", () => {
  const box = mkdtempSync(join(tmpdir(), "nulya-recents-"))
  try {
    const env = { ...process.env, NULYA_HOME: join(box, "user") }
    const path = recentsPath(env)
    expect(loadRecents(path)).toEqual([]) // nothing written yet is an empty list, not a throw
    rememberRecent(join(box, "a"), path, env)
    rememberRecent(join(box, "b"), path, env)
    rememberRecent(join(box, "a"), path, env)
    expect(loadRecents(path)).toEqual([join(box, "a"), join(box, "b")])
    // The home workspace has a standing row of its own; a recent for it would
    // be the same place offered twice.
    rememberRecent(homeWorkspaceDir(env), path, env)
    expect(loadRecents(path)).toEqual([join(box, "a"), join(box, "b")])
    // Garbage is nothing remembered, never a screen that will not open.
    writeFileSync(path, "not json at all")
    expect(loadRecents(path)).toEqual([])
  } finally {
    rmSync(box, { recursive: true, force: true })
  }
})

// ── grouping (§5.3b point 4) ────────────────────────────────────────────────

function entry(id: string): SessionListEntry {
  return {
    id,
    created: new Date().toISOString(),
    first_user_text: `about ${id}`,
    composition: { active: [], native_tools: [], prompts: [] },
  } as unknown as SessionListEntry
}

const ws_a = { dir: join(sep, "src", "alpha"), bin: "nulya" } as Workspace
const ws_b = { dir: join(sep, "src", "beta"), bin: "nulya" } as Workspace

test("one workspace draws no heading at all", () => {
  const groups: SessionGroup[] = [{ ws: ws_a, entries: [entry("s-1"), entry("s-2")] }]
  const rows = groupedRows(groups, false)
  expect(rows.every((row) => row.kind === "session")).toBe(true)
  expect(rows).toHaveLength(2)
})

test("a second workspace is what makes headings appear, and an empty group keeps its own", () => {
  const groups: SessionGroup[] = [
    { ws: ws_a, entries: [entry("s-1")] },
    { ws: ws_b, entries: [] },
  ]
  const rows = groupedRows(groups, false)
  expect(rows.map((row) => row.kind)).toEqual(["group", "session", "group"])
  // A directory somebody has just walked into and said nothing in yet is
  // precisely the one they need to see is there.
  expect((rows[2] as Extract<ListRow, { kind: "group" }>).ws.dir).toBe(ws_b.dir)
  // Each session knows its own workspace: acting on one in another directory
  // means spawning with THAT directory's cwd.
  expect((rows[1] as Extract<ListRow, { kind: "session" }>).ws.dir).toBe(ws_a.dir)
})

test("the cursor walks sessions and steps over headings", () => {
  const rows = groupedRows(
    [
      { ws: ws_a, entries: [entry("s-1")] },
      { ws: ws_b, entries: [entry("s-2"), entry("s-3")] },
    ],
    false,
  )
  // group, s-1, group, s-2, s-3
  expect(firstSelectable(rows)).toBe(1)
  expect(nextSelectable(rows, 1, 1)).toBe(3) // the heading between them is not a stop
  expect(nextSelectable(rows, 3, 1)).toBe(4)
  // Nothing further that way leaves the cursor alone rather than wrapping.
  expect(nextSelectable(rows, 4, 1)).toBe(4)
  expect(nextSelectable(rows, 1, -1)).toBe(1)
})

// ── the browser and the grouped list, on screen ─────────────────────────────

/** Replace a run-specific path (and its basename) with a fixed-width stand-in. */
function mask(frame: string, real: string, token: string): string {
  const name = basename(real)
  return frame
    .replaceAll(real, token.padEnd(real.length))
    .replaceAll(name, `${token}-name`.padEnd(name.length))
}

async function overlayFrame(node: () => JSX.Element, width = 120, height = 24) {
  return testRender(
    () => (
      <StyleContext.Provider value={createStyle(unsafe_settings, {})}>
        <FoldContext.Provider value={createFoldStore()}>{node()}</FoldContext.Provider>
      </StyleContext.Provider>
    ),
    { width, height },
  )
}

test("the directory browser draws its sections at 80 and at 120", async () => {
  const box = mkdtempSync(join(tmpdir(), "nulya-browse-"))
  const elsewhere = mkdtempSync(join(tmpdir(), "nulya-elsewhere-"))
  try {
    mkdirSync(join(box, "alpha", ".nulya"), { recursive: true })
    mkdirSync(join(box, "beta"), { recursive: true })
    mkdirSync(join(box, ".hidden"), { recursive: true })
    for (const width of [80, 120]) {
      const setup = await overlayFrame(
        () => <DirBrowser start={box} recents={[elsewhere]} onChoose={() => {}} onClose={() => {}} />,
        width,
      )
      try {
        const raw = await settle(setup, 5)
        expect(raw).toContain("no project") // the standing first row, ahead of the recents
        expect(raw).toContain("use this directory")
        expect(raw).toContain("..")
        expect(raw).toContain("alpha")
        expect(raw).toContain("beta")
        expect(raw).not.toContain(".hidden") // dot-directories are noise in every repository
        expect(raw).toContain("Esc close")
        expect(frameLines(raw).every((line) => displayWidth(line) <= width)).toBe(true)
        // The temp paths differ on every run and on every machine, so they are
        // masked before the frame is kept — PADDED to the same number of
        // columns, because a snapshot is here to pin the layout and a mask
        // that shortened a line would pin a layout nobody ever saw. (T69's
        // stopped clock, one kind of moving target further.)
        const frame = mask(mask(raw, box, "<dir>"), elsewhere, "<elsewhere>")
        expect(frame).toMatchSnapshot(`browser-${width}`)
      } finally {
        setup.renderer.destroy()
      }
    }
  } finally {
    rmSync(box, { recursive: true, force: true })
    rmSync(elsewhere, { recursive: true, force: true })
  }
}, 60_000)

test("a second workspace is what puts headings on the list", async () => {
  const one = tempWorkspace()
  const two = tempWorkspace()
  try {
    await sessionNew(one, { profile: "scripted" })
    await sessionNew(two, { profile: "scripted" })
    const alone = await overlayFrame(() => (
      <SessionsView workspaces={[one]} currentId="" onSwitch={() => {}} onOpenTab={() => {}} onNew={() => {}} onClose={() => {}} />
    ))
    try {
      // One directory: no heading anywhere — the screen everybody has had is
      // the screen they still have.
      expect(await settle(alone, 6)).not.toContain(workspaceLabel(two.dir))
    } finally {
      alone.renderer.destroy()
    }
    const both = await overlayFrame(() => (
      <SessionsView
        workspaces={[one, two]}
        currentId=""
        onSwitch={() => {}}
        onOpenTab={() => {}}
        onNew={() => {}}
        onClose={() => {}}
      />
    ))
    try {
      const frame = await settle(both, 6)
      expect(frame).toContain(workspaceLabel(one.dir))
      expect(frame).toContain(workspaceLabel(two.dir))
      // The full view has room for the path that disambiguates two checkouts
      // of the same repository.
      expect(frame).toContain(one.dir)
    } finally {
      both.renderer.destroy()
    }
    // …and the rail does not: at that width the name is all that fits, and a
    // five-column stub of a path is noise in front of the word that works.
    const rail = await overlayFrame(
      () => (
        <SessionsView
          workspaces={[one, two]}
          variant="sidebar"
          width={30}
          currentId=""
          onSwitch={() => {}}
          onOpenTab={() => {}}
          onNew={() => {}}
          onClose={() => {}}
        />
      ),
      30,
    )
    try {
      const frame = await settle(rail, 6)
      expect(frame).toContain(workspaceLabel(one.dir))
      expect(frame).not.toContain(one.dir)
    } finally {
      rail.renderer.destroy()
    }
  } finally {
    one.cleanup()
    two.cleanup()
  }
}, 90_000)

test("the checkout question is the same bargain on screen as on the terminal", async () => {
  const plan = planCheckout(
    { kind: "ask", store: join(sep, "src", "thing", ".nulya", "extensions"), drafts: ["lint · builds"] },
    { kind: "none" },
  )
  expect(plan.kind).toBe("ask")
  const ask = plan as Extract<typeof plan, { kind: "ask" }>
  // The words and the keys are the plan's, so the two askings cannot drift
  // into offering different bargains — the dialog only re-presents them.
  expect(promptLines(ask).some((line) => line.includes("lint · builds"))).toBe(true)
  expect(promptLines(ask).some((line) => line.includes("  t  "))).toBe(false)
  expect(choiceHint(ask)).toContain("t trust")
  // …and the bare terminal's echo prompt is not a line in a dialog.
  expect(promptLines(ask).some((line) => line.includes("›"))).toBe(false)

  const setup = await overlayFrame(() => <CheckoutPrompt where="thing" plan={ask} />, 80, 10)
  try {
    const frame = await settle(setup, 4)
    expect(frame).toContain("thing")
    expect(frame).toContain("lint · builds")
    expect(frame).toContain("t trust")
    expect(frameLines(frame).every((line) => displayWidth(line) <= 80)).toBe(true)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

// ── the screen: a tab's workspace is where its spawns run ───────────────────

const style = createStyle(
  { ...unsafe_settings, extensions: { ...unsafe_settings.extensions, sync_on_start: false, auto_activate: false } },
  {},
)

let here: TempWorkspace
let there: TempWorkspace

beforeAll(() => {
  here = tempWorkspace()
  there = tempWorkspace()
})

afterAll(() => {
  here.cleanup()
  there.cleanup()
})

test("`/cwd` re-points the draft, and the session lands in THAT directory", async () => {
  const state = join(mkdtempSync(join(tmpdir(), "nulya-state-")), "tui-state.json")
  const setup = await testRender(
    () => (
      <App
        ws={here}
        pick={{ profile: "scripted", model: "scripted-demo" }}
        style={style}
        statePath={state}
        driver={{ env: scripted_env }}
      />
    ),
    { width: 100, height: 30 },
  )
  try {
    await settle(setup, 4)
    // The screen opens in the directory the process was launched in.
    expect(setup.captureCharFrame()).toContain(here.dir.slice(-20))

    await setup.mockInput.typeText(`/cwd ${there.dir}`)
    setup.mockInput.pressEnter()
    await settle(setup, 4)

    await setup.mockInput.typeText("hello")
    setup.mockInput.pressEnter()
    // `session new` runs with the tab's cwd, so the file is created over there
    // and nothing at all appears here. This is the whole claim of S1c.
    await until(async () => (await sessionList(there)).length === 1, 40_000)
    expect((await sessionList(here)).length).toBe(0)
  } finally {
    setup.renderer.destroy()
  }
}, 90_000)

test("`no project` lands in the home workspace, and asks no renderer for a project's opening text", async () => {
  // A renderer that does not exist: in an ordinary workspace the screen says
  // so, which is exactly what makes its SILENCE in the home workspace evidence
  // that the loop did not run rather than that it happened to succeed.
  const ghosted = createStyle(
    {
      ...unsafe_settings,
      extensions: {
        ...unsafe_settings.extensions,
        sync_on_start: false,
        auto_activate: false,
        session_prompts: ["ghost"],
      },
    },
    {},
  )
  const home = openWorkspaceAt(homeWorkspaceDir())
  const before = (await sessionList(home)).length

  const open = async (where: TempWorkspace | Workspace, go: string) => {
    const state = join(mkdtempSync(join(tmpdir(), "nulya-state-")), "tui-state.json")
    const setup = await testRender(
      () => (
        <App
          ws={where as Workspace}
          pick={{ profile: "scripted", model: "scripted-demo" }}
          style={ghosted}
          statePath={state}
          driver={{ env: scripted_env }}
        />
      ),
      { width: 100, height: 24 },
    )
    await settle(setup, 4)
    if (go.length > 0) {
      await setup.mockInput.typeText(`/cwd ${go}`)
      setup.mockInput.pressEnter()
      await settle(setup, 4)
    }
    await setup.mockInput.typeText("hello")
    setup.mockInput.pressEnter()
    return setup
  }

  const project = await open(here, "")
  try {
    // An ordinary workspace does ask, and says what it could not find.
    await until(() => project.captureCharFrame().includes("not composed in"), 30_000)
  } finally {
    project.renderer.destroy()
  }

  const nowhere = await open(here, home.dir)
  try {
    // The session is real and it is in the home workspace — under NULYA_HOME,
    // one directory below the user layer, never `~/.nulya` itself (§5.3b).
    await until(async () => (await sessionList(home)).length === before + 1, 40_000)
    expect(homeWorkspaceDir().startsWith(process.env["NULYA_HOME"]!)).toBe(true)
    // …and nothing was asked for an opening text: there is no project for one
    // to describe, so the renderer is not run rather than run and ignored.
    expect(await settle(nowhere, 3)).not.toContain("not composed in")
  } finally {
    nowhere.renderer.destroy()
  }
}, 120_000)

test("a new tab starts in the directory the front tab works in", async () => {
  const state = join(mkdtempSync(join(tmpdir(), "nulya-state-")), "tui-state.json")
  const setup = await testRender(
    () => (
      <App
        ws={here}
        pick={{ profile: "scripted", model: "scripted-demo" }}
        style={style}
        statePath={state}
        driver={{ env: scripted_env }}
      />
    ),
    { width: 100, height: 24 },
  )
  try {
    await settle(setup, 4)
    await setup.mockInput.typeText(`/cwd ${there.dir}`)
    setup.mockInput.pressEnter()
    await settle(setup, 4)
    // A draft is re-pointed rather than duplicated, so this tab has to become a
    // session before `+` has a second tab to open (T22).
    await setup.mockInput.typeText("hello")
    setup.mockInput.pressEnter()
    await until(() => (loadTuiState(state).tabs ?? [])[0]?.session !== undefined, 40_000)
    // `+` / a bare `/new`: another tab HERE, not one back in the directory the
    // process happened to be launched in.
    await setup.mockInput.typeText("/new")
    setup.mockInput.pressEnter()
    await until(() => (loadTuiState(state).tabs ?? []).length === 2, 20_000)
    expect((loadTuiState(state).tabs ?? []).map((tab) => tab.ws)).toEqual([there.dir, there.dir])
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("the workspace a tab works in is remembered, and a draft is not a tab to restore", async () => {
  const state = join(mkdtempSync(join(tmpdir(), "nulya-state-")), "tui-state.json")
  const setup = await testRender(
    () => (
      <App
        ws={here}
        pick={{ profile: "scripted", model: "scripted-demo" }}
        style={style}
        statePath={state}
        driver={{ env: scripted_env }}
      />
    ),
    { width: 100, height: 24 },
  )
  try {
    await settle(setup, 4)
    await until(() => (loadTuiState(state).tabs ?? []).length === 1, 20_000)
    const [only] = loadTuiState(state).tabs!
    expect(only!.ws).toBe(here.dir)
    // A draft is nothing on disk, so it carries no session to come back to.
    expect(only!.session).toBeUndefined()
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a remembered tab in another directory comes back beside the launch tab", async () => {
  const state = join(mkdtempSync(join(tmpdir(), "nulya-state-")), "tui-state.json")
  const run = Bun.spawnSync({ cmd: [there.bin, "session", "new", "--profile", "scripted"], cwd: there.dir, env: process.env })
  const id = run.stdout.toString().trim().split(/\s+/).pop() ?? ""
  expect(id.startsWith("s-")).toBe(true)
  // What the last run left: the launch tab, then one in the other directory.
  rememberTabs([{ ws: here.dir }, { ws: there.dir, session: id }], state)

  const setup = await testRender(
    () => (
      <App
        ws={here}
        pick={{ profile: "scripted", model: "scripted-demo" }}
        style={style}
        statePath={state}
        driver={{ env: scripted_env }}
      />
    ),
    { width: 100, height: 24 },
  )
  try {
    // Two tabs: the launch one, and the remembered session BACK IN ITS OWN
    // DIRECTORY — which is the half a session id alone could never restore.
    await until(() => (loadTuiState(state).tabs ?? []).length === 2, 30_000)
    expect(loadTuiState(state).tabs).toEqual([{ ws: here.dir }, { ws: there.dir, session: id }])
    // …and the strip is drawn, which it is not for a single tab (T22).
    expect(await settle(setup, 3)).toContain("✕")
  } finally {
    setup.renderer.destroy()
  }
}, 90_000)

test("a remembered tab whose session is gone is skipped, not opened into an error", async () => {
  const state = join(mkdtempSync(join(tmpdir(), "nulya-state-")), "tui-state.json")
  rememberTabs([{ ws: here.dir }, { ws: there.dir, session: "s-000000000000" }], state)
  const setup = await testRender(
    () => (
      <App
        ws={here}
        pick={{ profile: "scripted", model: "scripted-demo" }}
        style={style}
        statePath={state}
        driver={{ env: scripted_env }}
      />
    ),
    { width: 100, height: 24 },
  )
  try {
    const frame = await settle(setup, 5)
    expect(frame).not.toContain("s-000000000000")
    // One tab, so the strip is not drawn at all (T22).
    expect(loadTuiState(state).tabs).toHaveLength(1)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)
