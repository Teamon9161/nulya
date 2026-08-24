import type { CardView, Line, PluginApi, Surface } from "nulya-tui/plugin-api"

interface DiffPresentation {
  kind: "diff"
  patch: string
  path?: string
  filetype?: string
}

export function activate(api: PluginApi) {
  api.registerCard("edit", {
    render(view: CardView): Surface {
      const diff = diffOf(view.presentation)
      if (view.ok !== false && diff) {
        return { kind: "diff", patch: diff.patch, ...(diff.path ? { path: diff.path } : {}), ...(diff.filetype ? { filetype: diff.filetype } : {}) }
      }
      return outputLines(view)
    },
  })
}

function diffOf(value: unknown): DiffPresentation | null {
  if (typeof value !== "object" || value === null) return null
  const record = value as Record<string, unknown>
  if (record["kind"] !== "diff" || typeof record["patch"] !== "string") return null
  return {
    kind: "diff",
    patch: record["patch"],
    ...(typeof record["path"] === "string" ? { path: record["path"] } : {}),
    ...(typeof record["filetype"] === "string" ? { filetype: record["filetype"] } : {}),
  }
}

function outputLines(view: CardView): Line[] {
  const text = view.output.length > 0 ? view.output : view.state === "done" ? "" : "waiting for edit result…"
  if (text.length === 0) return []
  return text.split("\n").map((line) => [{ text: line, token: view.ok === false ? "err" : "fg" }])
}
