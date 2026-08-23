/**
 * Test preload (bunfig.toml `[test] preload`): point `NULYA_HOME` at a scratch
 * directory for the whole run, before any test module loads.
 *
 * Nearly every test here spawns the real `nulya` binary, and the TUI's own
 * paths (`state/settings.ts`) resolve the user config dir the same way the
 * kernel does — from `NULYA_HOME`, else the real home. Without this, the
 * developer's `~/.nulya` takes part in every assertion: its extension store
 * (`/ext` listed the seeded `evolution` / `guide` next to the test's `lint` and
 * three tests broke the day the store was seeded — tui.md §11, T21), its
 * `config.toml` with real keys, its `tui.toml`, `tui-state.json` and the trust
 * journal. The kernel's e2e made the same move (`NULYA_HOME=<ws>/.nulya-test-home`).
 *
 * Tests that need a home of their own still pass `NULYA_HOME` per spawn; this
 * only changes what a spawn inherits by default. Set on purpose even when the
 * caller has one: the point is that no run can see the real home.
 */
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const scratchHome = mkdtempSync(join(tmpdir(), "nulya-tui-home-"))
process.env["NULYA_HOME"] = scratchHome

// Best effort: never let cleanup failure fail a test run (a spawned child
// still holding a handle open on Windows, an already-gone directory, etc).
process.on("exit", () => {
  try {
    rmSync(scratchHome, { recursive: true, force: true })
  } catch {
    // ignore
  }
})
