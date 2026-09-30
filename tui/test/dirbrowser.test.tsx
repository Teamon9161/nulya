import { expect, test } from "bun:test"
import { basename, dirname, join, resolve } from "node:path/posix"
import { testRender } from "@opentui/solid"
import { createStyle, StyleContext } from "../src/render/theme.ts"
import type { DirChild, DirSource } from "../src/browsedir.ts"
import { DirBrowser } from "../src/ui/overlays/DirBrowser.tsx"
import { displayWidth } from "../src/ui/columns.ts"
import { frameLines, settle, unsafe_settings } from "./support.ts"

const start = "/srv/projects"
const tree: Record<string, DirChild[]> = {
  [start]: [
    { name: "alpha", workspace: true },
    { name: "beta", workspace: false },
    { name: "中文项目", workspace: false },
  ],
  [`${start}/alpha`]: [],
}

function source(list: DirSource["list"] = async (dir) => tree[dir] ?? []): DirSource {
  return {
    list,
    exists: async (dir) => dir in tree,
    join,
    dirname,
    basename,
    expand: (input, base) => resolve(base, input || "."),
  }
}

async function browser(options: {
  width?: number
  height?: number
  ascii?: boolean
  light?: boolean
  noColor?: boolean
  source?: DirSource
  onChoose?: (dir: string) => void
  onClose?: () => void
  on?: string
} = {}) {
  const style = createStyle({
    ...unsafe_settings,
    transcript: { ...unsafe_settings.transcript, ascii: options.ascii ?? false },
    ui: { ...unsafe_settings.ui, theme: options.light ? "nulya-light" : "nulya-dark" },
  }, options.noColor ? { NO_COLOR: "1" } : {})
  return testRender(() => (
    <StyleContext.Provider value={style}>
      <DirBrowser
        start={start}
        recents={["/work/checkout", "/archive/checkout"]}
        source={options.source ?? source()}
        homeDir="/home/nulya"
        label={(dir) => dir === "/home/nulya" ? "no project" : basename(dir)}
        isWorkspace={() => false}
        onChoose={options.onChoose ?? (() => {})}
        onClose={options.onClose ?? (() => {})}
        on={options.on}
      />
    </StyleContext.Provider>
  ), { width: options.width ?? 80, height: options.height ?? 28 })
}

test("directory layout keeps actions and workspace marks readable across widths and themes", async () => {
  for (const options of [
    { width: 40 },
    { width: 80, light: true },
    { width: 120 },
    { width: 40, ascii: true, noColor: true },
  ]) {
    const setup = await browser(options)
    try {
      const frame = await settle(setup, 5)
      const lines = frameLines(frame)
      expect(frame).toContain("current directory")
      expect(frame).toContain("recent workspaces")
      expect(frame).toContain("中文项目/")
      expect(frame).toContain(options.ascii ? "+---" : "╭───")
      expect(frame).toContain(options.ascii ? "*" : "▪")
      const actionRows = lines.filter((line) => /\s(?:choose|open|up)\s*$/.test(line))
      expect(actionRows.length).toBeGreaterThan(0)
      const ends = actionRows.map((line) => displayWidth(line.trimEnd()))
      expect(new Set(ends).size).toBe(1)
      if (options.width >= 80) {
        expect(frame).toContain("/work/checkout")
        expect(frame).toContain("/archive/checkout")
      } else {
        expect(frame).not.toContain("/work/checkout")
      }
      expect(lines.every((line) => displayWidth(line) <= options.width)).toBe(true)
    } finally {
      setup.renderer.destroy()
    }
  }
}, 60_000)

test("Enter still enters a folder then chooses it, and clicks use the same actions", async () => {
  const chosen: string[] = []
  let closed = false
  const setup = await browser({
    source: source(async (dir) => (tree[dir] ?? []).filter((child) => child.name !== "中文项目")),
    onChoose: (dir) => chosen.push(dir),
    onClose: () => { closed = true },
  })
  try {
    await settle(setup, 5)
    setup.mockInput.pressArrow("down") // parent
    setup.mockInput.pressArrow("down") // alpha
    let frame = await settle(setup, 3)
    expect(frame).toContain("Enter open")
    expect(frame).toContain(`${start}/alpha`)
    setup.mockInput.pressEnter()
    frame = await settle(setup, 5)
    expect(chosen).toEqual([])
    expect(frame).toContain("no visible subdirectories")
    setup.mockInput.pressEnter()
    expect(chosen).toEqual([`${start}/alpha`])

    const rows = frameLines(frame)
    const recent = rows.findIndex((line) => line.includes("/archive/checkout"))
    expect(recent).toBeGreaterThanOrEqual(0)
    await setup.mockMouse.click(5, recent)
    expect(chosen.at(-1)).toBe("/archive/checkout")
    setup.mockInput.pressEscape()
    await settle(setup, 3)
    expect(closed).toBe(true)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("typing a prefix shows the resolved folder and an empty-filter message without losing path input", async () => {
  const chosen: string[] = []
  const setup = await browser({ onChoose: (dir) => chosen.push(dir) })
  try {
    await settle(setup, 5)
    await setup.mockInput.typeText("/zzjk")
    const frame = await settle(setup, 5)
    expect(frame).toContain("starts with zzjk")
    expect(frame).toContain("no matching folders")
    expect(frame).not.toContain("alpha/")
    setup.mockInput.pressEnter()
    expect(chosen).toEqual([start])
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a short remote browser scrolls to its cursor and distinguishes loading from an empty listing", async () => {
  let release!: (children: DirChild[]) => void
  const pending = new Promise<DirChild[]>((resolve) => { release = resolve })
  const setup = await browser({ width: 60, height: 16, on: "remote:ssh:dev", source: source(() => pending) })
  try {
    let frame = await settle(setup, 3)
    expect(frame).toContain("on remote:ssh:dev")
    expect(frame).toContain("listing")
    expect(frame).not.toContain("no visible subdirectories")
    release(Array.from({ length: 30 }, (_, i) => ({ name: `project-${String(i).padStart(2, "0")}`, workspace: false })))
    await settle(setup, 5)
    for (let i = 0; i < 40; i++) setup.mockInput.pressArrow("down")
    frame = await settle(setup, 5)
    expect(frame).toContain("project-29/")
    expect(frame).toContain("Enter open")
    expect(frame).toContain("Esc close")
    expect(frame).not.toContain("listing")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)
