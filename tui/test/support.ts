/**
 * Test helpers: a throwaway workspace that the real `nulya` binary can drive,
 * and a frame settler for renderables (markdown, diff) whose layout resolves
 * across real timer ticks rather than render passes alone.
 */
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { openWorkspace, type Workspace } from "../src/nulya/bin.ts"
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

export async function until(predicate: () => boolean, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
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
