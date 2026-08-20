/**
 * The `ask` package's front end (goals/tui-plugin.md D13, contract in
 * `tui/plugin-api.d.ts`).
 *
 * One panel. When an `ask` call is recorded, the question and its options appear
 * above the composer; a number moves the cursor, `Enter` answers, and the answer
 * goes back the one way a plugin can speak — `appendNote`, which is
 * `session append` with a sentinel, which is what the person typing the same
 * words by hand would have produced.
 *
 * ── WHAT THIS IS WORTH ────────────────────────────────────────────────────
 *
 * Almost nothing, and that is the point of it being the second consumer. The
 * question is in the ledger the moment the call is recorded, so a front end with
 * no plugin — or a headless driver — already shows it and already has an answer
 * channel: a person types. This module only turns "read the card, type the
 * option you want" into one keystroke. If it fails to load, if the API version
 * is wrong, if the package is not activated, the conversation still works. A
 * plugin that is a convenience over a floor the ledger already provides is the
 * shape the whole design is aiming at (D1).
 *
 * ── NO CARD, ON PURPOSE ───────────────────────────────────────────────────
 *
 * The ordinary extension card already draws `ask`'s arguments, and a question is
 * a short JSON object that reads perfectly well as one. Registering a card here
 * would be decoration, and it would put the question on screen twice while the
 * panel is up.
 */
import type { Line, PluginApi, PluginKey } from "nulya-tui/plugin-api"

/** At most this many option rows before the list pages under the cursor. */
const page_rows = 8

export interface Question {
  call: string
  text: string
  options: string[]
  freeText: boolean
}

