/**
 * `bun run compile` — one file per entry point, each one you can put on PATH.
 *
 * There are two: `src/main.tsx` is the screen, `src/acp/main.ts` is the ACP
 * adapter an editor spawns. Nothing else is an entry point, so `test/` (and the
 * driver-loop fixture that lives there) never reaches either executable. The
 * Solid plugin is the same one the runtime preload uses, so the compiled build
 * and `bun run src/main.tsx` see identical JSX semantics.
 *
 * Both results still need a `nulya` binary at run time. Release builds ship
 * it beside the TUI; source builds also search zig-out/bin and PATH.
 */
import { join } from "node:path"
import solidPlugin from "@opentui/solid/bun-plugin"

const target = process.env.NULYA_BUILD_TARGET
const windows = target ? target.includes("windows") : process.platform === "win32"
const exe = (name: string) => join(import.meta.dir, "dist", windows ? `${name}.exe` : name)

const entries: { entry: string; out: string }[] = [
  { entry: join(import.meta.dir, "src", "main.tsx"), out: exe("nulya-tui") },
  ...(!process.env.NULYA_BUILD_TUI_ONLY ? [{ entry: join(import.meta.dir, "src", "acp", "main.ts"), out: exe("nulya-acp") }] : []),
]

for (const { entry, out } of entries) {
  const result = await Bun.build({
    entrypoints: [entry],
    plugins: [solidPlugin],
    compile: { outfile: out, ...(target ? { target: target as "bun-linux-x64" } : {}) },
  })

  if (!result.success) {
    for (const log of result.logs) console.error(log)
    process.exit(1)
  }

  console.log(out)
}
