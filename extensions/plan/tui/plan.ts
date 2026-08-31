/**
 * The `plan` package's front end (goals/tui-plugin.md U4, contract in
 * `tui/plugin-api.d.ts`).
 *
 * Three surfaces, and each one exists because the declaration layer could not
 * have said it:
 *
 *  - a CARD for `propose`, drawing the plan out of the call's arguments while
 *    they are still arriving (`view.args` grows during `state: "pending"`), so
 *    the plan appears in the transcript as it is written rather than in one
 *    lump when the call returns;
 *  - a PANEL that opens by itself when a `propose` call finishes, where the
 *    plan is read line by line, commented on, and either sent back for revision
 *    or approved;
 *  - one COMMAND, `/plan-review`, to open that panel again after `Esc`.
 *
 * There is deliberately no widget: the package DECLARES `todo{panel: true}`, and
 * a code widget would supersede that row (`registerWidget`'s contract) to say
 * the same thing twice. The checklist is progress; this module is review.
 *
 * ── WHERE THE PLAN COMES FROM ─────────────────────────────────────────────
 *
 * The ledger, always. `observe.onEvent` reads the `propose` call's arguments off
 * the assistant event the kernel wrote — the same bytes the model sent, the same
 * bytes a replay would show — so this panel is a lens on the conversation and
 * never a second copy of it. Comments go back the one way a plugin can speak:
 * `appendNote`, which is `session append` with a sentinel, which is what a
 * person typing the same words would produce.
 *
 * Nothing here survives the process, and nothing here should: the cursor, the
 * selection and a half-typed comment are view state (D5). A plan proposed in an
 * earlier run is in that session's ledger and will be seen again the next time
 * one is proposed; `/plan-review` says so rather than pretending otherwise.
 */
import type { CardView, Line, PluginApi, PluginKey } from "nulya-tui/plugin-api"

/**
 * How many plan lines one page of the panel shows.
 *
 * A renderer is told its width and not its height (D9): the host caps a panel at
 * half the screen and counts what it left out, which is the guard that keeps the
 * transcript readable, but it means this number is a guess made once. Eight
 * lines plus this module's own four rows of chrome fits inside the cap on a
 * 24-row terminal, which is the smallest screen worth planning on.
 */
const page_rows = 8

/** At most this many plan lines in a transcript card; the panel is for reading. */
const card_rows = 40

interface Comment {
  /** Zero-based, inclusive. */
  from: number
  to: number
  text: string
}

