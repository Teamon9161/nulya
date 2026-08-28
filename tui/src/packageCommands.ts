/**
 * Package-declared slash commands, once (tui.md §4.4, goals/tui-plugin.md U2).
 *
 * `contributes.commands` lets an extension add itself to the slash chain
 * without this front end knowing its name in advance — the same relationship
 * `skills.ts` already has with `nulya skill list` (T15), one layer earlier: a
 * package says "I offer `/plan`, and typing it means `with`", and dispatch
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
import type { PackageActionValue, PackageCommand } from "./nulya/files.ts"
import type { Workspace } from "./nulya/bin.ts"

/** One package command, flattened with the id of the package that declared it. */
export interface PackageCommandRow extends PackageCommand {
  id: string
}

/**
 * `Command.action`, parsed into the three verbs this build understands.
 * Anything else is `unknown` — an open vocabulary the kernel deliberately does
 * not police (manifest.zig `Action`), so a verb this build has never heard of
 * is this reader's decision, same discipline as an unrecognised `ui.render`
 * hint (D12).
 *
 * A manifest writes an OBJECT with exactly one key: the verb, whose value is
 * its argument or a bare `true` when it takes none. One older spelling is still
 * folded in: `"wear"`, which is what `"with"` was called before the review
 * renamed it to the word `/with` and `session new --with` already use. That is
 * an ALIAS on an open vocabulary rather than a retired shape — the kernel would
 * happily build either — so it stays, and `deprecatedActionNote` is what lets a
 * caller name the package in a warning.
 *
 * `with`'s value may also be a string (`manifest.Action.withPrompt`): the
 * package's own default first message, sent verbatim when the command is
 * typed bare. `prompt` carries it through unread — same "this reader never
 * interprets the string" discipline `run`'s tool name and `skill`'s ref
 * already have.
 */
export type PackageAction =
  | { kind: "with"; prompt: string | null }
  | { kind: "run"; tool: string }
  | { kind: "skill"; ref: string }
  | { kind: "unknown"; word: string }

export function parseAction(action: PackageActionValue): PackageAction {
  const { verb, target } = splitAction(action)
  if (verb === "with" || verb === "wear") return { kind: "with", prompt: target.length > 0 ? target : null }
  if (verb === "run" && target.length > 0) return { kind: "run", tool: target }
  if (verb === "skill" && target.length > 0) return { kind: "skill", ref: target }
  return { kind: "unknown", word: verb }
}

/**
 * An action reduced to the verb and its argument — the two things every reader
 * wants and the object does not hand over directly.
 *
 * An object with no keys, or more than one, is a manifest the kernel's own
 * `validate` refuses (`InvalidCommandAction`), so it cannot reach a built
 * version; reading the first key is what this side does with the impossible
 * rather than a rule of its own.
 */
function splitAction(action: PackageActionValue): { verb: string; target: string } {
  const [verb] = Object.keys(action)
  if (verb === undefined) return { verb: "", target: "" }
  const value = action[verb]
  return { verb, target: typeof value === "string" ? value.trim() : "" }
}

/**
 * Whether `action`, as WRITTEN in a manifest, uses the `"wear"` verb — a
 * spelling this build still reads but no longer wants — so a caller that
 * already has the row (and so the package id that declared it) can name it in a
 * warning, once, rather than this pure parser reaching for a console of its
 * own. Null when there is nothing to say.
 */
export function deprecatedActionNote(action: PackageActionValue): string | null {
  return "wear" in action ? `rename the "wear" verb to "with"` : null
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
export function packageCompletions(
  // Only the two fields a menu row needs, so a loaded plugin's command list
  // (tui-plugin U3, which has no `action` and no store `id`) goes through the
  // same function rather than a second copy of these four lines.
  rows: readonly { name: string; description: string }[],
  text: string,
): { name: string; what: string }[] {
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
