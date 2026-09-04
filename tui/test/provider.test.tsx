/**
 * `/provider`: the endpoints, their keys, the add form — and
 * the handoff to `/model`, which is the whole point of splitting the two.
 *
 * The pair is exercised through a two-screen harness rather than through `App`:
 * what has to hold is the contract between them (`onShowModels` → a `/model`
 * mounted with `focusProfile`), and a fake `ConfigView` lets a key be "saved"
 * and the list reloaded without a real config file. `App` wiring itself is one
 * assertion in `model.test.tsx` (`guideOn="provider"` opens this screen).
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { Match, Switch, createSignal, type JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { configShow, sessionNew, type ConfigView } from "../src/nulya/cli.ts"
import { ModelView } from "../src/ui/overlays/ModelView.tsx"
import { ProviderView, endpointOf } from "../src/ui/overlays/ProviderView.tsx"
import { blockedReason, keyable, modelIdsOf } from "../src/ui/overlays/providers.ts"
import { displayWidth } from "../src/ui/columns.ts"
import { StyleContext, createStyle, type Style } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import type { ProfileDraft } from "../src/nulya/credentials.ts"
import { fake_config, settle, tempWorkspace, until, type TempWorkspace } from "./support.ts"

const style: Style = createStyle(default_settings, {})
const fake = fake_config

let ws: TempWorkspace
beforeAll(() => {
  ws = tempWorkspace()
})
afterAll(() => ws.cleanup())

async function frameOf(node: () => JSX.Element, width = 120, height = 30) {
  return testRender(() => <StyleContext.Provider value={style}>{node()}</StyleContext.Provider>, { width, height })
}

/** A rejected field keeps its text so it can be fixed; this is "fix it all". */
function erase(setup: { mockInput: { pressBackspace: () => void } }, count: number) {
  for (let i = 0; i < count; i++) setup.mockInput.pressBackspace()
}

/**
 * The two screens, wired the way `App` wires them: `/provider` hands a chosen
 * provider to `/model`, which opens on that provider's first model, and
 * `/model` with nothing to offer sends the person back.
 */
function Screens(props: {
  load: () => Promise<ConfigView>
  writeKey?: (path: string, profile: string, key: string) => void
  writeProfileBlock?: (path: string, draft: ProfileDraft) => void
  onNotice?: (message: string) => void
}) {
  const [where, setWhere] = createSignal<"provider" | "model">("provider")
  const [focus, setFocus] = createSignal<string | undefined>(undefined)
  return (
    <Switch>
      <Match when={where() === "provider"}>
        <ProviderView
          ws={ws}
          current={null}
          load={props.load}
          writeKey={props.writeKey}
          writeProfileBlock={props.writeProfileBlock}
          onShowModels={(profile) => {
            setFocus(profile)
            setWhere("model")
          }}
          onNotice={(message) => props.onNotice?.(message)}
          onClose={() => {}}
        />
      </Match>
      <Match when={where() === "model"}>
        <ModelView
          ws={ws}
          current={null}
          focusProfile={focus()}
          load={props.load}
          onPick={() => {}}
          onNotice={(message) => props.onNotice?.(message)}
          onOpenProviders={() => setWhere("provider")}
          onClose={() => {}}
        />
      </Match>
    </Switch>
  )
}

test("the facts both screens share have one answer each", () => {
  expect(modelIdsOf(fake.profiles[1]!)).toEqual(["deepseek-v4-flash", "deepseek-v4-pro"])
  // A profile that lists no `models[]` still offers the one it defaults to.
  expect(modelIdsOf({ ...fake.profiles[1]!, models: [] })).toEqual(["deepseek-v4-flash"])
  expect(keyable(fake.profiles[0]!)).toBe(true)
  expect(keyable(fake.profiles[2]!)).toBe(false) // codex signs in
  expect(keyable(fake.profiles[3]!)).toBe(false) // the offline stand-in
  expect(blockedReason(fake.profiles[0]!)).toBe("no key")
  expect(blockedReason(fake.profiles[3]!)).toBe("")

  expect(endpointOf(fake.profiles[0]!)).toBe("openai wire · api.openai.com")
  expect(endpointOf(fake.profiles[2]!)).toBe("codex · ChatGPT subscription")
  expect(endpointOf(fake.profiles[3]!)).toBe("offline · no network")
})

