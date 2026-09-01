/**
 * The declaration layer of goals/tui-plugin.md U2, against the real binary:
 * `contributes.commands` reaching the slash chain, `contributes.policy`
 * reaching the gate's read-only ceiling. `ui.render`/`ui.panel` are pure and
 * tested where `describeTool` lives (`test/registry.test.ts`); the merge
 * rules for commands are pure and tested in `test/packageCommands.test.ts`;
 * this file is what only a real session and a real build can show — that the
 * declared things actually run.
 *
 * Two fixture packages, built once for the whole file:
 *
 *  - `plugin` (a script extension, DESIGN §7.1) declares one tool
 *    (`echo`) and one skill (`note`), and three commands — one for each verb
 *    (`with` / `run <tool>` / `skill <ref>`). `activation: "on_request"` is
 *    the realistic shape for a package like this: registering it (building +
 *    activating) makes its commands discoverable without putting it in front
 *    of every session on the machine (DESIGN §7.2.1) — `/with-plugin` is the
 *    per-session decision.
 *  - `guard` contributes NOTHING but a policy narrowing (`{"readonly": true}`)
 *    — no tools, no runtime needed at all (`Manifest.validate`'s
 *    `MissingRuntime` only fires when `tools.len != 0`) — so it is the
 *    smallest possible proof that D3's ceiling reads a MEMBER's policy, not
 *    only an agent's frontmatter.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { testRender } from "@opentui/solid"
import { App } from "../src/ui/App.tsx"
import { createStyle, type Style } from "../src/render/theme.ts"
import { createSessionState } from "../src/state/session.ts"
import { extBuild, extSetCurrent, sessionEvents, sessionList, sessionNew } from "../src/nulya/cli.ts"
import type { LedgerEvent, ToolResultEntry } from "../src/nulya/ledger.ts"
import { unsafe_settings, scripted_env, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

let ws: TempWorkspace
/** The fixture's interpreter follows `ext init --script`'s own platform rule
 * (`cli/ext.zig`: `windows ? "powershell" : "sh"`), so the suite runs wherever
 * the kernel's generated scripts would. */
const win = process.platform === "win32"
/** The workspace-store version `plugin` built to — named once, used by several tests. */
let plugin_version: string
let guard_version: string

const style: Style = createStyle(unsafe_settings, {})

function extensionDir(id: string): string {
  return join(ws.dir, ".nulya", "extensions", id)
}

beforeAll(async () => {
  ws = tempWorkspace()

  // --- `plugin`: commands (all three verbs) + a tool + a skill ------------
  const plugin_dir = extensionDir("plugin")
  mkdirSync(join(plugin_dir, "src"), { recursive: true })
  mkdirSync(join(plugin_dir, "skills", "note"), { recursive: true })
  writeFileSync(
    join(plugin_dir, "extension.json"),
    JSON.stringify({
      schema: "nulya.extension/v2",
      id: "plugin",
      runtime: win
        ? { entry: "src/main.ps1", interpreter: "powershell" }
        : { entry: "src/main.sh", interpreter: "sh" },
      contributes: {
        tools: [
          {
            name: "echo",
            description: "echo back the `text` argument, for a `run <tool>` command to prove it actually ran",
            input: { type: "object", properties: { text: { type: "string" } } },
          },
        ],
        skills: ["skills/note"],
        commands: [
          { name: "with-plugin", description: "wear the plugin package for the next session", action: { with: true } },
          { name: "echo-run", description: "run the echo tool directly", action: { run: "echo" } },
          { name: "plugin-note", description: "load the note skill", action: { skill: "note" } },
        ],
      },
    }),
  )
  // Echoes back the `text` argument — the minimal deterministic proof that
  // `ext run` actually invoked this process. The wire is the whole story: the
  // argument arrives as NULYA_ARG_text, and whatever the script prints IS the
  // result (`templates.zig`'s own `scriptPs1` / `scriptSh` are the precedents
  // for a real script extension in this test suite).
  if (win)
    writeFileSync(
      join(plugin_dir, "src", "main.ps1"),
      [
        "$ErrorActionPreference = 'Stop'",
        "$in = [Console]::In.ReadToEnd()",
        "[Console]::Out.Write(\"echoed: $env:NULYA_ARG_text\")",
        "",
      ].join("\n"),
    )
  else
    writeFileSync(
      join(plugin_dir, "src", "main.sh"),
      [
        "#!/bin/sh",
        "cat >/dev/null",
        "printf 'echoed: %s' \"$NULYA_ARG_text\"",
        "",
      ].join("\n"),
    )
  writeFileSync(
    join(plugin_dir, "skills", "note", "SKILL.md"),
    "---\nname: note\ndescription: a note the plugin package offers\n---\nRemember: the plugin package is active.\n",
  )
  // A local build into an EMPTY workspace store auto-trusts it (DESIGN §9) —
  // the same precedent `pins.test.ts`'s `notes` fixture and `extensions.test.ts`
  // rely on, so there is no separate `ext trust` call here.
  plugin_version = await extBuild(ws, ".nulya/extensions/plugin")
  // `current` has to be set for BOTH readers this file exercises: the command
  // harvester only offers an ACTIVATED package's commands (`extensions.packageCommands`,
  // D8), and `nulya skill list` is the ACTIVE catalog across store roots.
  await extSetCurrent(ws, "activate", "plugin", plugin_version)

  // --- `guard`: nothing but a policy narrowing -----------------------------
  const guard_dir = extensionDir("guard")
  mkdirSync(guard_dir, { recursive: true })
  writeFileSync(
    join(guard_dir, "extension.json"),
    JSON.stringify({
      schema: "nulya.extension/v2",
      id: "guard",
      contributes: { policy: { readonly: true } },
    }),
  )
  guard_version = await extBuild(ws, ".nulya/extensions/guard")
})

