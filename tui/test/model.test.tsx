/**
 * `/model`: the picker over `nulya config show --json`,
 * the launch plan, and the one file the TUI writes (`tui-state.json`).
 *
 * This screen is models and nothing else — keys, endpoints and the
 * add-provider form are `/provider` and are tested in `provider.test.tsx`,
 * including the handoff between the two.
 *
 * The picker is rendered against a hand-built ConfigView so its frames are
 * about layout and keys, and against the real binary once so the shape the
 * kernel actually prints is the shape the picker reads.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { createSignal, type JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { configShow, type ConfigView, type ProfileView } from "../src/nulya/cli.ts"
import {
  AUTO,
  ModelView,
  initialSlot,
  labelOf,
  modelParamsFor,
  modelRows,
  pickableRows,
  rungAnchor,
  rungLanding,
  rungValue,
  rungsOn,
  pickerRows,
  providerDetail,
  teamOf,
  teamSummary,
} from "../src/ui/overlays/ModelView.tsx"
import { blockedReason } from "../src/ui/overlays/providers.ts"
import { displayWidth } from "../src/ui/columns.ts"
import { planLaunch } from "../src/launch.ts"
import { loadTuiState, rememberModel, saveTuiState } from "../src/state/tui_state.ts"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { createSessionState, runningModel } from "../src/state/session.ts"
import { sessionExists } from "../src/nulya/files.ts"
import { CliError, sessionList, sessionNew } from "../src/nulya/cli.ts"
import { App } from "../src/ui/App.tsx"
import type { ModelPick } from "../src/state/tui_state.ts"
import {
  unsafe_settings,
  fake_config,
  scripted_env,
  settle,
  statusLine,
  tempWorkspace,
  until,
  type TempWorkspace,
} from "./support.ts"

const style: Style = createStyle(unsafe_settings, {})

const fake = fake_config

let ws: TempWorkspace
beforeAll(() => {
  ws = tempWorkspace()
})
afterAll(() => ws.cleanup())

test("pickerRows: one row per (profile, model) in config order, dial = auto + the catalog levels", () => {
  const rows = pickerRows(fake)
  expect(rows.map((row) => `${row.profile.name}/${row.model}`)).toEqual([
    "openai/gpt-5.6-sol",
    "openai/gpt-5.6-luna",
    "deepseek/deepseek-v4-flash",
    "deepseek/deepseek-v4-pro",
    "codex/gpt-5.5",
    "scripted/scripted-demo",
  ])
  // A described id carries its dial; an undescribed one is bare, dial = auto only.
  expect(rows[0]!.slots).toEqual([AUTO, "low", "medium", "high"])
  expect(rows[1]!.params).toBeNull()
  expect(rows[1]!.slots).toEqual([AUTO])
  expect(rows[5]!.slots).toEqual([AUTO])

  // Where the dial starts: catalog default for a row that is not the current
  // pick, the profile's effort over the catalog's, the live effort for the
  // current pick, and auto when nothing says otherwise.
  expect(rows[0]!.slots[initialSlot(rows[0]!, null)]).toBe("medium")
  expect(rows[4]!.slots[initialSlot(rows[4]!, null)]).toBe("low")
  expect(rows[2]!.slots[initialSlot(rows[2]!, null)]).toBe(AUTO)
  const current: ModelPick = { profile: "deepseek", model: "deepseek-v4-flash", effort: "max" }
  expect(rows[2]!.slots[initialSlot(rows[2]!, current)]).toBe("max")
  expect(rows[3]!.slots[initialSlot(rows[3]!, current)]).toBe(AUTO)

  // The bare fact, without the remedy: which key fixes it depends on which
  // screen is showing it, so `blockedReason` does not pretend to know.
  expect(blockedReason(fake.profiles[0]!)).toBe("no key")
  expect(blockedReason(fake.profiles[2]!)).toBe("run `codex login`")
  expect(blockedReason(fake.profiles[1]!)).toBe("")
})

test("a profile's own catalog beats the global one: the same id is a different model behind a subscription", () => {
  // codex serves `gpt-5.6-sol` off a ChatGPT subscription: 258k of context and
  // an `xhigh` rung the public API does not have. The global `[[models]]` entry
  // for that very id says 1.05M and stops at `high`. Both are true — of
  // different endpoints — so the row takes its own endpoint's word.
  const config: ConfigView = {
    ...fake,
    profiles: [
      {
        ...fake.profiles[2]!,
        models: ["gpt-5.6-sol"],
        effort: null,
        catalog: [
          {
            id: "gpt-5.6-sol",
            label: "GPT-5.6 Sol",
            efforts: ["low", "medium", "high", "xhigh"],
            default_effort: "high",
            context_window: 258_400,
            vision: false,
          },
        ],
      },
      fake.profiles[0]!,
    ],
  }
  const [codex] = modelRows(config, config.profiles[0]!)
  expect(codex!.params?.context_window).toBe(258_400)
  expect(codex!.slots).toEqual([AUTO, "low", "medium", "high", "xhigh"])
  expect(codex!.slots[initialSlot(codex!, null)]).toBe("high")

  // Another profile serving the same id has no catalog of its own, so it still
  // reads the global entry: one id, two honest answers.
  const [api] = modelRows(config, config.profiles[1]!)
  expect(api!.params?.context_window).toBe(1_050_000)
  expect(api!.slots).toEqual([AUTO, "low", "medium", "high"])
  expect(api!.slots[initialSlot(api!, null)]).toBe("medium")
  // The label is the same in both, which is exactly why the parameters have to
  // be right: nothing else on the row would give the difference away.
  expect(labelOf(codex!)).toBe(labelOf(api!))
})

test("modelParamsFor: the one lookup the picker and the status bar gauge both call (docs/BUGS.md #8)", () => {
  const codexWithCatalog = {
    ...fake.profiles[2]!,
    catalog: [
      {
        id: "gpt-5.6-sol",
        label: "GPT-5.6 Sol",
        efforts: ["low", "medium", "high", "xhigh"],
        default_effort: "high",
        context_window: 258_400,
        vision: false,
      },
    ],
  }
  // A profile with its own entry for this id: that entry wins over the global
  // list even though the global list also names it (with a different window).
  expect(modelParamsFor(fake.models, codexWithCatalog, "gpt-5.6-sol")?.context_window).toBe(258_400)
  // No entry in the profile's own catalog for this id: falls back to the
  // global `[[models]]` list.
  const globalFlash = fake.models.find((m) => m.id === "deepseek-v4-flash")!
  expect(modelParamsFor(fake.models, codexWithCatalog, "deepseek-v4-flash")).toEqual(globalFlash)
  // A profile with no catalog of its own at all: same fallback.
  expect(modelParamsFor(fake.models, fake.profiles[1]!, "deepseek-v4-flash")).toEqual(globalFlash)
  // Named nowhere, by either: null, not a guess.
  expect(modelParamsFor(fake.models, codexWithCatalog, "no-such-model")).toBeNull()
})

test("a provider's team is said on its detail line; no team says nothing at all", () => {
  const staffed: ProfileView = {
    ...fake.profiles[1]!,
    roles: [
      { name: "explore", model: "deepseek-v4-pro", effort: null },
      { name: "review", model: "openai/gpt-5.6-sol", effort: "high" },
    ],
  }
  // Every rung, what it resolves to, and the effort when the rung pins one:
  // picking this provider's model picks these with it.
  expect(teamOf(staffed)).toHaveLength(2)
  expect(teamOf(staffed)[0]).toContain("explore")
  expect(teamOf(staffed)[0]).toContain("deepseek-v4-pro")
  expect(teamOf(staffed)[1]).toContain("openai/gpt-5.6-sol")
  expect(teamOf(staffed)[1]).toContain("high")
  const detail = providerDetail(staffed)
  for (const rung of teamOf(staffed)) expect(detail).toContain(rung)
  // …and with no rungs the line is exactly the provider facts it always was:
  // an empty team is not an announcement.
  expect(providerDetail({ ...staffed, roles: [] })).toBe(providerDetail(fake.profiles[1]!))
  expect(teamSummary(fake.profiles[1]!)).toBe("")
  // A profile from a binary that never heard of the field, and a profile name
  // nothing answers to (the notice looks its profile up by name): both empty,
  // neither a crash.
  const older = { ...fake.profiles[1]!, roles: undefined } as unknown as ProfileView
  expect(teamOf(older)).toEqual([])
  expect(teamSummary(undefined)).toBe("")
})

test("a fleet can cross providers: the rung says where it lands, and the row it lands on says so", () => {
  // The case this whole feature exists for: the main model on one endpoint,
  // one of its rungs on another.
  const fleet: ProfileView = {
    ...fake.profiles[0]!,
    roles: [
      { name: "explore", model: "deepseek/deepseek-v4-flash", effort: "low" },
      { name: "review", model: "gpt-5.6-luna", effort: null },
    ],
  }
  expect(rungLanding("openai", "deepseek/deepseek-v4-flash")).toEqual({
    profile: "deepseek",
    model: "deepseek-v4-flash",
  })
  // No slash is one of the owner's own models — and a slash at either end is
  // not a pair, so it stays one id rather than becoming a profile called "".
  expect(rungLanding("openai", "gpt-5.6-luna")).toEqual({ profile: "openai", model: "gpt-5.6-luna" })
  expect(rungLanding("openai", "/x").profile).toBe("openai")

  const rows = pickerRows({ ...fake, profiles: [fleet, fake.profiles[1]!] })
  const at = (profile: string, model: string) => rows.find((r) => r.profile.name === profile && r.model === model)!
  // The rung is written on openai and drawn under deepseek, because that is
  // where the model it names actually is.
  expect(rungsOn(fleet, at("deepseek", "deepseek-v4-flash"))).toContain("@explore")
  expect(rungsOn(fleet, at("openai", "gpt-5.6-luna"))).toContain("@review")
  expect(rungsOn(fleet, at("deepseek", "deepseek-v4-pro"))).toBe("")
  // Nothing in force, and a binary that never heard of the field: both empty,
  // neither a crash.
  expect(rungsOn(undefined, at("openai", "gpt-5.6-luna"))).toBe("")
  expect(rungsOn({ ...fleet, roles: undefined } as unknown as ProfileView, at("openai", "gpt-5.6-luna"))).toBe("")
})

test("a rung is written to the profile in force, and says the provider when the model is elsewhere", () => {
  const rows = pickerRows(fake)
  const luna = rows.find((row) => row.model === "gpt-5.6-luna")!
  const flash = rows.find((row) => row.model === "deepseek-v4-flash")!
  // The cursor moving over another provider's row does not move the team: it
  // is still the team of the model this conversation runs on.
  expect(rungAnchor({ profile: "openai", model: "gpt-5.6-sol" }, flash)).toBe("openai")
  expect(rungValue("openai", luna)).toBe("gpt-5.6-luna")
  expect(rungValue("openai", flash)).toBe("deepseek/deepseek-v4-flash")
  // Nothing in force yet: the row's own provider, since picking it is what
  // would put it in force.
  expect(rungAnchor(null, flash)).toBe("deepseek")
  expect(rungAnchor(null, null)).toBe("")
})

test("the team summary is one line: spelled out while it is short, counted once it is not", () => {
  const staffing = (count: number): ProfileView => ({
    ...fake.profiles[1]!,
    roles: Array.from({ length: count }, (_, at) => ({ name: `rung${at}`, model: "deepseek-v4-pro", effort: null })),
  })
  expect(teamSummary(staffing(2))).toContain("rung1")
  const crowded = teamSummary(staffing(9))
  expect(crowded).toContain("9")
  expect(crowded).not.toContain("rung0")
})

test("pickableRows: only the providers that can run — plus the one in force, whatever its state", () => {
  // openai and codex have no credential: not a model row between them. The
  // offline stand-in can always run and is still not offered — nobody chooses
  // it on purpose.
  expect(pickableRows(fake, null).map((row) => `${row.profile.name}/${row.model}`)).toEqual([
    "deepseek/deepseek-v4-flash",
    "deepseek/deepseek-v4-pro",
  ])
  // The pick in force stays on screen even after its key went away, so the
  // `current` mark has a row to sit on (Enter there says why it cannot run).
  expect(
    pickableRows(fake, { profile: "openai", model: "gpt-5.6-sol" }).map((row) => `${row.profile.name}/${row.model}`),
  ).toEqual(["openai/gpt-5.6-sol", "openai/gpt-5.6-luna", "deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-pro"])
  // Landed on the stand-in because nothing else could run: it must be visible,
  // or the screen would say nothing about where this session actually is.
  expect(
    pickableRows(fake, { profile: "scripted", model: "scripted-demo" }).map((row) => row.profile.name),
  ).toContain("scripted")
})

async function pickerFrame(node: () => JSX.Element, width = 120, height = 30) {
  return testRender(() => <StyleContext.Provider value={style}>{node()}</StyleContext.Provider>, { width, height })
}

test("modelRows: a profile's ids become its rows, and a bare profile still offers its default", () => {
  expect(modelRows(fake, fake.profiles[1]!).map((row) => row.model)).toEqual([
    "deepseek-v4-flash",
    "deepseek-v4-pro",
  ])
  // A profile that lists no `models[]` still offers the one it defaults to.
  const bare = { ...fake.profiles[1]!, models: [] }
  expect(modelRows(fake, bare).map((row) => row.model)).toEqual(["deepseek-v4-flash"])
})

test("/model is models and only models: grouped under their provider, nothing about keys", async () => {
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={{ profile: "deepseek", model: "deepseek-v4-flash", effort: undefined }}
      onPick={() => {}}
      onNotice={() => {}}
      onOpenProviders={() => {}}
      onClose={() => {}}
      load={async () => fake}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("DeepSeek V4 Pro"), 10_000)
    const frame = await settle(setup, 4)
    expect(frame).toContain("model · what the next session runs on")
    // The models of the providers that can run, each group under a heading that
    // names its provider once — and NOT the models of the ones that
    // cannot: no key, no row, no heading.
    const rows = frame.split("\n").map((line) => line.replace(/\s+$/, ""))
    const group = rows.findIndex((line) => line.trim() === "deepseek")
    expect(group).toBeGreaterThan(0)
    expect(rows[group + 1]).toContain("DeepSeek V4 Flash")
    expect(rows[group + 2]).toContain("DeepSeek V4 Pro")
    // The provider is said once, not repeated down the left edge of its models.
    expect(rows[group + 1]).not.toContain("deepseek  ")
    expect(frame).toContain("deepseek-v4-pro")
    expect(frame).toContain("1M ctx")
    expect(frame).toContain("✓ current")
    expect(frame).not.toContain("GPT-5.6 Sol")
    expect(frame).not.toContain("gpt-5.5")
    // The offline stand-in is not on this list: this session is not on it.
    expect(frame).not.toContain("scripted")
    // No providers row, and none of the provider keys are advertised here.
    // Credentials are a command of their own, not the tail of this list.
    expect(frame).not.toContain("providers ·")
    expect(frame).not.toContain("s paste a key")
    expect(frame).not.toContain("no key")
    expect(frame).toContain("Enter starts a session")
    // The cursor opened on the pick in force, and its endpoint is the detail line.
    expect(frame).toContain("deepseek · openai wire · https://api.deepseek.com · DEEPSEEK_API_KEY set")
    expect(frame).toMatchSnapshot()
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("landed on the stand-in, the screen says so: its own group, and the heading carries what it is", async () => {
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={{ profile: "scripted", model: "scripted-demo", effort: undefined }}
      onPick={() => {}}
      onNotice={() => {}}
      onOpenProviders={() => {}}
      onClose={() => {}}
      load={async () => fake}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("scripted-demo"), 10_000)
    // Being a stand-in is a fact about the provider, so it sits on the heading
    // rather than on each of its models.
    expect(setup.captureCharFrame()).toContain("scripted · offline stand-in")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("with no provider able to run, the list is one line pointing at /provider, and Enter goes there", async () => {
  const stranded: ConfigView = {
    ...fake,
    profiles: fake.profiles.filter((p) => p.kind !== "scripted").map((p) => ({ ...p, credential: false })),
  }
  const [asked, setAsked] = createSignal(0)
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={null}
      onPick={() => {}}
      onNotice={() => {}}
      onOpenProviders={() => setAsked(asked() + 1)}
      onClose={() => {}}
      load={async () => stranded}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("no provider can run yet"), 10_000)
    const frame = await settle(setup, 3)
    expect(frame).toContain("no provider can run yet · /provider to paste a key or add an endpoint")
    expect(frame).toContain("Enter · p opens /provider")
    // Both keys lead to the one screen that can change this.
    setup.mockInput.pressEnter()
    await until(() => asked() === 1, 10_000)
    setup.mockInput.pressKey("p")
    await until(() => asked() === 2, 10_000)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("the model table is cut to its columns at 76: one row each, a gutter that survives, nothing wraps", async () => {
  const notice = "openai has no API key · this session is the offline stand-in · pick a model that can run"
  const setup = await pickerFrame(
    () => (
      <ModelView
        ws={ws}
        current={null}
        notice={notice}
        onPick={() => {}}
        onNotice={() => {}}
        onOpenProviders={() => {}}
        onClose={() => {}}
        load={async () => fake}
      />
    ),
    76,
    30,
  )
  try {
    await until(() => setup.captureCharFrame().includes("DeepSeek V4 Pro"), 10_000)
    const frame = await settle(setup, 4)
    const lines = frame.split("\n").map((line) => line.replace(/\s+$/, ""))
    for (const line of lines) expect(displayWidth(line)).toBeLessThanOrEqual(76)

    // A model row is complete when its dial is on it; the two deepseek rows
    // each have theirs, and nothing wrapped a cell to a second line.
    expect(lines.filter((line) => /‹ \w+ ›|no dial/.test(line)).length).toBe(2)
    // The notice is broken at its joints, by us, one `<text>` per line.
    expect(frame).toContain("openai has no API key · this session is the offline stand-in")
    expect(frame).toContain("pick a model that can run")
    expect(frame).toMatchSnapshot()
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("the models level: ←→ turns the dial, Enter picks the row it is on", async () => {
  const [picked, setPicked] = createSignal<ModelPick | null>(null)
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={{ profile: "deepseek", model: "deepseek-v4-flash", effort: undefined }}
      onPick={setPicked}
      onNotice={() => {}}
      onOpenProviders={() => {}}
      onClose={() => {}}
      load={async () => fake}
    />
  ))
  try {
    // The cursor opens on the model in force.
    await until(() => setup.captureCharFrame().includes("DeepSeek V4 Pro"), 10_000)
    await settle(setup, 3)
    expect(setup.captureCharFrame()).toMatch(/▾ DeepSeek V4 Flash/)

    // → twice turns flash's dial auto → off → low; ↓ then Enter picks pro on
    // ITS dial (auto).
    setup.mockInput.pressArrow("right")
    setup.mockInput.pressArrow("right")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).toContain("‹ low ›")
    setup.mockInput.pressArrow("down")
    await settle(setup, 2)
    setup.mockInput.pressEnter()
    await until(() => picked() !== null, 10_000)
    expect(picked()).toEqual({ profile: "deepseek", model: "deepseek-v4-pro", effort: undefined })

    // Back up onto flash (dial still on low) — the pick carries the effort.
    setup.mockInput.pressArrow("up")
    await settle(setup, 2)
    setup.mockInput.pressEnter()
    await until(() => picked()?.effort === "low", 10_000)
    expect(picked()).toEqual({ profile: "deepseek", model: "deepseek-v4-flash", effort: "low" })

    // Down past the last row stops there: this list has no tail row any more.
    for (let i = 0; i < 10; i++) setup.mockInput.pressKey("j")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).toMatch(/▾ DeepSeek V4 Pro/)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("s asks who, not what to call it: the personas are the list, and picking one staffs the fleet in force", async () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-rung-"))
  const path = join(dir, "config.toml")
  const notices: string[] = []
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={{ profile: "openai", model: "gpt-5.6-sol", effort: undefined }}
      onPick={() => {}}
      onNotice={(message) => notices.push(message)}
      onOpenProviders={() => {}}
      onClose={() => {}}
      load={async () => ({ ...fake, paths: { ...fake.paths, user: path } })}
      rungs={async () => [
        { name: "explore", riders: ["explore", "scout"] },
        { name: "review", riders: ["review"] },
      ]}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("DeepSeek V4 Flash"), 10_000)
    // Down onto a DeepSeek row while this conversation runs on openai: the
    // combination this feature exists for.
    while (!setup.captureCharFrame().match(/▾ DeepSeek V4 Flash/)) {
      setup.mockInput.pressKey("j")
      await settle(setup, 2)
    }
    setup.mockInput.pressKey("s")
    await until(() => setup.captureCharFrame().includes("who runs on"), 10_000)
    const asking = await settle(setup, 2)
    // Nobody is asked to remember a rung name: the personas are on screen, and
    // a rung several of them ride says who rides it.
    expect(asking).toContain("explore")
    expect(asking).toContain("scout")
    expect(asking).toContain("review")
    // The models are not what the keys mean now, so they are not on screen.
    expect(asking).not.toContain("gpt-5.6-terra")

    setup.mockInput.pressEnter()
    await until(() => notices.length > 0, 10_000)
    const written = readFileSync(path, "utf8")
    expect(written).toContain(`name = "openai"`)
    // Written on the profile in force, naming the other provider — the main
    // model on one endpoint, this rung on another.
    expect(written).toContain(`explore = { model = "deepseek/deepseek-v4-flash" }`)
    expect(notices[0]).toContain("deepseek/deepseek-v4-flash")
    // And the question is down, with the models back.
    await until(() => setup.captureCharFrame().includes("GPT-5.6 Sol"), 10_000)
  } finally {
    setup.renderer.destroy()
    rmSync(dir, { recursive: true, force: true })
  }
}, 60_000)

test("with no persona asking for a model, s says so and writes nothing", async () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-rung-"))
  const path = join(dir, "config.toml")
  const notices: string[] = []
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={{ profile: "deepseek", model: "deepseek-v4-flash", effort: undefined }}
      onPick={() => {}}
      onNotice={(message) => notices.push(message)}
      onOpenProviders={() => {}}
      onClose={() => {}}
      load={async () => ({ ...fake, paths: { ...fake.paths, user: path } })}
      rungs={async () => []}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("DeepSeek V4 Flash"), 10_000)
    setup.mockInput.pressKey("s")
    await until(() => notices.length > 0, 10_000)
    // Nothing to choose from is not an empty list to stare at: it is one
    // sentence naming the screen that explains what would fill it.
    expect(notices[0]).toContain("/agent")
    expect(existsSync(path)).toBe(false)
    // …and the list is still the list, still listening.
    setup.mockInput.pressKey("j")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).toMatch(/▾ DeepSeek V4 Pro/)
  } finally {
    setup.renderer.destroy()
    rmSync(dir, { recursive: true, force: true })
  }
}, 60_000)

test("the question takes the list keys, and cancelling gives them back", async () => {
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={{ profile: "deepseek", model: "deepseek-v4-flash", effort: undefined }}
      onPick={() => {}}
      onNotice={() => {}}
      onOpenProviders={() => {}}
      onClose={() => {}}
      load={async () => fake}
      rungs={async () => [{ name: "explore", riders: ["explore"] }]}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("DeepSeek V4 Flash"), 10_000)
    await settle(setup, 3)
    expect(setup.captureCharFrame()).toMatch(/\u25be DeepSeek V4 Flash/)

    // With the question up, `j` moves the answer and not the models under it.
    setup.mockInput.pressKey("s")
    await until(() => setup.captureCharFrame().includes("who runs on"), 10_000)
    setup.mockInput.pressKey("j")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).not.toMatch(/DeepSeek V4 Pro/)

    // Escape ends the question and nothing else — the list is still there and
    // still listening, which `j` moving again is the whole proof of.
    setup.mockInput.pressEscape()
    await settle(setup, 2)
    setup.mockInput.pressKey("j")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).not.toMatch(/\u25be DeepSeek V4 Flash/)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("focusProfile: /provider hands a provider over and the cursor lands on its first model", async () => {
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      current={{ profile: "scripted", model: "scripted-demo", effort: undefined }}
      focusProfile="deepseek"
      onPick={() => {}}
      onNotice={() => {}}
      onOpenProviders={() => {}}
      onClose={() => {}}
      load={async () => fake}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("DeepSeek V4 Pro"), 10_000)
    const frame = await settle(setup, 3)
    // Not on the pick in force (scripted) — on the handed-over provider's first
    // model, which is what "choose a provider, then its model" has to mean.
    expect(frame).toMatch(/▾ DeepSeek V4 Flash/)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("Enter on a row whose provider lost its key says why, and points at the screen that fixes it", async () => {
  const [notice, setNotice] = createSignal<string | null>(null)
  const setup = await pickerFrame(() => (
    <ModelView
      ws={ws}
      // The pick in force is openai, which has no key: its rows are on screen
      // so the `current` mark has somewhere to sit, but Enter must not start.
      current={{ profile: "openai", model: "gpt-5.6-sol", effort: undefined }}
      onPick={() => setNotice("STARTED")}
      onNotice={setNotice}
      onOpenProviders={() => {}}
      onClose={() => {}}
      load={async () => fake}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("GPT-5.6 Sol"), 10_000)
    await settle(setup, 3)
    setup.mockInput.pressEnter()
    await until(() => notice() !== null, 10_000)
    expect(notice()).toBe("openai cannot run · no key · /provider to paste a key")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("configShow reads the real binary: scripted is always runnable, the catalog rides along", async () => {
  const config = await configShow(ws)
  expect(config.active_profile.length).toBeGreaterThan(0)
  const scripted = config.profiles.find((p) => p.name === "scripted")
  expect(scripted?.credential).toBe(true)
  const deepseek = config.profiles.find((p) => p.name === "deepseek")
  expect(deepseek?.api_key_env).toBe("DEEPSEEK_API_KEY")
  expect(deepseek?.models).toEqual(["deepseek-v4-flash", "deepseek-v4-pro"])
  const flash = config.models.find((m) => m.id === "deepseek-v4-flash")
  expect(flash?.efforts).toEqual(["off", "low", "high", "max"])
  // A profile that does not describe its own endpoint says so with null — and
  // a binary that has never heard of the field reads back the same way.
  expect(deepseek?.catalog ?? null).toBeNull()
  // The team is always a list to walk, whether this binary projects roles or
  // has never heard of them: `/model` maps over it without asking which.
  for (const p of config.profiles) expect(Array.isArray(p.roles)).toBe(true)
  for (const p of config.profiles) {
    if (p.catalog === null) continue
    expect(Array.isArray(p.catalog)).toBe(true)
    for (const entry of p.catalog) expect(typeof entry.id).toBe("string")
  }
  // Every id a profile lists is described — by its own catalog, or by the
  // global one; the picker never shows a bare id for a built-in profile.
  for (const p of config.profiles) {
    if (p.kind === "scripted") continue
    const own = new Set((p.catalog ?? []).map((m) => m.id))
    for (const id of p.models) expect(own.has(id) || config.models.some((m) => m.id === id)).toBe(true)
  }
  // Never a secret: only env var NAMES.
  const text = JSON.stringify(config)
  expect(text).not.toContain("api_key\"")
})

test("planLaunch: flags > last pick > active profile, and nothing runnable means offline + the way to fix it", () => {
  // Explicit and runnable.
  expect(planLaunch({ profile: "deepseek", model: "deepseek-v4-pro" }, undefined, fake)).toEqual({
    pick: { profile: "deepseek", model: "deepseek-v4-pro", effort: undefined },
  })
  // Explicit but not runnable: refused with the reason, never substituted.
  expect(planLaunch({ profile: "openai" }, undefined, fake).refuse).toContain("openai has no API key")
  expect(planLaunch({ profile: "openai" }, undefined, fake).refuse).toContain("/provider")
  expect(planLaunch({ profile: "nope" }, undefined, fake).refuse).toContain("no profile named 'nope'")
  // The last pick, whole; a flag overrides one field of it.
  const last: ModelPick = { profile: "deepseek", model: "deepseek-v4-flash", effort: "high" }
  expect(planLaunch({}, last, fake)).toEqual({ pick: last })
  expect(planLaunch({ effort: "off" }, last, fake).pick?.effort).toBe("off")
  // The last pick lost its key → not the active profile either (no key) →
  // offline + a guide. Something else CAN run (deepseek), so the screen offered
  // is the one that lists it.
  const gone = planLaunch({}, { profile: "openai" }, fake)
  expect(gone.pick).toEqual({ profile: "scripted" })
  expect(gone.guide).toContain("openai has no API key")
  expect(gone.guide).toContain("offline stand-in")
  expect(gone.guideOn).toBe("model")
  // No memory, active profile has no key: same, blaming the active profile.
  expect(planLaunch({}, undefined, fake).guide).toContain("openai has no API key")
  // But with no real provider working at all, a list of models has nothing to
  // offer: the first screen is the one that takes a key.
  const stranded: ConfigView = {
    ...fake,
    profiles: fake.profiles.map((p) => (p.kind === "scripted" ? p : { ...p, credential: false })),
  }
  const nothing = planLaunch({}, undefined, stranded)
  expect(nothing.guideOn).toBe("provider")
  expect(nothing.guide).toContain("paste a key, or add a compatible endpoint")
  // Active profile runnable: used.
  const ready = { ...fake, active_profile: "deepseek" }
  expect(planLaunch({}, undefined, ready)).toEqual({ pick: { profile: "deepseek", model: undefined, effort: undefined } })
})

test("tui-state remembers the last pick, tolerates absence and garbage, and is only ever whole", () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-tui-state-"))
  const path = join(dir, "nested", "tui-state.json")
  try {
    expect(loadTuiState(path)).toEqual({})
    rememberModel({ profile: "deepseek", model: "deepseek-v4-flash", effort: "high" }, path)
    expect(loadTuiState(path)).toEqual({ model: { profile: "deepseek", model: "deepseek-v4-flash", effort: "high" } })
    // Dropping the effort drops the key, not the pick.
    rememberModel({ profile: "deepseek", model: "deepseek-v4-flash" }, path)
    expect(loadTuiState(path)).toEqual({ model: { profile: "deepseek", model: "deepseek-v4-flash" } })
    // A broken file is "nothing remembered", and a save afterwards heals it.
    require("node:fs").writeFileSync(path, "{not json")
    expect(loadTuiState(path)).toEqual({})
    saveTuiState({ model: { profile: "codex" } }, path)
    expect(loadTuiState(path)).toEqual({ model: { profile: "codex" } })
    // A pick without a profile is no pick.
    require("node:fs").writeFileSync(path, JSON.stringify({ model: { model: "x" } }))
    expect(loadTuiState(path)).toEqual({})
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("picking in /model writes the draft, not a session", async () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-tui-state-"))
  const statePath = join(dir, "tui-state.json")
  const before = (await sessionList(ws)).length
  // The draft opens on the stand-in, which is what `launch.ts` hands over on a
  // machine with no key at all — and the pick in force always has a row, so
  // there is one here to press Enter on whatever this machine's environment has.
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        style={style}
        driver={{ env: scripted_env }}
        statePath={statePath}
        pick={{ profile: "scripted", model: "scripted-demo" }}
      />
    ),
    { width: 120, height: 24 },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("/model")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("model · what "), 15_000)
    for (let i = 0; i < 40; i++) setup.mockInput.pressKey("j")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).toMatch(/▾ scripted-demo/)
    setup.mockInput.pressEnter()
    // Enter on a draft spawns no process and writes no file: it says what the
    // first message will start, and the pick is remembered.
    await until(() => setup.captureCharFrame().includes("starts when you send a message"), 15_000)
    expect(loadTuiState(statePath).model).toEqual({ profile: "scripted", model: "scripted-demo", effort: undefined })
    expect((await sessionList(ws)).length).toBe(before)
  } finally {
    setup.renderer.destroy()
    rmSync(dir, { recursive: true, force: true })
  }
}, 120_000)

test("/effort sets this tab's effort: the header shows it and the next step is spawned with --effort", async () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-tui-state-"))
  const statePath = join(dir, "tui-state.json")
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} created statePath={statePath} />,
    { width: 120, height: 24 },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("/effort high")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("effort high"), 10_000)
    // The effort rides with the model, as tcode writes it: `id (effort)` — on
    // the bottom line, once the notice that answered `/effort` has come down
    // off it on its own.
    await until(() => statusLine(setup).includes("scripted-demo (high)"), 15_000)
    expect(loadTuiState(statePath).model?.effort).toBe("high")
    // The scripted provider ignores effort, but the flag must not break the
    // step: the run still completes.
    await setup.mockInput.typeText("probe")
    setup.mockInput.pressEnter()
    await until(() => state.snapshot.lastStopped !== null, 60_000)
    expect(state.snapshot.error).toBeNull()
    await setup.mockInput.typeText("/effort auto")
    setup.mockInput.pressEnter()
    await until(() => statusLine(setup).includes("scripted-demo") && !statusLine(setup).includes("(high)"), 15_000)
  } finally {
    setup.renderer.destroy()
    rmSync(dir, { recursive: true, force: true })
  }
}, 120_000)

test("a guide opens the picker first, with the reason on screen and the composer out of the way", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        id={id}
        state={state}
        style={style}
        driver={{ env: scripted_env }}
        created
        guide="openai has no API key · this session is the offline stand-in"
      />
    ),
    { width: 120, height: 24 },
  )
  try {
    // The guide's own reason is the signal that the picker is up: the title
    // depends on whether this tab has a session (it does — Enter would fork
    // it), and that is not what this test is about.
    await until(() => setup.captureCharFrame().includes("openai has no API key"), 15_000)
    const frame = await settle(setup, 3)
    expect(frame).toContain("scripted-demo")
    // j moves the picker; nothing is typed into the composer.
    setup.mockInput.pressKey("j")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).not.toMatch(/›\s*j\s*$/m)
    // Esc leaves the picker; the session underneath is the offline one.
    setup.mockInput.pressEscape()
    await settle(setup, 3)
    expect(setup.captureCharFrame()).toContain("scripted")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("a guide can open on /provider instead, when there is no model anywhere to list", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  const state = createSessionState(id)
  const setup = await testRender(
    () => (
      <App
        ws={ws}
        id={id}
        state={state}
        style={style}
        driver={{ env: scripted_env }}
        created
        guide="openai has no API key · this session is the offline stand-in · paste a key, or add a compatible endpoint"
        guideOn="provider"
      />
    ),
    { width: 120, height: 24 },
  )
  try {
    await until(() => setup.captureCharFrame().includes("providers · keys and endpoints"), 15_000)
    const frame = await settle(setup, 3)
    expect(frame).toContain("openai has no API key")
    expect(frame).toContain("s paste a key")
    setup.mockInput.pressEscape()
    await settle(setup, 3)
    expect(setup.captureCharFrame()).not.toContain("providers · keys and endpoints")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

// --- /model on a session that already exists: a carry fork ----------
//
// A session's model is frozen for its whole file, so changing what a
// conversation runs on means continuing it in a NEW file that carries the
// history (`session new --parent <id>:<seq> --carry`). What is tested here is
// the front end's half — that Enter on a live tab forks and goes there instead
// of opening a draft, that the kernel's own sentences reach the screen, and
// that the chips read the model that is actually answering.

/**
 * A session frozen on a real provider, so there is somewhere to fork FROM.
 * `deepseek` needs a key at creation and at every step's handle construction —
 * never on the wire, because nothing here talks to it: the fork lands on the
 * offline stand-in, and that is what any step runs.
 */
