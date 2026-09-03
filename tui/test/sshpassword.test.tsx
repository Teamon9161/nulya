import { expect, test } from "bun:test"
import { Show, createSignal } from "solid-js"
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { testRender } from "@opentui/solid"
import { remoteCheck } from "../src/nulya/cli.ts"
import { createStyle, ScreenContext, StyleContext } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { settle } from "./support.ts"
import { Composer } from "../src/ui/Composer.tsx"
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

test("the composer is off the layout while the password field stands in its place", async () => {
  const style = createStyle(default_settings, {})
  const [hidden, setHidden] = createSignal(false)
  const setup = await testRender(
    () => (
      <StyleContext.Provider value={style}>
        <ScreenContext.Provider value={() => ({ width: 80, height: 20 })}>
          <Show when={hidden()}>
            <SshPasswordPrompt spec="remote:ssh:box" bytes={4} />
          </Show>
          <Composer hidden={hidden()} onSubmit={() => {}} />
        </ScreenContext.Provider>
      </StyleContext.Provider>
    ),
    { width: 80, height: 20 },
  )
  try {
    expect(await settle(setup, 2)).toContain("message nulya")
    setHidden(true)
    const asking = await settle(setup, 2)
    // One input box on screen, and it is the one the password goes into.
    expect(asking).not.toContain("message nulya")
    expect(asking).toContain("SSH password")
  } finally {
    setup.renderer.destroy()
  }
})

test("a slow remote command narrates itself line by line while it runs", async () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-remote-progress-"))
  try {
    const bin = join(dir, "fake-nulya")
    // Two narration lines on stderr before the answer on stdout: what an
    // install over a slow link looks like from here.
    writeFileSync(
      bin,
      `#!/bin/sh\n` +
        `echo 'no nulya on that machine; installing one' >&2\n` +
        `echo 'sending this nulya (5 MB) to x86_64-linux' >&2\n` +
        `printf '%s\\n' '{"nulya":"test","os":"linux","arch":"x86_64","home":"/home/test","cwd":"/work","dialect":"bash"}'\n`,
    )
    chmodSync(bin, 0o700)
    const seen: string[] = []
    const hello = await remoteCheck({ dir, bin }, "remote:ssh:box", undefined, undefined, (line) => seen.push(line))
    expect(hello.os).toBe("linux")
    // Each line arrived on its own, so the screen can show the latest one.
    expect(seen).toEqual([
      "no nulya on that machine; installing one",
      "sending this nulya (5 MB) to x86_64-linux",
    ])
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