afterAll(() => {
  ws.cleanup()
})

/**
 * The three verbs a package's `contributes.commands` can declare, each landing
 * on the path a person typing the general form by hand would already reach
 * (goals/tui-plugin.md U2 bullet 1): `with` is `startDraft`'s own `--with`
 * move, `run <tool>` is `ext run` naming the version this package is active
 * AT, `skill <ref>` is T15's `skillTurn` with the declared ref standing in for
 * whatever the person typed.
 */
test("with, run and skill each land on the path a person typing the general form would reach", async () => {
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        pick={{ profile: "scripted" }}
        style={style}
        driver={{ env: scripted_env }}
        statePath={join(ws.dir, "tui-state-plugin-commands.json")}
      />
    ),
    { width: 100, height: 30 },
  )
  try {
    await settle(setup, 4)

    // `with`: a draft's `--with` — visible on the Welcome card's `with` row
    // before any session exists, exactly like the general `/with plugin` would
    // be (`test/views.test.tsx`'s "wearing a package" test is the precedent).
    await setup.mockInput.typeText("/with-plugin")
    setup.mockInput.pressEnter()
    let frame = await settle(setup, 4)
    expect(frame).toContain("with        plugin")

    // The first message materializes the session, wearing it.
    await setup.mockInput.typeText("hello")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("scripted"), 30_000)
    const id = await until_session_id()
    // The scripted `finish` provider's run is one `shell` call and then a final
    // reply; wait for that reply (not only the tool result) before dispatching
    // anything else — a command sent while the driver is still mid-step would
    // otherwise ride the ordinary mid-task framing (`state/driver.ts`), which
    // is correct behaviour but not what THIS test is isolating.
    await until(() => setup.captureCharFrame().includes("● done"), 60_000)

    // `run <tool>`: an actual `ext run plugin@<version> echo` — the notice
    // carries the tool's own reply back, proving the process really ran.
    await setup.mockInput.typeText("/echo-run hello from the command")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("hello from the command"), 60_000)
    frame = setup.captureCharFrame()
    expect(frame).toContain("plugin echo")

    // `skill <ref>`: the declared ref ("note") stands in for the name — this
    // is `skillTurn`'s own path, so the transcript folds it back exactly the
    // way typing `/note` would (`skills.ts` `echoSummary`).
    await setup.mockInput.typeText("/plugin-note")
    setup.mockInput.pressEnter()
    const isSkillEcho = (event: LedgerEvent): event is Extract<LedgerEvent, { kind: "user_text" }> =>
      event.kind === "user_text" && (event as Extract<LedgerEvent, { kind: "user_text" }>).text.includes("<user-skill ")
    await until(async () => (await sessionEvents(ws, id)).some(isSkillEcho), 60_000)
    const events = await sessionEvents(ws, id)
    const echoed = events.find(isSkillEcho)!
    expect(echoed.text).toContain('name="note"')
    expect(echoed.text).toContain("Remember: the plugin package is active.")
    await settle(setup, 4)
    expect(setup.captureCharFrame()).toContain("/note")
  } finally {
    setup.renderer.destroy()
  }
}, 180_000)