async function deepseekSession(): Promise<{ id: string; restore: () => void }> {
  const had = process.env["DEEPSEEK_API_KEY"]
  process.env["DEEPSEEK_API_KEY"] = "test-key-not-used-on-any-wire"
  const id = await sessionNew(ws, { profile: "deepseek" })
  return {
    id,
    restore: () => {
      if (had === undefined) delete process.env["DEEPSEEK_API_KEY"]
      else process.env["DEEPSEEK_API_KEY"] = had
    },
  }
}

test("what a session runs on is its header's model, for the whole file", () => {
  const state = createSessionState("s-1")
  state.setHeader({
    kind: "header",
    v: 1,
    session: "s-1",
    parent: null,
    model: "deepseek",
    model_identity: { provider: "openai", model: "deepseek-v4-pro", base_url: "", api_key_env: "" },
    environment: "",
    remote_workspace: "",
    created: "",
    composition: { active: [], native_tools: [], prompts: [] },
  })
  expect(runningModel(state.snapshot)).toEqual({ profile: "deepseek", model: "deepseek-v4-pro" })
})

test("a carry fork gives the child the parent's turns on another model, and leaves the parent alone", async () => {
  const { id, restore } = await deepseekSession()
  try {
    const child = await sessionNew(ws, {
      parent: { session: id, seq: 0 },
      carry: true,
      profile: "scripted",
    })
    expect(child).not.toBe(id)
    expect(sessionExists(ws, id)).toBe(true)
    const rows = await sessionList(ws)
    expect(rows.find((row) => row.id === child)?.model).toBe("scripted")
    // The parent is still on what its own header froze.
    expect(rows.find((row) => row.id === id)?.model).toBe("deepseek")
  } finally {
    restore()
  }
}, 60_000)

