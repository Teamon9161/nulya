import type { CardView, Line, PluginApi } from "nulya-tui/plugin-api"

interface Brief {
  done: string
  next_task: string
  keep: string
  drop: string
}

export function activate(api: PluginApi): void {
  api.registerCard("handoff", { render: renderHandoff })
}

/** Durable rendering of the arguments recorded in the ledger, live or replayed. */
export function renderHandoff(view: CardView, width: number): Line[] {
  const room = Math.max(12, width)
  const brief = briefOf(view.args)
  if (!brief) {
    const raw = view.args.trim()
    return wrap(raw || "waiting for handoff details…", room).map((text) => [
      { text, token: raw ? "warn" : "dim" },
    ])
  }

  const out: Line[] = []
  for (const [label, text] of [
    ["next task", brief.next_task],
    ["done", brief.done],
    ["keep", brief.keep],
    ["drop", brief.drop],
  ] as const) {
    if (!text) continue
    const prefix = `${label} · `
    const lines = wrap(text, Math.max(8, room - prefix.length))
    out.push([{ text: prefix, token: "accent.evolve" }, { text: lines[0] ?? "", token: "fg" }])
    for (const line of lines.slice(1)) {
      out.push([{ text: " ".repeat(prefix.length) }, { text: line, token: "fg" }])
    }
  }
  return out
}

function briefOf(raw: string): Brief | null {
  let value: unknown
  try {
    value = JSON.parse(raw)
  } catch {
    return null
  }
  if (typeof value !== "object" || value === null) return null
  const record = value as Record<string, unknown>
  const done = section(record["done"])
  const next_task = section(record["next_task"])
  const keep = section(record["keep"])
  if (!done || !next_task || !keep) return null
  return { done, next_task, keep, drop: section(record["drop"]) }
}

function section(value: unknown): string {
  return typeof value === "string" ? value.trim() : ""
}

function wrap(text: string, width: number): string[] {
  const out: string[] = []
  for (const source of text.split("\n")) {
    if (source.length === 0) {
      out.push("")
      continue
    }
    let rest = source
    while (rest.length > width) {
      const space = rest.lastIndexOf(" ", width)
      const cut = space > 0 ? space : width
      out.push(rest.slice(0, cut))
      rest = rest.slice(cut).trimStart()
    }
    out.push(rest)
  }
  return out
}