/** The id of the one session this file's workspace has grown so far — the only public seam once a draft has materialized. */
async function until_session_id(): Promise<string> {
  let id: string | null = null
  await until(async () => {
    const listed = await sessionList(ws)
    id = listed[0]?.id ?? null
    return id !== null
  }, 30_000)
  return id!
}

/**
 * A built-in name is never taken from a person — even by a package that ships
 * with this repository's own binary. `commands.ts`'s table is checked first
 * (`ui/App.tsx` `runCommand`), so a package declaring `/model` would never be
 * reached; this exercises the same guarantee for a fixture package's OWN
 * completion listing, at the pure level (`resolve`) plus the one place it
 * would actually matter: dispatch never sees it.
 */
test("a package cannot take a built-in name away, even by declaring it", async () => {
  const shadow_dir = extensionDir("shadow")
  mkdirSync(shadow_dir, { recursive: true })
  writeFileSync(
    join(shadow_dir, "extension.json"),
    JSON.stringify({
      schema: "nulya.extension/v2",
      id: "shadow",
      contributes: { commands: [{ name: "model", description: "a package pretending to be /model", action: { with: true } }] },
    }),
  )
  const version = await extBuild(ws, ".nulya/extensions/shadow")
  await extSetCurrent(ws, "activate", "shadow", version)

  const setup = await testRender(
    () => (
      <App
        ws={ws}
        pick={{ profile: "scripted" }}
        style={style}
        driver={{ env: scripted_env }}
        statePath={join(ws.dir, "tui-state-plugin-shadow.json")}
      />
    ),
    { width: 100, height: 30 },
  )
  try {
    await settle(setup, 4)
    // `/model` opens the model picker — the built-in behaviour — never
    // `shadow`'s `with` action (which would instead have opened a draft card
    // saying `with        shadow`).
    await setup.mockInput.typeText("/model")
    setup.mockInput.pressEnter()
    const frame = await settle(setup, 4)
    expect(frame).not.toContain("with        shadow")
    // The model overlay itself opened — the built-in's real effect, not just
    // the absence of the package's.
    expect(frame).toContain("model · what ")
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)

/**
 * `contributes.policy.readonly: true` on a composition MEMBER is the same
 * ceiling a `readonly: true` agent gets (D3), judged before every approval
 * table — `unsafe` mode would ordinarily wave a `shell` call straight through,
 * so denying it here is proof the ceiling fired, not the ordinary tables.
 */
test("a member package's readonly policy denies shell before any table, and names itself in the note", async () => {
  const id = await sessionNew(ws, { profile: "scripted", with: [`guard@${guard_version}`] })
  const state = createSessionState(id)
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        id={id}
        state={state}
        style={style}
        driver={{ env: scripted_env }}
        statePath={join(ws.dir, `tui-state-${id}.json`)}
        created
      />
    ),
    { width: 100, height: 24 },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("probe")
    setup.mockInput.pressEnter()
    await until(async () => (await sessionEvents(ws, id)).some((event) => event.kind === "tool_results"), 60_000)
    const batches = (await sessionEvents(ws, id)).filter(
      (event): event is Extract<LedgerEvent, { kind: "tool_results" }> => event.kind === "tool_results",
    )
    const denied: ToolResultEntry[] = batches.flatMap((event) => event.results)
    expect(denied).not.toHaveLength(0)
    expect(denied.every((result) => result.ok === false)).toBe(true)
    // The same judgment as the agent ceiling (`agents.ts` `readonlyCeiling`),
    // with a note that names WHICH package's policy fired — a package's
    // policy is not an agent, and the model reading the deny should not be
    // told it is one.
    expect(denied.some((result) => result.output.includes("read-only policy of guard"))).toBe(true)
    expect(denied.some((result) => result.output.includes("cannot run shell"))).toBe(true)
  } finally {
    setup.renderer.destroy()
  }
}, 120_000)