test("a carry the kernel refuses throws with its whole sentence, and nothing is created", async () => {
  const { id, restore } = await deepseekSession()
  const before = (await sessionList(ws)).length
  try {
    // A cut point past the parent's last event: the kernel refuses rather than
    // guessing how much history there is.
    const failed = await sessionNew(ws, { parent: { session: id, seq: 99 }, carry: true, profile: "scripted" }).then(
      () => null,
      (error: unknown) => error,
    )
    expect(failed).toBeInstanceOf(CliError)
    expect((failed as CliError).detail).toContain(id)
    expect((await sessionList(ws)).length).toBe(before)
  } finally {
    restore()
  }
}, 60_000)

test("/model on a started session continues it in a new one, and the chips follow", async () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-tui-state-"))
  const statePath = join(dir, "tui-state.json")
  const { id, restore } = await deepseekSession()
  const state = createSessionState(id)
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} created statePath={statePath} />,
    { width: 120, height: 24 },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("/model")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("model · what this conversation runs on"), 15_000)
    // Down to the last row: another model on the provider this session already
    // runs on, so the fork needs nothing this machine does not have.
    for (let i = 0; i < 40; i++) setup.mockInput.pressKey("j")
    await settle(setup, 2)
    setup.mockInput.pressEnter()

    // Another session, forked from this one, and the tab in front is on it:
    // the bottom line names what is answering now.
    await until(
      async () => (await sessionList(ws)).some((row) => row.id !== id && row.parent?.session === id),
      20_000,
    )
    await until(() => statusLine(setup).includes("deepseek-v4-pro"), 20_000)
  } finally {
    setup.renderer.destroy()
    restore()
    rmSync(dir, { recursive: true, force: true })
  }
}, 120_000)

