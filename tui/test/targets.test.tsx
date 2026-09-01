/**
 * `/env`'s picker: what this machine is asked, and what the
 * dialog does with the answer.
 *
 * The colours and the wording are not asserted. What is: that a distribution
 * name survives the encoding `wsl.exe` actually writes, that a pattern in an
 * ssh config is not offered as a host, that a target this host cannot reach is
 * not on the list, and that the row which is NOT a target says so by handing
 * back `null` instead of a spec.
 */
import { expect, test } from "bun:test"
import type { JSX } from "solid-js"
import { testRender } from "@opentui/solid"
import { EnvPicker } from "../src/ui/EnvPicker.tsx"
import { StyleContext, createStyle } from "../src/render/theme.ts"
import { default_settings } from "../src/state/settings.ts"
import { settle } from "./support.ts"
import { execChoices, parseSshHosts, parseWslList, withCurrent, type TargetProbe } from "../src/state/targets.ts"

const style = createStyle(default_settings, {})

function mount(node: () => JSX.Element, width = 80, height = 14) {
  return testRender(() => <StyleContext.Provider value={style}>{node()}</StyleContext.Provider>, { width, height })
}

function probe(over: Partial<TargetProbe> = {}): TargetProbe {
  return {
    platform: "win32",
    wsl: async () => [],
    ssh: async () => [],
    ...over,
  }
}

/** `wsl.exe -l -q` on a host too old for `WSL_UTF8`, byte for byte. */
function utf16(text: string, bom = true): Uint8Array {
  const out: number[] = bom ? [0xff, 0xfe] : []
  for (const unit of text) {
    const code = unit.charCodeAt(0)
    out.push(code & 0xff, code >> 8)
  }
  return new Uint8Array(out)
}

test("a distribution name survives the encoding wsl.exe writes", () => {
  // The whole reason this function exists: read as UTF-8, `Ubuntu` is `U\0b\0…`
  // and every row of the picker would be a name with holes in it.
  expect(parseWslList(utf16("Ubuntu\r\ndocker-desktop\r\n"))).toEqual(["Ubuntu", "docker-desktop"])
  // …and a newer wsl.exe, which honours the variable we set, writes plain text.
  expect(parseWslList(new TextEncoder().encode("Ubuntu\nDebian\n"))).toEqual(["Ubuntu", "Debian"])
})

test("a pattern in an ssh config is a block of defaults, not a machine", () => {
  const config = `
Host *
  ServerAliveInterval 60

Host box tunnel
  HostName 10.0.0.4

Host *.internal
  User me
`
  expect(parseSshHosts(config)).toEqual(["box", "tunnel"])
})

test("a target this host cannot reach is not offered", async () => {
  const listed = await execChoices(probe({ platform: "linux", wsl: async () => ["Ubuntu"] }))
  expect(listed.map((one) => one.spec)).toEqual(["local"])
  // …and on the host that can, the distribution is named rather than left to
  // `wsl`'s default, which is a setting that can move under a frozen session.
  const onWindows = await execChoices(probe({ wsl: async () => ["Ubuntu"], ssh: async () => ["box"] }))
  expect(onWindows.map((one) => one.spec)).toEqual([
    "local",
    "wsl:Ubuntu",
    "remote:wsl:Ubuntu",
    "remote:ssh:box",
  ])
})

test("the remote: family rides the same two sources, one row each behind the shell-only wsl row", async () => {
  // Same data (`wsl -l`, `~/.ssh/config`), a second family of rows — not a
  // second probe, and not the SAME spec doing double duty. `local` never gets
  // a `remote:local` twin: this
  // machine's own workspace is not a target `--workspace` would move to. The
  // ssh source only seeds the `remote:ssh:` row: there is no bare `ssh:`
  // exec target.
  const listed = await execChoices(probe({ wsl: async () => ["Ubuntu"], ssh: async () => ["box"] }))
  expect(listed.map((one) => one.spec)).toEqual([
    "local",
    "wsl:Ubuntu",
    "remote:wsl:Ubuntu",
    "remote:ssh:box",
  ])
  // The sentence is the only thing telling the two families apart, so it has
  // to actually say the workspace moves — the whole reason a person would
  // pick the `remote:` row over the plain one right above it.
  const remoteWsl = listed.find((one) => one.spec === "remote:wsl:Ubuntu")!
  const remoteSsh = listed.find((one) => one.spec === "remote:ssh:box")!
  expect(remoteWsl.what.toUpperCase()).toContain("WORKSPACE")
  expect(remoteSsh.what.toUpperCase()).toContain("WORKSPACE")
})

test("a target typed by hand is still shown as the one in force", () => {
  const listed = withCurrent([{ spec: "local", what: "" }], "ssh:elsewhere")
  expect(listed.map((one) => one.spec)).toEqual(["local", "ssh:elsewhere"])
  // An empty spec is how `tui-state.json` spells "this machine"; the rows spell
  // it `local`, and a picker that could not match the two would mark nothing.
  expect(withCurrent([{ spec: "local", what: "" }], "")).toHaveLength(1)
})

test("the last row is not a target: it hands the typing back", async () => {
  const picked: Array<string | null> = []
  const choices = [
    { spec: "local", what: "this machine" },
    { spec: "wsl:Ubuntu", what: "a distribution" },
  ]
  const setup = await mount(() => (
    <EnvPicker
      choices={choices}
      current="local"
      selected={2}
      onSelect={() => {}}
      onPick={(choice) => picked.push(choice ? choice.spec : null)}
    />
  ))
  try {
    const frame = await settle(setup, 2)
    expect(frame).toContain("wsl:Ubuntu")
    // The syntax for what the list could not enumerate is on the screen, so a
    // person who does not see their host knows the dialog is not the limit —
    // `remote:ssh:<dest>` now, since the bare `ssh:<dest>` exec target this
    // used to point at was retired.
    expect(frame).toContain("remote:ssh:<destination>")
    setup.mockMouse.click(4, rowOf(frame, "somewhere else"))
    await settle(setup, 2)
    expect(picked).toEqual([null])
  } finally {
    setup.renderer.destroy()
  }
})

function rowOf(frame: string, text: string): number {
  const at = frame.split("\n").findIndex((row) => row.includes(text))
  expect(at).toBeGreaterThanOrEqual(0)
  return at
}
