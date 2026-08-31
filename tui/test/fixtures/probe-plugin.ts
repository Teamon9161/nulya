/**
 * The fixture plugin (tui-plugin U3's completion criteria).
 *
 * It lives HERE, under `test/`, rather than as a string inside the test file,
 * for one reason worth the copy step: `tsconfig.json` includes `test`, so
 * `bunx tsc --noEmit` checks this module against `plugin-api.d.ts` on every
 * run. A contract nothing is written against is a contract nobody has read —
 * and the type-only import below is also the proof that the specifier never
 * has to resolve where a plugin is actually installed, because Bun erases it.
 *
 * The test copies this file into a package draft (`tui/probe.ts`), builds the
 * package, and lets the host load the frozen copy. So what runs is exactly
 * what a real package would ship: a file inside a content-addressed version,
 * imported by absolute path.
 *
 * Everything it does is observable from outside, which is what makes it a
 * fixture rather than a demo: counts of what it observed and how many keys it
 * took are printed in its widget and its panel, so a test asserts on the
 * screen instead of on a private variable.
 */
import type { CardView, Line, PluginApi, PluginKey } from "nulya-tui/plugin-api"

export function activate(api: PluginApi): void {
  let streams = 0
  let events = 0
  let cursor = 0
  let eventSource = "none"

  api.observe.onStream(() => {
    streams += 1
  })
  api.observe.onEvent((_event, _session, source) => {
    events += 1
    eventSource = source
  })

  // Two rows: the head (always on screen) and a body that folds under it.
  api.registerWidget({
    render: (width: number): Line[] => [
      [
        { text: "probe", token: "accent.evolve" },
        { text: ` · streams ${streams} · events ${events} · source ${eventSource}`, token: "dim" },
      ],
      [{ text: `width ${width} · session ${api.observe.session()?.id ?? "none"}`, token: "muted" }],
    ],
  })

  api.registerUserTurn({
    id: "probe-turn",
    match: (text) => text.startsWith("<probe>"),
    head: () => "probe context",
    defaultOpen: () => true,
    render: (view) => [[{ text: view.text.slice("<probe>".length).trim(), token: "fg" }]],
    sessionTitle: (text) => `probe · ${text.slice("<probe>".length).trim()}`,
  })

  // The package's OWN tool, which is the only kind it may draw (D11).
  api.registerCard("note", {
    render: (view: CardView): Line[] => [
      [
        { text: "probe card", token: "accent.tool" },
        { text: ` · ${view.state}`, token: "dim" },
      ],
      [{ text: view.args.slice(0, 60), token: "fg" }],
    ],
  })

  const panel = api.registerPanel({
    render: (): Line[] => [
      [{ text: "probe panel", token: "fg" }],
      [{ text: `cursor ${cursor} · j moves`, token: "dim" }],
    ],
    onKey: (key: PluginKey): boolean => {
      if (key.name === "j") {
        cursor += 1
        return true
      }
      // Everything else — `escape` included — is left to the host, which is
      // what guarantees a person can always leave a plugin's panel.
      return false
    },
    onClose: () => {
      cursor = 0
    },
  })

  api.registerCommand({
    name: "probe-panel",
    description: "open the probe panel",
    run: () => panel.open(),
  })

  api.registerCommand({
    name: "probe-note",
    description: "append what the probe found",
    run: async (ctx) => {
      await api.actions.appendNote("finding", ctx.args.length > 0 ? ctx.args : "nothing in particular")
    },
  })

  api.registerCommand({
    name: "probe-cross",
    description: "run an internal tool through the generic package action",
    run: async () => {
      const result = await api.actions.extRunPackage("probe", "inside", {})
      api.notice(`cross-package code ${result.code}`)
    },
  })

  api.registerCommand({
    name: "probe-cross-refuse",
    description: "prove a model-facing tool is refused by the cross-package action",
    run: async () => {
      try {
        await api.actions.extRunPackage("probe", "note", {})
      } catch (error) {
        api.notice(error instanceof Error ? error.message : String(error))
      }
    },
  })

  api.registerCommand({
    name: "probe-cross-missing",
    description: "prove an id without current is refused",
    run: async () => {
      try {
        await api.actions.extRunPackage("missing-package", "inside", {})
      } catch (error) {
        api.notice(error instanceof Error ? error.message : String(error))
      }
    },
  })

  api.registerCommand({
    name: "probe-remember",
    description: "count how often this was run, across runs",
    run: () => {
      const seen = (api.state.get<number>("seen") ?? 0) + 1
      api.state.set("seen", seen)
      api.notice(`probe has been asked ${seen} time${seen === 1 ? "" : "s"}`)
    },
  })

  // A built-in name is never taken from a person (D8): the host refuses this
  // and says so, and the rest of the activation stands.
  api.registerCommand({ name: "model", description: "should never be reachable", run: () => {} })
}