test("/provider lists every endpoint, runnable or not, with what each one is and what it needs", async () => {
  const setup = await frameOf(() => (
    <ProviderView
      ws={ws}
      current={{ profile: "deepseek", model: "deepseek-v4-flash", effort: undefined }}
      onShowModels={() => {}}
      onNotice={() => {}}
      onClose={() => {}}
      load={async () => fake}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("api.openai.com"), 10_000)
    const frame = await settle(setup, 4)
    expect(frame).toContain("providers · keys and endpoints")
    expect(frame).toContain("2 models")
    expect(frame).toContain("openai wire · api.openai.com")
    // Models are the other screen's business: not one label of them here.
    expect(frame).not.toContain("DeepSeek V4 Flash")
    // The remedy IS on this screen, so it is named on the row.
    expect(frame).toContain("no key · s to paste one")
    expect(frame).toContain("run `codex login`")
    expect(frame).toContain("✓ current")
    expect(frame).toContain("offline stand-in")
    expect(frame).toContain("+ add an OpenAI- or Anthropic-compatible provider")
    // It opened on the provider in force, whose detail line lists its model ids
    // (they are not rows here): browsing is not gated, only starting is.
    expect(frame).toContain("deepseek · openai wire · https://api.deepseek.com · DEEPSEEK_API_KEY set")
    expect(frame).toContain("models deepseek-v4-flash, deepseek-v4-pro")
    expect(frame).toMatchSnapshot()
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("the provider table is cut to its columns at 76: one row each, a gutter that survives, nothing wraps", async () => {
  // `deepseek-anthropic` is exactly the 18 columns the name column used to be
  // fixed at, so it is the row that used to run straight into the endpoint
  // beside it ("deepseek-anthropicanthropic wire · api.").
  const crowded: ConfigView = {
    ...fake,
    profiles: [
      ...fake.profiles,
      {
        name: "deepseek-anthropic",
        kind: "anthropic",
        base_url: "https://api.deepseek.com/anthropic",
        api_key_env: "DEEPSEEK_API_KEY",
        credential: false,
        credential_source: "none",
        model: "deepseek-v4-flash",
        models: ["deepseek-v4-flash"],
        effort: null,
        catalog: null,
        roles: [],
      },
    ],
  }
  const notice = "openai has no API key · this session is the offline stand-in · paste a key, or add a compatible endpoint"
  const setup = await frameOf(
    () => (
      <ProviderView
        ws={ws}
        current={null}
        notice={notice}
        onShowModels={() => {}}
        onNotice={() => {}}
        onClose={() => {}}
        load={async () => crowded}
      />
    ),
    76,
    30,
  )
  try {
    await until(() => setup.captureCharFrame().includes("deepseek-anthropic"), 10_000)
    const frame = await settle(setup, 4)
    const lines = frame.split("\n").map((line) => line.replace(/\s+$/, ""))
    for (const line of lines) expect(displayWidth(line)).toBeLessThanOrEqual(76)

    // One line per profile, each carrying its whole row: a cell that overflowed
    // its column would take a second line and leave the count alone, so the
    // rows are counted by the chip that only a complete row has.
    const rows = lines.filter((line) => /\d model(s)? /.test(line))
    expect(rows.length).toBe(crowded.profiles.length)
    for (const row of rows) expect(row).toMatch(/(no key · s|codex login|stand-in|ready)/)

    // The gutter is not negotiable, and what does not fit is cut with `…`
    // rather than wrapped into the row below.
    expect(frame).toContain("deepseek-anthropic  anthropic wire")
    expect(frame).toContain("…")
    expect(frame).not.toContain("deepseek-anthropicanthropic")

    // The notice is broken at its joints, by us, one `<text>` per line.
    expect(frame).toContain("openai has no API key · this session is the offline stand-in")
    expect(frame).toContain("paste a key, or add a compatible endpoint")
    expect(frame).toMatchSnapshot()
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("Enter on a ready provider goes to /model landed on its first model; on a keyless one, to its key", async () => {
  const [notice, setNotice] = createSignal<string | null>(null)
  const setup = await frameOf(() => <Screens load={async () => fake} onNotice={setNotice} />)
  try {
    // The cursor opens on the first provider that can actually run.
    await until(() => setup.captureCharFrame().includes("no key · s to paste one"), 10_000)
    await settle(setup, 3)
    expect(setup.captureCharFrame()).toMatch(/▾ deepseek /)

    // A provider without a key is still browsable — its model ids are in the
    // detail line — and Enter on it goes to the one thing that would let it
    // run: its key. Esc leaves that alone.
    setup.mockInput.pressKey("k")
    await settle(setup, 2)
    expect(setup.captureCharFrame()).toContain("models gpt-5.6-sol, gpt-5.6-luna")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("API key for openai"), 10_000)
    setup.mockInput.pressEscape()
    await until(() => !setup.captureCharFrame().includes("API key for openai"), 10_000)
    expect(setup.captureCharFrame()).toContain("providers · keys and endpoints")

    // codex has a login, not a key: Enter says so and stays put.
    setup.mockInput.pressKey("j")
    setup.mockInput.pressKey("j")
    await settle(setup, 2)
    setup.mockInput.pressEnter()
    await until(() => (notice() ?? "").includes("codex login"), 10_000)
    expect(setup.captureCharFrame()).toContain("providers · keys and endpoints")

    // And Enter on a ready one is the handoff: the other screen, on that
    // provider's first model. This is the two-step the split exists for.
    setup.mockInput.pressKey("k")
    await settle(setup, 2)
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("model · what "), 10_000)
    const frame = await settle(setup, 3)
    expect(frame).toMatch(/▾ DeepSeek V4 Flash/)
    // And it is a models screen: no keys, no endpoints, no way back by accident.
    expect(frame).not.toContain("s paste a key")
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("s pastes a key where the key belongs, and the models screen gains that provider's rows", async () => {
  const written: Array<[string, string, string]> = []
  let keyed = false
  const load = async (): Promise<ConfigView> => ({
    ...fake,
    profiles: fake.profiles.map((p) =>
      p.name === "openai" && keyed ? { ...p, credential: true, credential_source: "config" as const } : p,
    ),
  })
  const [notice, setNotice] = createSignal<string | null>(null)
  const setup = await frameOf(() => (
    <Screens
      load={load}
      onNotice={setNotice}
      writeKey={(path, profile, key) => {
        written.push([path, profile, key])
        keyed = true
      }}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("no key · s to paste one"), 10_000)
    setup.mockInput.pressKey("k")
    await settle(setup, 2)
    setup.mockInput.pressKey("s")
    await until(() => setup.captureCharFrame().includes("API key for openai"), 10_000)
    expect(setup.captureCharFrame()).toContain("Enter save to /home/me/.nulya/config.toml")
    // j must NOT move the list while the input has the keyboard.
    await setup.mockInput.typeText("sk-pasted-j")
    setup.mockInput.pressEnter()
    await until(() => written.length === 1, 10_000)
    expect(written[0]).toEqual(["/home/me/.nulya/config.toml", "openai", "sk-pasted-j"])
    await until(() => setup.captureCharFrame().includes("ready · key in config"), 10_000)
    expect(notice()).toContain("api_key for openai saved to /home/me/.nulya/config.toml")

    // Esc backs out of a second entry without writing.
    setup.mockInput.pressKey("s")
    await until(() => setup.captureCharFrame().includes("API key for openai"), 10_000)
    setup.mockInput.pressEscape()
    await until(() => !setup.captureCharFrame().includes("API key for openai"), 10_000)
    expect(written.length).toBe(1)

    // The point of pasting it: the provider now has models, and Enter shows them.
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("GPT-5.6 Sol"), 10_000)
    const frame = await settle(setup, 3)
    // Grouped under their provider the heading names it once, and
    // the models it just gained are the rows under it.
    const rows = frame.split("\n").map((line) => line.replace(/\s+$/, ""))
    const group = rows.findIndex((line) => line.trim() === "openai")
    expect(group).toBeGreaterThan(0)
    expect(rows[group + 1]).toMatch(/▾ GPT-5\.6 Sol/)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("`a` walks the compatible-provider form and writes one profile", async () => {
  const written: ProfileDraft[] = []
  const [notice, setNotice] = createSignal<string | null>(null)
  const setup = await frameOf(() => (
    <ProviderView
      ws={ws}
      current={null}
      onShowModels={() => {}}
      onNotice={setNotice}
      onClose={() => {}}
      load={async () => fake}
      writeProfileBlock={(_path, draft) => {
        written.push(draft)
      }}
    />
  ))
  try {
    await until(() => setup.captureCharFrame().includes("api.openai.com"), 10_000)
    setup.mockInput.pressKey("a")
    await until(() => setup.captureCharFrame().includes("profile name"), 10_000)

    // A name that already exists is refused where it is typed, not on save —
    // and the text stays put so it can be corrected rather than retyped.
    await setup.mockInput.typeText("deepseek")
    setup.mockInput.pressEnter()
    await until(() => (notice() ?? "").includes("already exists"), 10_000)
    expect(setup.captureCharFrame()).toContain("profile name")
    erase(setup, "deepseek".length)

    await setup.mockInput.typeText("openrouter")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("Chat Completions"), 10_000)
    expect(setup.captureCharFrame()).toContain("anthropic · Messages")
    setup.mockInput.pressKey("j")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("base URL"), 10_000)

    // Nothing typed into a step leaks into the next one, and a URL is checked.
    await setup.mockInput.typeText("openrouter.ai")
    setup.mockInput.pressEnter()
    await until(() => (notice() ?? "").includes("starts with http"), 10_000)
    erase(setup, "openrouter.ai".length)
    await setup.mockInput.typeText("https://openrouter.ai/api/")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("model id(s)"), 10_000)
    await setup.mockInput.typeText("moonshotai/kimi-k3 , qwen/qwen4-max")
    setup.mockInput.pressEnter()
    await until(() => setup.captureCharFrame().includes("API key for openrouter"), 10_000)
    await setup.mockInput.typeText("sk-or-xxx")
    setup.mockInput.pressEnter()
    await until(() => written.length === 1, 10_000)

    expect(written[0]).toEqual({
      name: "openrouter",
      kind: "anthropic",
      // The trailing slash is dropped: the kernel appends the wire's own path.
      base_url: "https://openrouter.ai/api",
      models: ["moonshotai/kimi-k3", "qwen/qwen4-max"],
      key: "sk-or-xxx",
    })
    expect(notice()).toContain("openrouter added to /home/me/.nulya/config.toml")
    // And the screen is back on the list — where the new one's state is read
    // next — not stuck in the form.
    await until(() => setup.captureCharFrame().includes("providers · keys and endpoints"), 10_000)
  } finally {
    setup.renderer.destroy()
  }
}, 60_000)

test("credentials: a pasted key lands as a marked block in the user config, replaced in place next time, the rest untouched", () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-home-"))
  const path = join(dir, "config.toml")
  try {
    const { writeProfileKey, keyBlock } = require("../src/nulya/credentials.ts")
    // A fresh file (directory exists, file does not).
    const first = writeProfileKey(path, "deepseek", "sk-one")
    expect(first).toBe(keyBlock("deepseek", "sk-one"))
    // A human's content stays; our block is appended after a blank line.
    require("node:fs").writeFileSync(path, `# mine\n[provider]\nactive_profile = "deepseek"\n`)
    const appended = writeProfileKey(path, "deepseek", "sk-one")
    expect(appended.startsWith(`# mine\n[provider]\nactive_profile = "deepseek"\n\n# nulya: api_key for profile "deepseek"`)).toBe(true)
    // A second profile is a second block; rotating the first replaces it in place.
    writeProfileKey(path, "openrouter", "sk-or")
    const rotated = writeProfileKey(path, "deepseek", "sk-two")
    expect(rotated).not.toContain("sk-one")
    expect(rotated).toContain('name = "deepseek"\napi_key = "sk-two"')
    expect(rotated).toContain('name = "openrouter"\napi_key = "sk-or"')
    expect(rotated.indexOf("deepseek")).toBeLessThan(rotated.indexOf("openrouter"))
    expect((rotated.match(/\[\[provider\.profiles\]\]/g) ?? []).length).toBe(2)
    // Quotes and backslashes in a key survive TOML.
    const odd = writeProfileKey(path, "openrouter", `a"b${"\\"}c`)
    expect(odd).toContain(`api_key = "a\\"b\\\\c"`)
    expect(() => writeProfileKey(path, "bad name", "k")).toThrow()
    expect(() => writeProfileKey(path, "deepseek", "   ")).toThrow()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("credentials: a rung is its own marked block, so re-pointing one leaves the rest of the team alone", () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-home-"))
  const path = join(dir, "config.toml")
  try {
    const { writeRung } = require("../src/nulya/credentials.ts")
    require("node:fs").writeFileSync(path, `# mine\n[provider]\nactive_profile = "openai"\n`)

    writeRung(path, "openai", "explore", "gpt-5.6-luna")
    const both = writeRung(path, "openai", "review", "gpt-5.6-terra", "high")
    // An absent effort and a chosen one are different instructions, so the key
    // is written only when there is one.
    expect(both).toContain(`"explore" = { model = "gpt-5.6-luna" }`)
    expect(both).toContain(`"review" = { model = "gpt-5.6-terra", effort = "high" }`)

    // Re-pointing one rung replaces that block and nothing else — not the other
    // rung, and not what the person wrote.
    const moved = writeRung(path, "openai", "explore", "gpt-5.6-sol", "low")
    expect(moved).not.toContain("gpt-5.6-luna")
    expect(moved).toContain(`"explore" = { model = "gpt-5.6-sol", effort = "low" }`)
    expect(moved).toContain(`"review" = { model = "gpt-5.6-terra", effort = "high" }`)
    expect(moved).toContain("# mine")

    // A persona name may carry a dot, and a persona that names no model rides a
    // rung called after itself — so the picker can offer `review.fast`, and the
    // quoted key is what keeps it ONE rung instead of a table holding `fast`.
    const dotted = writeRung(path, "openai", "review.fast", "gpt-5.6-terra")
    expect(dotted).toContain(`"review.fast" = { model = "gpt-5.6-terra" }`)

    expect(() => writeRung(path, "openai", "explore", "   ")).toThrow()
    expect(() => writeRung(path, "openai", ".hidden", "m")).toThrow()
    expect(() => writeRung(path, "bad name", "explore", "m")).toThrow()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("credentials: a block owns itself to its end line, so what a person wrote under it survives", () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-home-"))
  const path = join(dir, "config.toml")
  try {
    const { writeRung } = require("../src/nulya/credentials.ts")
    writeRung(path, "openai", "explore", "gpt-5.6-luna")
    // The file is the person's: they may close the gap the block was written
    // with. What follows is still theirs.
    const packed = require("node:fs").readFileSync(path, "utf8").replace(/\n\n+/g, "\n") + `[[models]]\nid = "mine"\n`
    require("node:fs").writeFileSync(path, packed)

    const again = writeRung(path, "openai", "explore", "gpt-5.6-sol")
    expect(again).toContain(`"explore" = { model = "gpt-5.6-sol" }`)
    expect(again).not.toContain("gpt-5.6-luna")
    expect(again).toContain(`[[models]]\nid = "mine"`)

    // A block an older build wrote has no end line, and which of the lines under
    // it were ours is not knowable — so nothing is deleted. The new block is
    // appended and overrides it (roles merge by name, last one wins), and from
    // then on there is a marked block to replace exactly.
    const legacy =
      `# nulya: rung "explore" on profile "openai" (written by the TUI; edit or delete freely)\n` +
      `[[provider.profiles]]\nname = "openai"\n[provider.profiles.roles]\nexplore = { model = "old" }\n` +
      `effort = "high"\n[[models]]\nid = "mine"\n`
    require("node:fs").writeFileSync(path, legacy)
    const migrated = writeRung(path, "openai", "explore", "gpt-5.6-sol")
    expect(migrated.startsWith(legacy)).toBe(true)
    expect(migrated).toContain(`"explore" = { model = "gpt-5.6-sol" }`)

    // And the second write replaces that one rather than piling up a third.
    const settled = writeRung(path, "openai", "explore", "gpt-5.6-terra")
    expect(settled.startsWith(legacy)).toBe(true)
    expect(settled).not.toContain("gpt-5.6-sol")
    expect((settled.match(/# nulya: end/g) ?? []).length).toBe(1)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("credentials: an added profile is one marked block, replaced whole (not by line count) next time", () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-home-"))
  const path = join(dir, "config.toml")
  try {
    const { writeProfile, writeProfileKey } = require("../src/nulya/credentials.ts")
    require("node:fs").writeFileSync(path, `# mine\n[provider]\nactive_profile = "deepseek"\n`)
    const first = writeProfile(path, {
      name: "openrouter",
      kind: "anthropic",
      base_url: "https://openrouter.ai/api",
      models: ["moonshotai/kimi-k3", "qwen/qwen4-max"],
      key: "sk-or",
    })
    expect(first).toContain("# mine")
    expect(first).toContain('kind = "anthropic"')
    expect(first).toContain('base_url = "https://openrouter.ai/api"')
    // The first id is also the profile's default, so `--profile openrouter` runs.
    expect(first).toContain('model = "moonshotai/kimi-k3"')
    expect(first).toContain('models = ["moonshotai/kimi-k3", "qwen/qwen4-max"]')
    expect(first).toContain('api_key = "sk-or"')

    // Something after it stays put, and rewriting with a SHORTER model list
    // replaces the whole block rather than leaving orphaned lines behind.
    writeProfileKey(path, "deepseek", "sk-ds")
    const again = writeProfile(path, {
      name: "openrouter",
      kind: "openai",
      base_url: "https://openrouter.ai/api/v1",
      models: ["moonshotai/kimi-k3"],
    })
    expect(again).toContain('name = "deepseek"\napi_key = "sk-ds"')
    expect(again).not.toContain("qwen/qwen4-max")
    expect(again).not.toContain("anthropic")
    expect(again).not.toContain("sk-or")
    expect((again.match(/\[\[provider\.profiles\]\]/g) ?? []).length).toBe(2)

    expect(() => writeProfile(path, { name: "bad name", kind: "openai", base_url: "https://x", models: ["m"] })).toThrow()
    expect(() => writeProfile(path, { name: "ok", kind: "openai", base_url: "", models: ["m"] })).toThrow()
    expect(() => writeProfile(path, { name: "ok", kind: "openai", base_url: "https://x", models: [] })).toThrow()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("a key pasted in /provider makes the kernel see the profile as ready (real binary, NULYA_HOME)", async () => {
  const home = mkdtempSync(join(tmpdir(), "nulya-home-"))
  const env = { NULYA_HOME: home }
  try {
    const before = await configShow(ws, env)
    expect(before.paths.user).toBe(join(home, "config.toml"))
    const ds = before.profiles.find((p) => p.name === "deepseek")!
    // Only assert the file route: the env var may or may not be set on this machine.
    if (ds.credential_source !== "env") expect(ds.credential).toBe(false)

    const { writeProfileKey } = require("../src/nulya/credentials.ts")
    writeProfileKey(before.paths.user, "deepseek", "sk-test-not-real")
    const after = await configShow(ws, env)
    const ready = after.profiles.find((p) => p.name === "deepseek")!
    expect(ready.credential).toBe(true)
    expect(ready.credential_source).toBe("config")
    // The key itself is not in the projection.
    expect(JSON.stringify(after)).not.toContain("sk-test-not-real")
    // And a session on it freezes the real provider, not scripted.
    const id = await sessionNew(ws, { profile: "deepseek" }, env)
    const header = JSON.parse(require("node:fs").readFileSync(join(ws.dir, ".nulya", "sessions", `${id}.jsonl`), "utf8").split("\n")[0])
    expect(header.model_identity.provider).toBe("openai")
    expect(header.model_identity.model).toBe("deepseek-v4-flash")
    expect(JSON.stringify(header)).not.toContain("sk-test-not-real")
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
}, 30_000)

test("a provider added in /provider is a profile the real kernel resolves (real binary, NULYA_HOME)", async () => {
  const home = mkdtempSync(join(tmpdir(), "nulya-home-"))
  const env = { NULYA_HOME: home }
  try {
    const { writeProfile } = require("../src/nulya/credentials.ts")
    const before = await configShow(ws, env)
    expect(before.profiles.some((p) => p.name === "my-endpoint")).toBe(false)
    writeProfile(before.paths.user, {
      name: "my-endpoint",
      kind: "openai",
      base_url: "https://example.invalid/v1",
      models: ["some-model", "other-model"],
      key: "sk-added-not-real",
    })
    const after = await configShow(ws, env)
    const added = after.profiles.find((p) => p.name === "my-endpoint")!
    expect(added.kind).toBe("openai")
    expect(added.base_url).toBe("https://example.invalid/v1")
    expect(added.models).toEqual(["some-model", "other-model"])
    // It can run: the key is right there in the file the kernel reads.
    expect(added.credential).toBe(true)
    expect(added.credential_source).toBe("config")
    expect(JSON.stringify(after)).not.toContain("sk-added-not-real")
    // And a session freezes it, model id and all.
    const id = await sessionNew(ws, { profile: "my-endpoint", model: "other-model" }, env)
    const line = require("node:fs")
      .readFileSync(join(ws.dir, ".nulya", "sessions", `${id}.jsonl`), "utf8")
      .split("\n")[0]
    const header = JSON.parse(line)
    expect(header.model_identity.provider).toBe("openai")
    expect(header.model_identity.model).toBe("other-model")
    expect(JSON.stringify(header)).not.toContain("sk-added-not-real")
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
}, 30_000)
