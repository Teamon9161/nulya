/**
 * The pane tree, drawn and clicked.
 *
 * `panes.test.ts` pins the model; this pins the two claims the model cannot
 * make on its own:
 *
 *  - ONE PANE DRAWS AS ITSELF. The whole acceptance criterion of S1a is that
 *    today's screen is the new model's degenerate case, so a single-leaf tree
 *    has to paint what the surface painted with no host between them. Asserting
 *    that against a REFERENCE RENDER rather than against a stored frame is the
 *    point: a wrapper box that changed the layout would show up here even if
 *    every snapshot in the suite had been re-recorded around it.
 *  - A CLICK LANDS IN THE PANE THAT WAS DRAWN THERE, and does not stop the row
 *    under it from acting on the same click.
 */
import { expect, test } from "bun:test"
import { createSignal, type JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { PaneHost } from "../src/ui/PaneHost.tsx"
import { createSurfaceRegistry, host_owner, type SurfaceRegistry } from "../src/pane/registry.ts"
import { singlePane, splitPane, type PaneTree } from "../src/pane/tree.ts"
import { onClick } from "../src/ui/rows.ts"
import { settle } from "./support.ts"

/** Two surfaces that say which one they are and nothing else. */
function table(onClick?: () => void): SurfaceRegistry<JSX.Element> {
  const registry = createSurfaceRegistry<JSX.Element>()
  for (const id of ["left", "right"]) {
    registry.register({
      id,
      title: id,
      owner: host_owner,
      claimsKeyboard: false,
      render: () => (
        <box flexGrow={1} flexDirection="column">
          <text onMouseDown={onClick}>surface {id}</text>
        </box>
      ),
    })
  }
  return registry
}

const width = 40
const height = 6

function mount(node: () => JSX.Element) {
  return testRender(node, { width, height })
}

test("a single pane paints exactly what the surface paints, with no host between them", async () => {
  const registry = table()
  const body = () => registry.get("left")!.render({ pane: "only", focused: true })

  const direct = await mount(body)
  const through = await mount(() => <PaneHost tree={singlePane("left", "only")} registry={registry} />)
  try {
    // Frame for frame. A wrapper box the old `<Switch>` did not have would move
    // something here, which is the failure this test exists to catch.
    expect(await settle(through)).toBe(await settle(direct))
  } finally {
    direct.renderer.destroy()
    through.renderer.destroy()
  }
})

test("a split draws both surfaces at once", async () => {
  const registry = table()
  const tree = splitPane(singlePane("left", "one"), "one", {
    direction: "row",
    surface: "right",
    id: "two",
    splitId: "s",
  })
  const setup = await mount(() => <PaneHost tree={tree} registry={registry} />)
  try {
    const frame = await settle(setup)
    expect(frame).toContain("surface left")
    expect(frame).toContain("surface right")
  } finally {
    setup.renderer.destroy()
  }
})

test("a click focuses the pane it landed in, and the row under it still acts on it", async () => {
  const registry_clicks: string[] = []
  const registry = table(() => registry_clicks.push("surface"))
  const [tree, setTree] = createSignal<PaneTree>(
    splitPane(singlePane("left", "one"), "one", { direction: "row", surface: "right", id: "two", splitId: "s" }),
  )
  const setup = await mount(() => (
    <PaneHost tree={tree()} registry={registry} onFocusPane={(pane) => setTree((now) => ({ ...now, focus: pane }))} />
  ))
  try {
    await settle(setup)
    expect(tree().focus).toBe("two")

    // The left half of a 40-column screen is the pane drawn there.
    await setup.mockMouse.click(2, 0)
    await settle(setup)
    expect(tree().focus).toBe("one")

    // …and the click reached the surface as well. Focusing a pane happens on
    // the way down and must never swallow what a person actually clicked
    // (`ui/rows.ts` owns what a click IS).
    expect(registry_clicks.length).toBeGreaterThan(0)

    await setup.mockMouse.click(width - 2, 0)
    await settle(setup)
    expect(tree().focus).toBe("two")
  } finally {
    setup.renderer.destroy()
  }
})

test("a row action that claims the click still lets the pane under it take the keyboard", async () => {
  // `onClick(action, true)` — the `/ext` checkbox — claims the RELEASE, not
  // the press: a pane focuses itself on the way DOWN, so stopping
  // propagation there too would leave a box ticked in an unfocused pane with
  // the keyboard left behind.
  const ticks: string[] = []
  const registry = createSurfaceRegistry<JSX.Element>()
  for (const id of ["left", "right"]) {
    registry.register({
      id,
      title: id,
      owner: host_owner,
      claimsKeyboard: false,
      render: () => (
        <box flexGrow={1} flexDirection="column">
          <text {...onClick(() => ticks.push(id), true)}>[x] {id}</text>
        </box>
      ),
    })
  }
  const [tree, setTree] = createSignal<PaneTree>(
    splitPane(singlePane("left", "one"), "one", { direction: "row", surface: "right", id: "two", splitId: "s" }),
  )
  const setup = await mount(() => (
    <PaneHost tree={tree()} registry={registry} onFocusPane={(pane) => setTree((now) => ({ ...now, focus: pane }))} />
  ))
  try {
    await settle(setup)
    expect(tree().focus).toBe("two")
    await setup.mockMouse.click(2, 0)
    await settle(setup)
    // The box was ticked AND the keyboard came with the click.
    expect(ticks).toEqual(["left"])
    expect(tree().focus).toBe("one")
  } finally {
    setup.renderer.destroy()
  }
})

test("a pane pointing at a surface nobody registered draws nothing rather than failing", async () => {
  // The shape a package that failed to load takes. An empty pane the keyboard
  // still works around is the honest version of that bug.
  const setup = await mount(() => <PaneHost tree={singlePane("host:gone", "only")} registry={table()} />)
  try {
    expect((await settle(setup)).trim()).toBe("")
  } finally {
    setup.renderer.destroy()
  }
})
