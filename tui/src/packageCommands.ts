/**
 * Package-declared slash commands, once (tui.md §4.4, goals/tui-plugin.md U2).
 *
 * `contributes.commands` lets an extension add itself to the slash chain
 * without this front end knowing its name in advance — the same relationship
 * `skills.ts` already has with `nulya skill list` (T15), one layer earlier: a
 * package says "I offer `/plan`, and typing it means `wear`", and dispatch
 * insertS one more link — built-in → PACKAGE → skill → the model, verbatim
 * (`commands.ts`, `ui/App.tsx` `runCommand`/`runPackageCommand`).
 *
 * `extensions.packageCommands` does the one process spawn (`ext list`) and the
 * manifest reads; everything here is pure, so the merge rules — a built-in is
 * never shadowed, two packages fighting over one name are resolved by "first
 * in scan order" and the loser is reported rather than dropped — are testable
 * without a workspace on disk.
 */
import { packageCommands as harvestPackageCommands } from "./extensions.ts"
import type { PackageCommand } from "./nulya/files.ts"
import type { Workspace } from "./nulya/bin.ts"

/** One package command, flattened with the id of the package that declared it. */
export interface PackageCommandRow extends PackageCommand {
  id: string
}

/**
 * `Command.action`, parsed into the one shape kernel `validate` checks
 * (`run <tool>` must name a tool the SAME manifest declares) plus the two
 * other words this build understands. Anything else is `unknown` — an open
 * vocabulary the kernel deliberately does not police (manifest.zig `Command`),
 * so a word this build has never heard of is this reader's decision, same
 * discipline as an unrecognised `render` hint (D12).
 */
export type PackageAction =
  | { kind: "wear" }
  | { kind: "run"; tool: string }
  | { kind: "skill"; ref: string }
  | { kind: "unknown"; word: string }

export function parseAction(action: string): PackageAction {
  const trimmed = action.trim()
  if (trimmed === "wear") return { kind: "wear" }
  if (trimmed.startsWith("run ")) {
    const tool = trimmed.slice("run ".length).trim()
    if (tool.length > 0) return { kind: "run", tool }
  }
  if (trimmed.startsWith("skill ")) {
    const ref = trimmed.slice("skill ".length).trim()
    if (ref.length > 0) return { kind: "skill", ref }
  }
  return { kind: "unknown", word: trimmed }
}

/**
 * What `ext run <id>@<version> <tool>` receives as its JSON arguments, from
 * whatever text followed the command name on the line.
 *
 * The kernel's own `ext run` requires the trailing JSON to be an OBJECT (`the
 * last argument must be a JSON object`, `cli/ext.zig`), so free text has to
 * live under some key — `text` is the least presumptuous one a tool that
 * wanted a sentence would look for. A person who typed literal JSON gets it
 * forwarded verbatim: this front end does not otherwise interpret the shape
 * ("形状由 tool 自己认", goals/tui-plugin.md U2).
 */
export function runArgs(rest: string): Record<string, unknown> {
  if (rest.length === 0) return {}
  try {
    const parsed: unknown = JSON.parse(rest)
    if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>
    }
  } catch {
    // Not JSON at all: falls through to the wrap below.
  }
  return { text: rest }
}

/** Package rows a built-in of the same name would win anyway (D8: a built-in is never shadowed). */
export function withoutBuiltins(
  rows: readonly PackageCommandRow[],
  builtinNames: ReadonlySet<string>,
): PackageCommandRow[] {
  return rows.filter((row) => !builtinNames.has(row.name))
}

export interface CommandShadow {
  row: PackageCommandRow
  /** The package id whose command of the same name already won. */
  heldBy: string
}

/**
 * Two different packages declaring the same command name: the first in scan
 * order (`extensions.packageCommands`'s own `ext list` order, i.e. kernel
 * store-root search order) keeps it, same "first holder wins" rule store roots
 * already use for a shadowed VERSION (D8) — applied here to a NAME instead.
 * The rest are reported, not silently dropped, so a person can see why typing
 * one name ran a different package than they expected.
 */
export function dedupe(rows: readonly PackageCommandRow[]): {
  winners: PackageCommandRow[]
  shadowed: CommandShadow[]
} {
  const winners: PackageCommandRow[] = []
  const shadowed: CommandShadow[] = []
  const heldBy = new Map<string, string>()
  for (const row of rows) {
    const holder = heldBy.get(row.name)
    if (holder) shadowed.push({ row, heldBy: holder })
    else {
      heldBy.set(row.name, row.id)
      winners.push(row)
    }
  }
  return { winners, shadowed }
}

/** The final table dispatch and completion both read: built-ins never shadowed, then first-in-scan-order per name. */
export function resolve(
  rows: readonly PackageCommandRow[],
  builtinNames: ReadonlySet<string>,
): { winners: PackageCommandRow[]; shadowed: CommandShadow[] } {
  return dedupe(withoutBuiltins(rows, builtinNames))
}

/**
 * The completion menu entries a resolved package command table offers, after
 * built-ins and before skills (`commands.ts` `completions`, `skills.ts`
 * `skillCompletions` — same shape, same "exact match keeps the explanation up"
 * rule).
 */
export function packageCompletions(rows: readonly PackageCommandRow[], text: string): { name: string; what: string }[] {
  if (!text.startsWith("/")) return []
  const head = text.split(/\s/)[0] ?? text
  if (head.length < text.length) {
    const exact = rows.find((row) => `/${row.name}` === head)
    return exact ? [{ name: `/${exact.name}`, what: exact.description }] : []
  }
  return rows.filter((row) => `/${row.name}`.startsWith(head)).map((row) => ({ name: `/${row.name}`, what: row.description }))
}

/**
 * The package command catalog, cached until something could have changed it —
 * same shape and same invalidation contract as `skills.createSkillTable`
 * (`/ext` calls both `invalidate()`s on a membership change).
 */
export interface PackageCommandTable {
  entries(): readonly PackageCommandRow[]
  invalidate(): void
  ready(): Promise<readonly PackageCommandRow[]>
}

export function createPackageCommandTable(
  ws: Workspace,
  env?: Record<string, string | undefined>,
): PackageCommandTable {
  let entries: PackageCommandRow[] = []
  let pending: Promise<readonly PackageCommandRow[]> | null = null

  const load = () => {
    pending ??= harvestPackageCommands(ws, env)
      .then((rows) => {
        entries = rows.map(({ id, command }) => ({ id, ...command }))
        return entries as readonly PackageCommandRow[]
      })
      .catch(() => {
        // No binary, no store: an empty table, never a crash.
        return entries as readonly PackageCommandRow[]
      })
    return pending
  }

  void load()
  return {
    entries: () => entries,
    invalidate: () => {
      pending = null
      void load()
    },
    ready: () => load(),
  }
}
