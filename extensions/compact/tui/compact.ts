import type { LedgerEventView, Line, PluginApi, PluginKey } from "nulya-tui/plugin-api"

export const requestMarker = "<nulya:compact-request>"
export const summaryMarker = "<nulya:context-summary>"

export interface HandoffBrief {
  done: string
  next_task: string
  keep: string
  drop: string
}

interface Proposal {
  key: string
  session: string
  call: string
  seq: number
  brief: HandoffBrief
}

export function activate(api: PluginApi): void {
  const calls = new Map<string, Proposal>()
  const handled = new Set<string>()
  let proposal: Proposal | null = null
  let status = ""
  let running = false

  const panel = api.registerPanel({
    render: renderPanel,
    onKey,
    onClose() {
      if (proposal) handled.add(proposal.key)
      proposal = null
      status = ""
      running = false
    },
  })

  api.registerCommand({
    name: "compact",
    description: "summarise this session and open its continuation in a new tab",
    async run(ctx) {
      if (!ctx.session) {
        api.notice("compact: this tab has no session yet · nothing to compact")
        return
      }
      await run(ctx.session.id, ctx.args.trim().length > 0 ? { focus: ctx.args.trim() } : {})
    },
  })

  api.registerUserTurn({
    id: "compact-context",
    match: (text) => text.startsWith(requestMarker) || text.startsWith(summaryMarker),
    head(view) {
      return view.text.startsWith(requestMarker)
        ? "compaction · continuation brief requested"
        : "context summary · carried from the previous session"
    },
    defaultOpen: (view) => view.text.startsWith(summaryMarker),
    render(view, width) {
      const request = view.text.startsWith(requestMarker)
      return wrap(withoutMarker(view.text), Math.max(12, width)).map((text) => [
        { text, token: request ? "dim" : "fg" },
      ])
    },
    sessionTitle,

  })

  api.observe.onEvent((event, session, source) => {
    if (source !== "live") return
    if (event.kind === "assistant") rememberCalls(event, session)
    if (event.kind === "tool_results") acceptResults(event, session)
  })

  function rememberCalls(event: LedgerEventView, session: string): void {
    const raw = event["calls"]
    if (!Array.isArray(raw)) return
    for (const value of raw) {
      if (typeof value !== "object" || value === null) continue
      const call = value as { id?: unknown; tool?: unknown; args?: unknown }
      if (call.tool !== "handoff" || typeof call.id !== "string") continue
      const brief = briefOf(typeof call.args === "string" ? call.args : "")
      if (!brief) continue
      const key = proposalKey(session, call.id)
      calls.set(key, { key, session, call: call.id, seq: event.seq, brief })
    }
  }

  function acceptResults(event: LedgerEventView, session: string): void {
    const raw = event["results"]
    if (!Array.isArray(raw)) return
    for (const value of raw) {
      if (typeof value !== "object" || value === null) continue
      const result = value as { call_id?: unknown; ok?: unknown }
      if (typeof result.call_id !== "string") continue
      const key = proposalKey(session, result.call_id)
      const found = calls.get(key)
      if (!found) continue
      calls.delete(key)
      if (result.ok !== true || handled.has(key)) continue
      proposal = found
      status = ""
      panel.open()
    }
  }

  function renderPanel(width: number): Line[] {
    if (!proposal) return [[{ text: "no handoff is waiting", token: "dim" }]]
    const out: Line[] = [[{ text: "handoff proposed", token: "accent.evolve" }]]
    for (const line of briefPreview(proposal.brief).slice(0, 8)) {
      out.push([{ text: clip(line, Math.max(12, width)), token: "muted" }])
    }
    out.push([
      {
        text: status || "Enter follow into a new tab · Esc dismiss · the call stays either way",
        token: status ? "warn" : "dim",
      },
    ])
    return out
  }

  function onKey(key: PluginKey): boolean {
    if (key.name !== "return" || !proposal) return false
    if (running || handled.has(proposal.key)) {
      status = running ? "following…" : "this handoff was already handled"
      return true
    }
    const chosen = proposal
    handled.add(chosen.key)
    running = true
    status = "following…"
    void run(chosen.session, { brief_seq: chosen.seq })
      .then((opened) => {
        running = false
        if (!opened) {
          handled.delete(chosen.key)
          status = "not followed · resolve the notice above, then press Enter again"
          return
        }
        proposal = null
        panel.close()
      })
      .catch((error: unknown) => {
        running = false
        status = messageOf(error)
        api.notice(`compact: ${status}`)
      })
    return true
  }

  async function run(sessionId: string, args: { focus?: string; brief_seq?: number }): Promise<boolean> {
    const current = api.observe.session()
    if (!current || current.id !== sessionId) {
      api.notice("compact: return to the session that proposed this handoff before following it")
      return false
    }
    if (current.role !== "driver") {
      api.notice("compact: this tab is observing · follow it from the TUI that is driving the session")
      return false
    }
    if (current.status !== "idle") {
      api.notice("compact: a step is running · try again when it stops")
      return false
    }

    api.notice(args.brief_seq === undefined ? "compacting · asking for a continuation brief…" : "following handoff…")
    const result = await api.actions.extRun("compact", { session: sessionId, ...args })
    const child = compactResult(result.stdout, result.stderr, result.code)
    api.actions.openTab(child.session)
    api.notice(`compact: opened ${child.session} · parent ${sessionId} remains open`)
    return true
  }
}