export function activate(api: PluginApi): void {
  /** The latest proposed plan, and the call it came from. */
  let plan: { call: string; text: string } | null = null
  let lines: string[] = []
  let cursor = 0
  let top = 0
  /** Where `v` started a selection, or null when the cursor is alone. */
  let anchor: number | null = null
  let comments: Comment[] = []
  /** A comment being typed, or null. */
  let draft: string | null = null
  /** One line about what just happened, under the plan. */
  let status = ""
  /** The `propose` call this run is waiting to see finish. */
  let awaiting: string | null = null
  /** `a` was pressed once while comments were unsent; a second one means it. */
  let armed = false

  const panel = api.registerPanel({
    render: renderPanel,
    onKey,
    onClose() {
      // The draft and the selection are about a panel that is on screen; the
      // comments are about the plan, and the plan is still there.
      draft = null
      anchor = null
    },
  })

  // ── Reading the conversation ─────────────────────────────────────────────

  api.observe.onEvent((event) => {
    if (event.kind !== "assistant") return
    const calls = event["calls"]
    if (!Array.isArray(calls)) return
    for (const raw of calls) {
      const call = raw as { id?: unknown; tool?: unknown; args?: unknown }
      if (call.tool !== "propose") continue
      const text = planOf(typeof call.args === "string" ? call.args : "")
      if (text === null || text.length === 0) continue
      adopt(typeof call.id === "string" ? call.id : "", text)
    }
  })

  api.observe.onStream((line) => {
    if (line.stream !== "tool") return
    // A `tool` line names the call; only `begin` names the TOOL, so the id is
    // remembered there and matched when it ends. Opening on the end rather than
    // on the assistant event is the difference between "the model has finished
    // saying it" and "the call has been recorded".
    if (line.event === "begin") {
      const call = line["call_id"]
      if (line["tool"] === "propose" && typeof call === "string") awaiting = call
      return
    }
    if (line.event !== "end") return
    const call = line["call_id"]
    if (typeof call !== "string" || call !== awaiting) return
    awaiting = null
    if (!plan) return
    status = ""
    // A queued open is honoured the moment a trusted zone clears (D4); there is
    // nothing to check for here and nothing to retry.
    panel.open()
  })

  /** A newly proposed plan replaces the old one, and the comments about it. */
  function adopt(call: string, text: string): void {
    if (plan && plan.text === text) {
      plan = { call, text }
      return
    }
    plan = { call, text }
    lines = text.replace(/\r\n/g, "\n").split("\n")
    cursor = 0
    top = 0
    anchor = null
    draft = null
    // Comments were quotations of a text that no longer exists. They have
    // already been sent; keeping them would attach them to the wrong lines.
    comments = []
    status = ""
    armed = false
  }

  // ── The transcript card ──────────────────────────────────────────────────

  api.registerCard("propose", {
    render(view: CardView, width: number): Line[] {
      const text = planOf(view.args)
      if (text === null) {
        return [[{ text: view.state === "pending" ? "writing the plan…" : "no plan in this call", token: "dim" }]]
      }
      const rows = text.replace(/\r\n/g, "\n").split("\n")
      const out: Line[] = [
        [
          { text: view.state === "done" ? "plan" : "plan · writing", token: "accent.assistant" },
          { text: ` · ${rows.length} line${rows.length === 1 ? "" : "s"}`, token: "muted" },
        ],
      ]
      for (const row of rows.slice(0, card_rows)) out.push([{ text: clip(row, width), token: "fg" }])
      if (rows.length > card_rows) {
        out.push([
          { text: `… ${rows.length - card_rows} more line${rows.length - card_rows === 1 ? "" : "s"} · `, token: "faint" },
          { text: "/plan-review", token: "dim" },
        ])
      }
      return out
    },
  })

  // ── The review panel ─────────────────────────────────────────────────────

  api.registerCommand({
    name: "plan-review",
    description: "review the plan this session proposed",
    run() {
      if (!plan) {
        api.notice("plan: nothing proposed in this run yet")
        return
      }
      panel.open()
    },
  })

  function renderPanel(width: number): Line[] {
    if (!plan) {
      return [
        [{ text: "no plan yet", token: "dim" }],
        [{ text: "the model records one by calling propose", token: "faint" }],
      ]
    }
    const gutter = String(lines.length).length
    const first = Math.min(top, Math.max(0, lines.length - 1))
    const last = Math.min(first + page_rows, lines.length)

    const out: Line[] = [
      [
        { text: "plan", token: "fg" },
        { text: ` · lines ${first + 1}-${last} of ${lines.length}`, token: "muted" },
        { text: comments.length > 0 ? ` · ${comments.length} comment${comments.length === 1 ? "" : "s"}` : "", token: "warn" },
      ],
    ]
    for (let at = first; at < last; at++) {
      const selected = inSelection(at)
      const marked = comments.some((one) => at >= one.from && at <= one.to)
      const mark = at === cursor ? ">" : selected ? "|" : marked ? "*" : " "
      out.push([
        { text: `${mark} `, token: at === cursor ? "accent.user" : marked ? "warn" : "faint" },
        { text: `${String(at + 1).padStart(gutter, " ")} `, token: "faint" },
        { text: clip(lines[at] ?? "", Math.max(8, width - gutter - 3)), token: selected || at === cursor ? "fg" : "dim" },
      ])
    }
    if (draft !== null) {
      out.push([
        { text: `comment on ${range()}: `, token: "warn" },
        { text: draft.length > 0 ? draft : "…", token: "fg" },
        { text: "  Enter save · Esc cancel", token: "faint" },
      ])
    } else {
      out.push([{ text: status.length > 0 ? status : hint(), token: status.length > 0 ? "warn" : "dim" }])
    }
    return out
  }

  function hint(): string {
    return "j/k move · u/d page · v select · c comment · r request changes · a approve"
  }

  function range(): string {
    const [from, to] = span()
    return from === to ? `line ${from + 1}` : `lines ${from + 1}-${to + 1}`
  }

  function span(): [number, number] {
    if (anchor === null) return [cursor, cursor]
    return anchor <= cursor ? [anchor, cursor] : [cursor, anchor]
  }

  function inSelection(at: number): boolean {
    if (anchor === null) return false
    const [from, to] = span()
    return at >= from && at <= to
  }

  function move(by: number): void {
    cursor = Math.max(0, Math.min(lines.length - 1, cursor + by))
    if (cursor < top) top = cursor
    if (cursor >= top + page_rows) top = cursor - page_rows + 1
    top = Math.max(0, Math.min(top, Math.max(0, lines.length - page_rows)))
  }

  function onKey(key: PluginKey): boolean {
    if (!plan) return false

    // Typing a comment. Everything is consumed while this is open — including
    // `escape`, which cancels the draft rather than closing the panel; a second
    // `escape` reaches the host and closes it, which is the ordinary two-step a
    // note field has everywhere else in this front end.
    if (draft !== null) {
      if (key.name === "escape") {
        draft = null
        return true
      }
      if (key.name === "return") {
        const text = draft.trim()
        draft = null
        if (text.length === 0) {
          status = "empty comment · nothing added"
          return true
        }
        const [from, to] = span()
        comments = [...comments.filter((one) => !(one.from === from && one.to === to)), { from, to, text }]
        anchor = null
        armed = false
        status = `${comments.length} comment${comments.length === 1 ? "" : "s"} · r sends them back`
        return true
      }
      if (key.name === "backspace" || key.name === "delete") {
        draft = draft.slice(0, -1)
        return true
      }
      if (key.name === "space") {
        draft += " "
        return true
      }
      if (typeof key.text === "string" && key.text.length > 0) draft += key.text
      return true
    }

    switch (key.name) {
      case "j":
      case "down":
        move(1)
        return true
      case "k":
      case "up":
        move(-1)
        return true
      case "d":
      case "pagedown":
        move(page_rows)
        return true
      case "u":
      case "pageup":
        move(-page_rows)
        return true
      case "g":
        move(key.shift ? lines.length : -lines.length)
        return true
      case "v":
        anchor = anchor === null ? cursor : null
        status = anchor === null ? "" : `selecting from line ${anchor + 1}`
        return true
      case "c":
        draft = ""
        return true
      case "r":
        requestChanges()
        return true
      case "a":
        void approvePlan()
        return true
      default:
        // Anything else — `escape` above all — is the host's. That is what
        // guarantees a person can always leave a plugin's panel.
        return false
    }
  }

  /**
   * Send every comment back as ONE user turn.
   *
   * One turn rather than one per comment because the model reads them together
   * and revises once, and because each turn is a cache increment: a review that
   * cost six turns would cost six revisions' worth of prefix for no more
   * information.
   */
  function requestChanges(): void {
    if (comments.length === 0) {
      status = "no comments yet · c writes one"
      return
    }
    const text = commentsText()
    const sent = comments.length
    comments = []
    anchor = null
    armed = false
    status = "sent"
    panel.close()
    void api.actions
      .appendNote("plan-comments", text)
      .then(() => api.notice(`plan: ${sent} comment${sent === 1 ? "" : "s"} sent · the model will revise`))
      .catch((error: unknown) => api.notice(`plan: could not send the comments · ${messageOf(error)}`))
  }

  function commentsText(): string {
    const parts = [
      "I read the plan. Revise it to address every comment below, then call `propose` again with the complete plan — not a diff, not a list of changes.",
    ]
    for (const one of [...comments].sort((a, b) => a.from - b.from)) {
      const where = one.from === one.to ? `line ${one.from + 1}` : `lines ${one.from + 1}-${one.to + 1}`
      const quoted = lines
        .slice(one.from, one.to + 1)
        .map((row) => `> ${row}`)
        .join("\n")
      parts.push(`--- ${where} ---\n${quoted}\n\n${one.text}`)
    }
    return parts.join("\n\n")
  }

  /**
   * Approve: freeze the plan into a brief, then fork on it.
   *
   * Two steps, and both are verbs somebody already has (D5). `approve` is this
   * package's own tool, run the way a driver runs one; `compact` is `/compact`'s
   * `brief_file` branch, the same fork the front end performs when the model
   * writes a handoff. The child session is created by `session new --parent`
   * with no `--with`, so the plan travels and this persona does not: the work is
   * carried out by an ordinary session that can actually change things.
   */
  async function approvePlan(): Promise<void> {
    if (!plan) return
    const session = api.observe.session()
    if (!session) {
      status = "no session yet · nothing to continue"
      return
    }
    if (comments.length > 0 && !armed) {
      // Approving with comments in hand is almost always a mis-key: the person
      // wrote them to be answered. Said once, then taken at face value.
      armed = true
      status = `${comments.length} comment${comments.length === 1 ? "" : "s"} not sent · r sends them · a again approves without them`
      return
    }
    armed = false
    status = "approving…"
    try {
      const run = await api.actions.extRun("approve", { session: session.id, plan_md: plan.text })
      if (run.code !== 0) {
        status = `approve failed · ${firstLine(run.stdout) || firstLine(run.stderr)}`
        api.notice(status)
        return
      }
      const brief = recordedPath(run.stdout)
      if (brief === null) {
        status = `approve wrote no brief · ${firstLine(run.stdout)}`
        api.notice(status)
        return
      }
      const compact = await api.actions.extRunPackage("compact", "compact", {
        session: session.id,
        brief_file: brief,
      })
      const forked = compactResult(compact.stdout, compact.stderr, compact.code)
      api.actions.openTab(forked.session)
      panel.close()
      api.notice(`plan approved · carrying it out in ${forked.session}`)
    } catch (error) {
      status = `approve failed · ${messageOf(error)}`
      api.notice(status)
    }
  }
}