export function activate(api: PluginApi): void {
  let question: Question | null = null
  let cursor = 0
  let top = 0
  /** An answer being typed, or null while the list has the keys. */
  let draft: string | null = null
  let status = ""
  /** The `ask` call this run is waiting to see finish. */
  let awaiting: string | null = null

  const panel = api.registerPanel({
    render: renderPanel,
    onKey,
    onClose() {
      draft = null
    },
  })

  api.observe.onEvent((event) => {
    if (event.kind !== "assistant") return
    const calls = event["calls"]
    if (!Array.isArray(calls)) return
    for (const raw of calls) {
      const call = raw as { id?: unknown; tool?: unknown; args?: unknown }
      if (call.tool !== "ask") continue
      const asked = questionOf(typeof call.args === "string" ? call.args : "")
      if (asked === null) continue
      adopt(typeof call.id === "string" ? call.id : "", asked)
    }
  })

  api.observe.onStream((line) => {
    if (line.stream !== "tool") return
    if (line.event === "begin") {
      const call = line["call_id"]
      if (line["tool"] === "ask" && typeof call === "string") awaiting = call
      return
    }
    if (line.event !== "end") return
    const call = line["call_id"]
    if (typeof call !== "string" || call !== awaiting) return
    awaiting = null
    if (!question) return
    panel.open()
  })

  function adopt(call: string, asked: Omit<Question, "call">): void {
    question = { call, ...asked }
    cursor = 0
    top = 0
    status = ""
    // An open question has nothing to choose between, so the panel is a text
    // field from the start rather than an empty list with a hint under it.
    draft = asked.options.length === 0 ? "" : null
  }

  api.registerCommand({
    name: "ask-review",
    description: "answer the question this session asked",
    run() {
      if (!question) {
        api.notice("ask: nothing has been asked in this run")
        return
      }
      panel.open()
    },
  })

  // ── The panel ────────────────────────────────────────────────────────────

  /** The rows the list offers: the options, then "something else" when invited. */
  function choices(): string[] {
    if (!question) return []
    return question.freeText ? [...question.options, "something else — type it"] : question.options
  }

  function renderPanel(width: number): Line[] {
    if (!question) return [[{ text: "nothing has been asked", token: "dim" }]]

    const out: Line[] = []
    for (const row of wrap(question.text, Math.max(16, width - 2))) {
      out.push([{ text: row, token: "fg" }])
    }

    if (draft !== null) {
      out.push([
        { text: "› ", token: "accent.user" },
        { text: draft.length > 0 ? draft : "type your answer", token: draft.length > 0 ? "fg" : "faint" },
      ])
      out.push([
        {
          text: (question.options.length > 0 ? "Enter send · Esc back to the options" : "Enter send · Esc close"),
          token: "faint",
        },
      ])
      return out
    }

    const rows = choices()
    const first = Math.min(top, Math.max(0, rows.length - 1))
    const last = Math.min(first + page_rows, rows.length)
    for (let at = first; at < last; at++) {
      out.push([
        { text: at === cursor ? "› " : "  ", token: "accent.user" },
        { text: `${at + 1}. `, token: "faint" },
        { text: clip(rows[at] ?? "", Math.max(8, width - 6)), token: at === cursor ? "fg" : "dim" },
      ])
    }
    if (rows.length > last) out.push([{ text: `  … ${rows.length - last} more`, token: "faint" }])
    out.push([
      {
        text: status.length > 0 ? status : "↑↓/j/k move · 1-9 pick · Enter answer · t type · Esc close",
        token: status.length > 0 ? "warn" : "dim",
      },
    ])
    return out
  }

  function move(by: number): void {
    const rows = choices()
    if (rows.length === 0) return
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + by))
    if (cursor < top) top = cursor
    if (cursor >= top + page_rows) top = cursor - page_rows + 1
    top = Math.max(0, Math.min(top, Math.max(0, rows.length - page_rows)))
  }

  function onKey(key: PluginKey): boolean {
    if (!question) return false

    if (draft !== null) {
      if (key.name === "escape") {
        // Back to the list when there is one; otherwise let the host close, so
        // an open question is never a panel with no way out but an answer.
        if (question.options.length === 0) return false
        draft = null
        return true
      }
      if (key.name === "return") {
        const text = draft.trim()
        if (text.length === 0) {
          status = "nothing typed"
          return true
        }
        answer(text)
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

    const rows = choices()
    if (key.name.length === 1 && key.name >= "1" && key.name <= "9") {
      const at = Number(key.name) - 1
      if (at < rows.length) {
        cursor = at
        if (cursor < top) top = cursor
        if (cursor >= top + page_rows) top = cursor - page_rows + 1
      }
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
      case "t":
        draft = ""
        return true
      case "return": {
        const picked = rows[cursor]
        if (picked === undefined) return true
        // The last row of a free-text question is not an answer, it is the
        // invitation to write one.
        if (question.freeText && cursor === rows.length - 1) {
          draft = ""
          return true
        }
        answer(picked)
        return true
      }
      default:
        return false
    }
  }

  /**
   * The answer, as a user turn.
   *
   * Wrapped in the plugin sentinel by the host, so the transcript folds it back
   * to exactly these words with the package's name on it — the model reads that
   * this came from the person through `ask`, which is what makes it an answer
   * rather than a new instruction arriving out of nowhere.
   */
  function answer(text: string): void {
    if (!question) return
    const asked = question.text
    question = null
    draft = null
    panel.close()
    void api.actions
      .appendNote("answer", `${text}\n\n(in answer to: ${asked})`)
      .then(() => api.notice(`ask: answered · ${clip(text, 60)}`))
      .catch((error: unknown) => api.notice(`ask: could not send the answer · ${messageOf(error)}`))
  }
}

// ── Pure helpers ───────────────────────────────────────────────────────────

/** An `ask` call's arguments, or null when there is no question in them. */
export function questionOf(args: string): Omit<Question, "call"> | null {
  let value: { question?: unknown; options?: unknown; free_text?: unknown }
  try {
    value = JSON.parse(args) as typeof value
  } catch {
    // Half-arrived arguments are not a question yet; the panel opens on the
    // call's END, so there is always a complete object by then.
    return null
  }
  if (typeof value.question !== "string" || value.question.trim().length === 0) return null
  const options = Array.isArray(value.options)
    ? value.options.filter((one): one is string => typeof one === "string" && one.trim().length > 0)
    : []
  return {
    text: value.question.trim(),
    options,
    // No options at all always means an answer in their own words; the flag only
    // says whether one is welcome ALONGSIDE a list.
    freeText: options.length === 0 || value.free_text === true,
  }
}

/** Break a question across rows the panel can draw, on word boundaries. */
export function wrap(text: string, width: number): string[] {
  const out: string[] = []
  for (const paragraph of text.replace(/\r\n/g, "\n").split("\n")) {
    let row = ""
    for (const word of paragraph.split(/\s+/).filter((one) => one.length > 0)) {
      if (row.length === 0) {
        row = word
      } else if (row.length + 1 + word.length <= width) {
        row = `${row} ${word}`
      } else {
        out.push(row)
        row = word
      }
      while (row.length > width) {
        out.push(row.slice(0, width))
        row = row.slice(width)
      }
    }
    out.push(row)
  }
  return out.length > 0 ? out : [""]
}

function clip(text: string, width: number): string {
  const flat = text.replace(/[\t\n]/g, " ")
  return flat.length <= width ? flat : `${flat.slice(0, Math.max(1, width - 1))}…`
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
