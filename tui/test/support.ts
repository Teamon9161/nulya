/**
 * Test helpers: a throwaway workspace that the real `nulya` binary can drive,
 * and a frame settler for renderables (markdown, diff) whose layout resolves
 * across real timer ticks rather than render passes alone.
 */
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { openWorkspace, type Workspace } from "../src/nulya/bin.ts"
import { default_settings, type Settings } from "../src/state/settings.ts"
import type { ConfigView } from "../src/nulya/cli.ts"
import type { TranscriptItem } from "../src/state/session.ts"

export interface TempWorkspace extends Workspace {
  cleanup(): void
}

/**
 * A fresh directory with its own `.nulya/`. The binary is found by walking up
 * from this package (or `NULYA_BIN`), so tests exercise the real CLI while
 * writing nothing into the repository's own session store.
 */
export function tempWorkspace(): TempWorkspace {
  const dir = mkdtempSync(join(tmpdir(), "nulya-tui-"))
  const ws = openWorkspace(dir)
  return {
    ...ws,
    cleanup() {
      try {
        rmSync(dir, { recursive: true, force: true })
      } catch {
        // A step process may still hold the session lock on Windows; the OS
        // temp directory is allowed to keep it.
      }
    },
  }
}

/** The deterministic offline provider, so no test ever needs an API key. */
export const scripted_env = { NULYA_SCRIPTED_MODE: "finish" }
export const scripted_loop_env = { NULYA_SCRIPTED_MODE: "loop" }

/**
 * Settings for a test that wants tool calls to RUN (tui.md §5.7).
 *
 * Every step this TUI drives is gated — the kernel asks before each tool call —
 * and the default mode is `ask`, which means a person. A test with nobody at the
 * keyboard is a test in `auto` mode: the same gate, answered immediately. What
 * `ask` does is its own test, where the keys are pressed on purpose.
 */
export const auto_settings: Settings = {
  ...default_settings,
  driver: { mode: "auto" },
  // …and without the `handoff` package. Composing it is a real behaviour with
  // its own test; here it would put a second extension in every workspace whose
  // store these tests then read back (tui.md §5.8).
  extensions: { ...default_settings.extensions, handoff: false },
}

/**
 * A config the way `nulya config show --json` prints it, with one key present.
 *
 * Here rather than in either test file because `/model` and `/provider` are two
 * screens over these same rows (tui.md §11, T21) and both need them; a test
 * file importing another test file would register that file's tests twice.
 */
export const fake_config: ConfigView = {
  paths: { system: "/etc/nulya/config.toml", user: "/home/me/.nulya/config.toml", project: ".nulya/config.toml" },
  active_profile: "openai",
  registry: { max_tools: 8, pinned_native_tools: [] },
  profiles: [
    {
      name: "openai",
      kind: "openai",
      base_url: "https://api.openai.com/v1",
      api_key_env: "OPENAI_API_KEY",
      credential: false,
      credential_source: "none",
      model: "gpt-5.6-sol",
      models: ["gpt-5.6-sol", "gpt-5.6-luna"],
      effort: null,
      catalog: null,
    },
    {
      name: "deepseek",
      kind: "openai",
      base_url: "https://api.deepseek.com",
      api_key_env: "DEEPSEEK_API_KEY",
      credential: true,
      credential_source: "env",
      model: "deepseek-v4-flash",
      models: ["deepseek-v4-flash", "deepseek-v4-pro"],
      effort: null,
      catalog: null,
    },
    { name: "codex", kind: "codex", base_url: "", api_key_env: "", credential: false, credential_source: "none", model: "gpt-5.5", models: ["gpt-5.5"], effort: "low", catalog: null },
    { name: "scripted", kind: "scripted", base_url: "", api_key_env: "", credential: true, credential_source: "builtin", model: "scripted-demo", models: ["scripted-demo"], effort: null, catalog: null },
  ],
  models: [
    { id: "gpt-5.6-sol", label: "GPT-5.6 Sol", efforts: ["low", "medium", "high"], default_effort: "medium", context_window: 1_050_000 },
    { id: "deepseek-v4-flash", label: "DeepSeek V4 Flash", efforts: ["off", "low", "high", "max"], default_effort: null, context_window: 1_000_000 },
    { id: "deepseek-v4-pro", label: "DeepSeek V4 Pro", efforts: ["off", "low", "high", "max"], default_effort: null, context_window: 1_000_000 },
    { id: "gpt-5.5", label: "GPT-5.5 (Codex)", efforts: ["off", "low", "medium", "high"], default_effort: null, context_window: null },
  ],
}

interface Settleable {
  renderOnce(): Promise<unknown>
  captureCharFrame(): string
}

/** Render `passes` times with a real delay between them, then capture. */
export async function settle(setup: Settleable, passes = 8, delayMs = 40): Promise<string> {
  for (let i = 0; i < passes; i++) {
    await new Promise((resolve) => setTimeout(resolve, delayMs))
    await setup.renderOnce()
  }
  return setup.captureCharFrame()
}

/**
 * A captured frame as lines with their trailing blanks removed — what a "no row
 * wraps" assertion needs. The renderer pads every row out to the full width, so
 * the raw split says nothing; what matters is where the last glyph sits.
 */
export function frameLines(frame: string): string[] {
  return frame.split("\n").map((line) => line.replace(/\s+$/, ""))
}

export async function until(predicate: () => boolean | Promise<boolean>, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!(await predicate())) {
    if (Date.now() > deadline) throw new Error("timed out waiting for a condition")
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
}

/**
 * The comparable shape of a transcript: everything that came from the ledger,
 * with view-only fields (keys, fold state, streaming flags) dropped. Two paths
 * to the same session must agree on exactly this.
 */
export function projection(items: TranscriptItem[]): unknown[] {
  return items.map((item) => {
    switch (item.kind) {
      case "user":
        return { kind: item.kind, seq: item.seq, text: item.text, queued: item.queued }
      case "assistant":
        return { kind: item.kind, seq: item.seq, text: item.text }
      case "thinking":
        return { kind: item.kind, seq: item.seq, text: item.text, opaque: item.opaque }
      case "tool":
        return {
          kind: item.kind,
          seq: item.seq,
          tool: item.tool,
          callId: item.callId,
          args: item.args,
          ok: item.ok,
          output: item.output,
          spillPath: item.spillPath,
        }
      case "capability":
        return { kind: item.kind, seq: item.seq, id: item.id, version: item.version, text: item.text }
      default:
        return { kind: item.kind, seq: item.seq }
    }
  })
}