// ── Pure helpers ───────────────────────────────────────────────────────────

/**
 * The plan text in a `propose` call's arguments.
 *
 * Tolerates a HALF-WRITTEN object, because a card is drawn while the arguments
 * are still streaming in (`CardView.args` grows during `pending`). The strict
 * parse is tried first, so a complete call never goes through the scanner.
 */
export function compactResult(stdout: string, stderr: string, code: number): { session: string } {
  if (code !== 0) {
    throw new Error(firstLine(stdout) || firstLine(stderr) || "compact failed · build and activate the compact package, then approve again")
  }
  let value: unknown
  try {
    value = JSON.parse(stdout.trim())
  } catch {
    throw new Error(`compact returned no result · ${firstLine(stdout) || firstLine(stderr)}`)
  }
  const session = (value as { session?: unknown } | null)?.session
  if (typeof session !== "string" || !session.startsWith("s-")) {
    throw new Error(`compact returned no session id · ${firstLine(stdout) || firstLine(stderr)}`)
  }
  return { session }
}

export function planOf(args: string): string | null {
  try {
    const value = JSON.parse(args) as { plan_md?: unknown }
    if (typeof value.plan_md === "string") return value.plan_md
  } catch {
    // Still arriving — fall through to the partial reader.
  }
  return partialPlan(args)
}