test("a refused pick is shown as the kernel wrote it, and no session is created", async () => {
  const { id, restore } = await deepseekSession()
  const state = createSessionState(id)
  const before = (await sessionList(ws)).length
  const setup = await testRender(
    () => <App ws={ws} id={id} state={state} style={style} driver={{ env: scripted_env }} created />,
    { width: 120, height: 24 },
  )
  try {
    await settle(setup, 3)
    await setup.mockInput.typeText("/model")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("model · what this conversation runs on"), 15_000)
    // The picker read the config once, on mount, with the key in place. Taking
    // it away now is exactly the case this front end must not try to answer for
    // itself: the row still looks runnable here, and the kernel is the one that
    // knows it is not.
    restore()
    delete process.env["DEEPSEEK_API_KEY"]
    for (let i = 0; i < 40; i++) setup.mockInput.pressKey("k")
    await settle(setup, 2)
    setup.mockInput.pressEnter()

    // The kernel's sentence, not one of ours: the assertion is taken from what
    // the CLI itself says, so a reworded refusal moves both halves together.
    const refusal = await sessionNew(ws, { parent: { session: id, seq: 0 }, carry: true, profile: "deepseek" }).then(
      () => "",
      (error: unknown) => (error instanceof CliError ? error.detail : String(error)),
    )
    const longest = refusal.split(/[\s'`]+/).reduce((a: string, b: string) => (b.length > a.length ? b : a), "")
    await until(() => setup.captureCharFrame().includes(longest), 20_000)
    expect((await sessionList(ws)).length).toBe(before)
  } finally {
    setup.renderer.destroy()
    restore()
  }
}, 120_000)
