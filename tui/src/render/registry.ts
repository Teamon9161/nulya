/**
 * The ONE place that matches on a tool name or a shell command prefix.
 *
 * Everything else in `render/` receives a `ToolPresentation` and draws it. Two
 * reasons this is a single choke point: a name match scattered over a dozen
 * card components rots, and the same registry has to serve the live stream and
 * a replay (tui.md §3) — one decision, one place, both paths.
 *
 * T1 fills in shell / edit / extension tools and recognises `nulya …` commands
 * as evolution actions. The full head-line table for each `nulya` subcommand
 * (tui.md §5.2) is T2's; a command this table cannot read falls back to the
 * plain shell presentation rather than failing.
 */
import { parseEditArgs } from "../nulya/diff.ts"
import type { Glyphs } from "./theme.ts"

export type AccentRole = "tool" | "evolve"
export type BodyKind = "diff" | "output"

export interface ToolPresentation {
  glyph: string
  /** Single-line head: what this call is, at a glance. */
  head: string
  accent: AccentRole
  body: BodyKind
  /** True when the card should carry the edit's unified diff. */
  isEdit: boolean
}

function firstLine(text: string, limit: number): string {
  const line = text.split("\n", 1)[0] ?? ""
  return line.length > limit ? `${line.slice(0, limit - 1)}…` : line
}

export function shellCommandOf(argsJson: string): string | null {
  try {
    const value = JSON.parse(argsJson)
    if (value && typeof value === "object" && typeof (value as { command?: unknown }).command === "string") {
      return (value as { command: string }).command
    }
  } catch {
    // Arguments still streaming in, or malformed; the caller shows them raw.
  }
  return null
}

/** A one-line digest of arbitrary tool arguments: top-level keys, truncated. */
function argsSummary(argsJson: string, limit: number): string {
  try {
    const value = JSON.parse(argsJson)
    if (value && typeof value === "object" && !Array.isArray(value)) {
      const parts = Object.entries(value as Record<string, unknown>).map(([key, entry]) => {
        const text = typeof entry === "string" ? entry : JSON.stringify(entry)
        return `${key}=${firstLine(text ?? "", 40)}`
      })
      return firstLine(parts.join(" "), limit)
    }
  } catch {
    // Fall through.
  }
  return firstLine(argsJson, limit)
}

/** `nulya …` through shell is how the agent evolves itself — it reads differently. */
function evolvePresentation(command: string, glyphs: Glyphs): ToolPresentation | null {
  const words = command.trim().split(/\s+/)
  if (words[0] !== "nulya" && !/[\\/]nulya(\.exe)?$/i.test(words[0] ?? "")) return null
  const verb = words[1] ?? ""
  const glyph =
    verb === "src"
      ? glyphs.readKernel
      : verb === "skill"
        ? glyphs.skill
        : verb === "session"
          ? glyphs.subSession
          : glyphs.build
  return { glyph, head: firstLine(command, 200), accent: "evolve", body: "output", isEdit: false }
}

export function describeTool(tool: string, argsJson: string, glyphs: Glyphs): ToolPresentation {
  if (tool === "shell") {
    const command = shellCommandOf(argsJson)
    if (command === null) {
      return { glyph: glyphs.shell, head: firstLine(argsJson, 200), accent: "tool", body: "output", isEdit: false }
    }
    return (
      evolvePresentation(command, glyphs) ?? {
        glyph: glyphs.shell,
        head: firstLine(command, 200),
        accent: "tool",
        body: "output",
        isEdit: false,
      }
    )
  }
  if (tool === "edit") {
    const args = parseEditArgs(argsJson)
    return {
      glyph: glyphs.edit,
      head: args ? args.path : firstLine(argsJson, 200),
      accent: "tool",
      body: args ? "diff" : "output",
      isEdit: args !== null,
    }
  }
  return {
    glyph: glyphs.ext,
    head: `${tool || "tool"} ${argsSummary(argsJson, 120)}`.trimEnd(),
    accent: "tool",
    body: "output",
    isEdit: false,
  }
}