/** As much of `"plan_md": "…"` as has been written, decoded. */
function partialPlan(args: string): string | null {
  const at = args.indexOf('"plan_md"')
  if (at < 0) return null
  const colon = args.indexOf(":", at + '"plan_md"'.length)
  if (colon < 0) return null
  const quote = args.indexOf('"', colon + 1)
  if (quote < 0) return null
  let out = ""
  for (let i = quote + 1; i < args.length; i++) {
    const ch = args[i]!
    if (ch !== "\\") {
      if (ch === '"') break
      out += ch
      continue
    }
    const next = args[i + 1]
    if (next === undefined) break
    i++
    if (next === "n") out += "\n"
    else if (next === "t") out += "  "
    else if (next === "r") continue
    else if (next === "u") {
      const hex = args.slice(i + 1, i + 5)
      if (hex.length < 4) break
      const code = Number.parseInt(hex, 16)
      if (Number.isNaN(code)) break
      out += String.fromCharCode(code)
      i += 4
    } else out += next
  }
  return out
}

/** `{"recorded": "<path>"}` — what `approve` prints on stdout. */
export function recordedPath(stdout: string): string | null {
  try {
    const value = JSON.parse(stdout.trim()) as { recorded?: unknown }
    return typeof value.recorded === "string" && value.recorded.length > 0 ? value.recorded : null
  } catch {
    return null
  }
}

function clip(text: string, width: number): string {
  const flat = text.replace(/\t/g, "  ")
  return flat.length <= width ? flat : `${flat.slice(0, Math.max(1, width - 1))}…`
}

function firstLine(text: string): string {
  return text.trim().split("\n")[0] ?? ""
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
