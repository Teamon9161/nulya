/**
 * `--settings-help`: what a settings file takes, printed by the program that
 * reads it.
 *
 * WHY A COMMAND AND NOT A PAGE. A driver is not an extension — it has no
 * manifest and contributes no skill — so a person, or a model asked to
 * configure one, has nowhere to look but the binary. Any written copy of this
 * table would be a second author of the same fact, and the copy is the half
 * that rots. The bundled `tui` package's manual therefore routes here instead
 * of restating anything.
 *
 * SAME SOURCE AS THE SCREEN. The rows are `state/settings.ts`'s
 * `setting_fields` — the one description of what the parser reads — and the
 * middle column is `acceptsOf`, the same words `/settings` prints and its
 * picker offers. A program prints the subset IT reads: `nulya-acp` reads
 * `[approvals]` and nothing else, and both files go through one parser
 * (`approvals.applyApprovals`), so that subset is a filter and not a second
 * list.
 */
import { basename } from "node:path"
import { approvalPaths, file_name as acp_file } from "./acp/settings.ts"
import { resolveEnvProfile, type ExecTargetKind } from "./state/envprofile.ts"
import { acceptsOf, default_settings, settingsPaths, setting_fields, type SettingField } from "./state/settings.ts"

export interface SettingsHelp {
  /** What the file is called, as a person would name it. */
  file: string
  /** Its layers, nearer last. */
  paths: readonly string[]
  /** Every key that program's parser reads and can describe. */
  fields: readonly SettingField[]
  /** What the file does not say: flags, open key sets, where to change it. */
  tail: readonly string[]
}

/** The TOML table a key lives in — everything before its last dot. */
function tableOf(key: string): string {
  const at = key.lastIndexOf(".")
  return at === -1 ? "" : key.slice(0, at)
}

const pad = (text: string, width: number) => text + " ".repeat(Math.max(0, width - text.length))

export function settingsHelpText(help: SettingsHelp): string {
  const rows = help.fields.map((field) => ({
    table: tableOf(field.key),
    leaf: field.key.slice(tableOf(field.key).length + 1),
    accepts: acceptsOf(field),
    // The DEFAULT, not what is set: this answers "what may I write here", and
    // the layers decide the rest. `/settings` is where a live value is.
    value: field.value(default_settings),
    note: field.note,
  }))
  const leafWidth = Math.max(...rows.map((row) => row.leaf.length))
  const acceptsWidth = Math.max(...rows.map((row) => row.accepts.length))

  const out: string[] = [
    `${help.file} — every key this program reads, what it takes, and its default.`,
    "",
    "Layers merge in order, nearer wins; none has to exist:",
    ...help.paths.map((path, i) => `  ${i + 1}. ${path}`),
    "A list-shaped key is REPLACED by a nearer layer, never merged into, so a",
    "nearer layer can always ask for fewer things.",
  ]
  let table: string | null = null
  for (const row of rows) {
    if (row.table !== table) {
      table = row.table
      out.push("", `[${table}]`)
    }
    out.push(`  ${pad(row.leaf, leafWidth)}  ${pad(row.accepts, acceptsWidth)}  default: ${row.value}`)
    if (row.note) out.push(`  ${" ".repeat(leafWidth)}  · ${row.note}`)
  }
  if (help.tail.length !== 0) out.push("", ...help.tail)
  return out.join("\n") + "\n"
}

/**
 * What an `[env.<kind>]` table replaces when it is not written.
 *
 * The three rows above it can only say WHICH kinds override them — what
 * actually applies is per kind, so no one cell holds it. Asked of
 * `resolveEnvProfile` with no overrides, which is the function the screen
 * composes sessions through, so this cannot come to disagree with what happens.
 */
function envDefaults(): string[] {
  const { session_with, session_prompts } = default_settings.extensions
  const list = (xs: readonly string[]) => (xs.length === 0 ? "[]" : xs.join(", "))
  return [
    "An [env.<kind>] table replaces the three keys in it, per kind, and what it",
    "replaces when nothing is written is:",
    ...(["local", "remote"] as ExecTargetKind[]).map((kind) => {
      const it = resolveEnvProfile(kind, session_with, session_prompts, {})
      return `  ${pad(kind, 8)}bare = ${pad(String(it.bare), 7)}with = ${pad(list(it.with), 16)}session_prompts = ${list(it.session_prompts)}`
    }),
  ]
}

/** `nulya-tui --settings-help`. */
export function tuiSettingsHelp(cwd: string): string {
  return settingsHelpText({
    file: "tui.toml",
    paths: settingsPaths(cwd),
    fields: setting_fields,
    tail: [
      ...envDefaults(),
      "",
      "Also read:",
      '  [keys] <action> = "<binding>"   the action names are in this interface\'s own',
      "                                  /help; an open set, so not a row above",
      "",
      "`/settings` in the interface shows what is set and which file it came from,",
      "and writes the user layer.",
    ],
  })
}

/** `nulya-acp --settings-help`. */
export function acpSettingsHelp(): string {
  return settingsHelpText({
    file: acp_file,
    // The workspace layer is whichever directory a session names, so it is
    // shown as the shape it has rather than as one resolved path.
    paths: [approvalPaths("<the workspace a session opens in>")[0]!, `<that workspace>/.nulya/${acp_file}`],
    fields: setting_fields.filter((field) => field.key.startsWith("approvals.")),
    tail: [
      "That is the whole file: no other section is read.",
      "",
      "The permission mode is not in it — `--mode ask|unsafe` on the command line.",
      "An editor already spawns this process per workspace, so the launch line is",
      "where that choice lives, and a second place to say it would be a second answer.",
      "",
      "`tui.toml` is a different file for a different driver; this one reads none of it.",
      "`nulya-tui --settings-help` prints that one.",
    ],
  })
}

/**
 * How to run this program's own `--settings-help`, as something that can be
 * typed where the session is.
 *
 * A compiled entry point IS the executable. Run from source, the executable is
 * bun and the script it was handed has to be repeated, so the command names
 * both. Which of the two is told by the runner's NAME, because the file system
 * cannot tell: Bun answers `existsSync` for the virtual main path a compiled
 * binary reports. A path with a space in it is quoted and one without is left
 * bare, so the ordinary case is a line that runs in either shell.
 */
export function selfSettingsHelpCommand(): string {
  const quoted = (path: string) => (/[ \t]/.test(path) ? `"${path}"` : path)
  const runner = basename(process.execPath).replace(/\.exe$/i, "").toLowerCase()
  const viaBun = runner === "bun" || runner === "bun-debug"
  const self = viaBun ? `${quoted(process.execPath)} run ${quoted(Bun.main)}` : quoted(process.execPath)
  return `${self} --settings-help`
}
