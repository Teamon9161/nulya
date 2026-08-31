import { expect, test } from "bun:test"
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { testRender } from "@opentui/solid"
import { remoteCheck } from "../src/nulya/cli.ts"
import { createStyle, ScreenContext, StyleContext } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { settle } from "./support.ts"
import { SshPasswordPrompt } from "../src/ui/SshPasswordPrompt.tsx"

const nonWindows = process.platform === "win32" ? test.skip : test

nonWindows("secret stdin is written once, wiped, and absent from argv", async () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-ssh-secret-"))
  try {
    const stdinPath = join(dir, "stdin")
    const argvPath = join(dir, "argv")
    const bin = join(dir, "fake-nulya")
    writeFileSync(
      bin,
      `#!/bin/sh\nprintf '%s\\n' "$@" > '${argvPath}'\ncat > '${stdinPath}'\nprintf '%s\\n' '{"nulya":"test","os":"linux","arch":"x86_64","home":"/home/test","cwd":"/work","dialect":"bash"}'\n`,
    )
    chmodSync(bin, 0o700)
    const secret = new TextEncoder().encode("not-on-the-command-line")
    await remoteCheck({ dir, bin }, "remote:ssh:box", undefined, secret)
    expect([...secret]).toEqual(new Array(secret.length).fill(0))
    expect(readFileSync(stdinPath, "utf8")).toBe("not-on-the-command-line\n")
    expect(readFileSync(argvPath, "utf8")).not.toContain("not-on-the-command-line")
    expect(readFileSync(argvPath, "utf8")).toContain("--ssh-password-stdin")
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("SSH password prompt renders bullets and never receives secret text", async () => {
  const style = createStyle(default_settings, {})
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <ScreenContext.Provider value={() => ({ width: 80, height: 20 })}>
          <SshPasswordPrompt spec="remote:ssh:box" bytes={7} />
        </ScreenContext.Provider>
      </StyleContext.Provider>
    ),
    { width: 80, height: 20 },
  )
  try {
    const frame = await settle(setup, 2)
    expect(frame).toContain("•••••••")
    expect(frame).toContain("stays in memory only")
    expect(frame).not.toContain("hunter2")
  } finally {
    setup.renderer.destroy()
  }
})