export function briefOf(raw: string): HandoffBrief | null {
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

export function sessionTitle(text: string): string | null {
  if (!text.startsWith(summaryMarker)) return null
  const carried = withoutMarker(text).replace(/^\s*#+\s*/, "").trim()
  return carried.length > 0 ? `continued · ${carried}` : "continued context"
}

export function compactResult(stdout: string, stderr: string, code: number): { session: string; parent: unknown } {
  if (code !== 0) throw new Error(firstLine(stdout) || firstLine(stderr) || "compact failed")
  let value: unknown
  try {
    value = JSON.parse(stdout.trim())
  } catch {
    throw new Error(`compact returned no result · ${firstLine(stdout) || firstLine(stderr)}`)
  }
  const result = value as { session?: unknown; parent?: unknown } | null
  if (typeof result?.session !== "string" || !result.session.startsWith("s-")) {
    throw new Error(`compact returned no session id · ${firstLine(stdout) || firstLine(stderr)}`)
  }
  return { session: result.session, parent: result.parent }
}

function proposalKey(session: string, call: string): string {
  return `${session}\u0000${call}`
}

function section(value: unknown): string {
  return typeof value === "string" ? value.trim() : ""
}

export function withoutMarker(text: string): string {
  if (text.startsWith(requestMarker)) return text.slice(requestMarker.length).trim()
  if (text.startsWith(summaryMarker)) return text.slice(summaryMarker.length).trim()
  return text.trim()
}

function briefPreview(brief: HandoffBrief): string[] {
  const out: string[] = []
  for (const [label, text] of [
    ["next", brief.next_task],
    ["done", brief.done],
    ["keep", brief.keep],
    ["drop", brief.drop],
  ] as const) {
    if (!text) continue
    const lines = text.split("\n")
    out.push(`${label}: ${lines[0]}`)
    for (const line of lines.slice(1)) out.push(`      ${line}`)
  }
  return out
}

function wrap(text: string, width: number): string[] {
  if (!text) return []
  const out: string[] = []
  for (const source of text.split("\n")) {
    if (!source) {
      out.push("")
      continue
    }
    let rest = source
    while (rest.length > width) {
      const cut = Math.max(1, rest.lastIndexOf(" ", width))
      out.push(rest.slice(0, cut))
      rest = rest.slice(cut).trimStart()
    }
    out.push(rest)
  }
  return out
}

function clip(text: string, width: number): string {
  return text.length <= width ? text : `${text.slice(0, Math.max(1, width - 1))}…`
}

function firstLine(text: string): string {
  return text.trim().split("\n")[0] ?? ""
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
