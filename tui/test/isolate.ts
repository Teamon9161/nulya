/**
 * Test preload (bunfig.toml `[test] preload`): point `NULYA_HOME` (and
 * `CODEX_HOME`) at scratch directories for the whole run, before any test
 * module loads.
 *
 * Nearly every test here spawns the real `nulya` binary, and the TUI's own
 * paths (`state/settings.ts`) resolve the user config dir the same way the
 * kernel does — from `NULYA_HOME`, else the real home. Without this, the
 * developer's `~/.nulya` takes part in every assertion: its extension store
 * (`/ext` would list the seeded `evolution` / `guide` next to the test's
 * `lint`), its
 * `config.toml` with real keys, its `tui.toml`, `tui-state.json` and the trust
 * journal. The kernel's e2e made the same move (`NULYA_HOME=<ws>/.nulya-test-home`).
 *
 * `codex`'s credential is a file the kernel reads straight off the host home
 * (`~/.codex/auth.json`) — `NULYA_HOME` does not touch it. On a
 * machine where `codex login` has actually run, `nulya config show --json`
 * then reports that profile as runnable, which reorders every list built from
 * "the providers that can run" (`/model`'s picker rows put codex ahead of
 * `scripted`) and made `model.test.tsx`'s "picking in /model writes the
 * draft…" flaky on exactly those machines. `CODEX_HOME` is the same escape
 * hatch the kernel's own e2e uses (`tests/e2e/cli.zig`) to point that lookup
 * at an empty directory instead.
 *
 * Tests that need a home of their own still pass `NULYA_HOME` / `CODEX_HOME`
 * per spawn; this only changes what a spawn inherits by default. Set on
 * purpose even when the caller has one: the point is that no run can see the
 * real home.
 */
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const scratchHome = mkdtempSync(join(tmpdir(), "nulya-tui-home-"))
process.env["NULYA_HOME"] = scratchHome
process.env["CODEX_HOME"] = join(scratchHome, "codex-home")

// Best effort: never let cleanup failure fail a test run (a spawned child
// still holding a handle open on Windows, an already-gone directory, etc).
process.on("exit", () => {
  try {
    rmSync(scratchHome, { recursive: true, force: true })
  } catch {
    // ignore
  }
})
