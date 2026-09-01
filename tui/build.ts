/**
 * `bun run compile` — one file you can put on PATH.
 *
 * Only `src/main.tsx` is an entry point, so `test/` (and the driver-loop fixture
 * that lives there) never reaches the executable. The Solid plugin is the same
 * one the runtime preload uses, so the compiled build and `bun run src/main.tsx`
 * see identical JSX semantics.
 *
 * The result still needs a `nulya` binary at run time: it is a driver client
 * over a process boundary, not a second harness. `NULYA_BIN` names it, otherwise
 * a `zig-out/bin/nulya` at or above the workspace, otherwise PATH.
 */
import { join } from "node:path"
import solidPlugin from "@opentui/solid/bun-plugin"

const out = join(import.meta.dir, "dist", process.platform === "win32" ? "nulya-tui.exe" : "nulya-tui")

const result = await Bun.build({
  entrypoints: [join(import.meta.dir, "src", "main.tsx")],
  plugins: [solidPlugin],
  compile: { outfile: out },
})

if (!result.success) {
  for (const log of result.logs) console.error(log)
  process.exit(1)
}

console.log(out)
