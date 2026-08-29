/**
 * Where a session's `shell` could run, as this machine answers it (DESIGN §8.1,
 * tui.md §11 T93).
 *
 * `/env` used to be typing only, and the reason written down at the time was
 * that the useful set is not enumerable: an ssh destination is whatever that
 * person's `ssh_config` calls a host, and the distributions on this machine are
 * "a `wsl -l` away". Both halves of that sentence name a source — so this
 * module asks those two sources instead of offering a hard-coded pair of words.
 * A picker built from `wsl.exe -l -q` and `~/.ssh/config` is not pretending to
 * know the answer; it is reporting one. What it cannot enumerate — a host that
 * exists only in DNS, an `Include`d config fragment — is why the dialog keeps a
 * row that hands the typing back.
 *
 * Two families ride the same two sources (`wsl -l`, `~/.ssh/config`): `wsl:`/
 * `ssh:` move only the SHELL (DESIGN §8.1), `remote:wsl:`/`remote:ssh:` move
 * the whole WORKSPACE too (goals/remote-env.md §3.9) — picking one of the
 * latter is the first half of a two-part choice, the second being WHICH
 * directory on that machine (`ui/App.tsx`'s remote-browse flow, `dirsource.
 * ts`'s `remoteDirSource`).
 *
 * NOTHING HERE DECIDES ANYTHING. The kernel parses the spec
 * (`environment.parseExecTarget`) and refuses a bad one with the vocabulary in
 * the message; this only shortens the walk to a spelling that already works. So
 * a probe that fails is one fewer row and never an error: a machine with no WSL
 * and no ssh config still gets `local`, which is the answer it has.
 */
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

/** One row of the picker: what would be remembered, and what it is. */
export interface ExecChoice {
  /** Exactly what `session new --env` takes (`environment.exec_target_syntax`). */
  spec: string
  /** One line, in this machine's terms. */
  what: string
}

/** The two questions this asks the host, as a seam tests can answer instead. */
export interface TargetProbe {
  platform: string
  /** Distribution names, in the order `wsl.exe` lists them. */
  wsl(): Promise<string[]>
  /** Host aliases from the ssh client config. */
  ssh(): Promise<string[]>
}

/**
 * `local` is not probed and never absent: it is where this process is, and a
 * picker that could come back empty would be a dialog with nothing to say.
 */
const here: ExecChoice = { spec: "local", what: "this machine · where the harness itself runs" }

export async function execChoices(probe: TargetProbe = hostProbe): Promise<ExecChoice[]> {
  const [distros, hosts] = await Promise.all([
    probe.platform === "win32" ? probe.wsl() : Promise.resolve([]),
    probe.ssh(),
  ])
  return [
    here,
    // `wsl:<name>` rather than a bare `wsl` row for the default distribution:
    // the spec is frozen into a session header, and a name still means the same
    // distribution after somebody runs `wsl --set-default`.
    ...distros.map((name) => ({ spec: `wsl:${name}`, what: "a WSL distribution · the workspace as /mnt/…" })),
    ...hosts.map((host) => ({ spec: `ssh:${host}`, what: "from your ssh config · the remote account's own home" })),
    // The `remote:` family (goals/remote-env.md §3.9): the WORKSPACE moves,
    // not just the shell — `extensions/std`, `ground`, everything that reads
    // files reads THAT machine's, over a channel this harness itself opens
    // (no ssh/wsl config of its own to read, so these ride the same two
    // sources the rows above already asked). Same names, same source data —
    // the sentence is what tells the two families apart.
    ...distros.map((name) => ({
      spec: `remote:wsl:${name}`,
      what: "a WSL distribution · the WORKSPACE moves there too",
    })),
    ...hosts.map((host) => ({
      spec: `remote:ssh:${host}`,
      what: "from your ssh config · the WORKSPACE moves there too",
    })),
  ]
}

/**
 * The list with the spec in force on it, wherever that came from.
 *
 * A destination typed by hand is not on any list this machine can produce, and
 * a picker that quietly failed to mark the current answer would be telling the
 * person they are somewhere they are not.
 */
export function withCurrent(choices: readonly ExecChoice[], current: string): ExecChoice[] {
  const spec = current.length === 0 ? "local" : current
  if (choices.some((one) => one.spec === spec)) return [...choices]
  return [...choices, { spec, what: "chosen here earlier · not something this machine lists" }]
}

/**
 * `wsl.exe -l -q` writes UTF-16LE unless `WSL_UTF8` is set, and the version
 * that honours that variable is newer than the versions that do not. So the
 * variable is set AND the bytes are sniffed: a NUL in what should be text is
 * the one thing UTF-8 never produces.
 */
export function decodeWslList(bytes: Uint8Array): string {
  const utf16 = (from: Uint8Array) => Buffer.from(from).toString("utf16le")
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) return utf16(bytes.subarray(2))
  if (bytes.subarray(0, 16).includes(0)) return utf16(bytes)
  return new TextDecoder().decode(bytes)
}

/** Distribution names from `wsl.exe -l -q`, which is one bare name per line. */
export function parseWslList(bytes: Uint8Array): string[] {
  return decodeWslList(bytes)
    .split(/\r?\n/)
    // A stray BOM and a trailing NUL both survive the split and both look like
    // a distribution with an invisible name.
    .map((line) => line.replace(/[\uFEFF\u0000]/g, "").trim())
    .filter((line) => line.length > 0)
}

/**
 * `Host` aliases from an ssh config.
 *
 * Patterns are skipped rather than shown: `Host *` is a block of defaults, not
 * a machine, and `ssh:*` is not something anybody can connect to. `Include` is
 * not followed — a fragment file is exactly the case the dialog's last row is
 * for, and a config parser that chased includes would be a second implementation
 * of `ssh`'s own lookup living here.
 */
export function parseSshHosts(text: string): string[] {
  const out: string[] = []
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim()
    if (!/^host\s/i.test(trimmed)) continue
    for (const name of trimmed.slice(4).trim().split(/[\s=]+/)) {
      if (name.length === 0 || /[*?!]/.test(name)) continue
      if (!out.includes(name)) out.push(name)
    }
  }
  return out
}

/** How long a probe may take before this stops waiting for it. */
const probe_ms = 4_000

async function bounded(cmd: string[]): Promise<Uint8Array | null> {
  try {
    const proc = Bun.spawn({
      cmd,
      // Ask for UTF-8; a `wsl.exe` too old to know the variable ignores it and
      // `decodeWslList` handles what it writes instead.
      env: { ...process.env, WSL_UTF8: "1" },
      stdout: "pipe",
      stderr: "ignore",
    })
    const timer = setTimeout(() => proc.kill(), probe_ms)
    try {
      const [bytes, code] = await Promise.all([
        new Response(proc.stdout).bytes(),
        proc.exited,
      ])
      return code === 0 ? bytes : null
    } finally {
      clearTimeout(timer)
    }
  } catch {
    // No such program on this machine. One fewer row.
    return null
  }
}

export const hostProbe: TargetProbe = {
  platform: process.platform,
  async wsl() {
    const bytes = await bounded(["wsl.exe", "-l", "-q"])
    return bytes ? parseWslList(bytes) : []
  },
  async ssh() {
    try {
      return parseSshHosts(readFileSync(join(homedir(), ".ssh", "config"), "utf8"))
    } catch {
      // No config, or one this process may not read: no hosts to offer.
      return []
    }
  },
}
