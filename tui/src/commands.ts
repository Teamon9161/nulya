/**
 * The slash commands, once (tui.md §4.4).
 *
 * `App.runCommand` dispatches them, the composer completes them and `/help`
 * lists them; all three read this table, so a command cannot exist without
 * being discoverable, and the help cannot describe one that is gone.
 *
 * Anything typed after `/` that is not here is offered to the skill catalog
 * next (`skills.ts`), and only then goes to the model verbatim. A `/name` that
 * names a skill loads that skill's body as a user turn — the same thing the
 * model can already do with `nulya skill load`, one round trip cheaper, with a
 * person as the one who decided. That is prompt sugar, not front-end
 * intelligence: nothing here chooses a skill, rewrites one, or triggers one on
 * its own (goals/tui-panel.md D8; this table's earlier "nulya has no slash
 * skills" mistook "who triggers" for "who judges").
 *
 * The built-ins are tried first, so a skill can never take `/model` away.
 *
 * Four names dispatch without being listed: `/as` (what `/with` was called
 * until T36), `/evolve` (which rebuilds the shipped evolution draft before
 * wearing it), `/clear` (the word other harnesses use for what `/new` does) and
 * `/resume` (theirs for what `/sessions` does). All four keep working; none is
 * offered, because a command in this table is a command this front end says
 * exists — `/evolve` named ONE package whether or not this machine had it (the
 * confusion T37 set out to end), and the other two would each put a second word
 * on the table for a concept that already has one. `/clear` would also name the
 * one thing that never happens here: a ledger is append-only, nothing is
 * cleared, and a new session is a new session (physics #1, #4).
 */
export interface Command {
  name: string
  /** Argument shape, shown after the name while completing. */
  args?: string
  what: string
}

export const commands: Command[] = [
  { name: "/model", what: "pick the model the next session runs on" },
  {
    name: "/mode",
    args: "[ask|unsafe]",
    what: "ask before every tool call, or run them all unreviewed; no argument opens the picker",
  },
  { name: "/provider", what: "endpoints and their keys · add an OpenAI- or Anthropic-compatible one" },
  { name: "/effort", args: "<level|auto>", what: "change this tab's effort now; the next step runs with it" },
  {
    name: "/new",
    args: "[--profile p] [--model id]",
    what: "a session on the last pick, or on the named profile · `/clear` is another name for it",
  },
  {
    name: "/sessions",
    args: "[<id>]",
    what: "everything in .nulya/sessions · Enter opens one · an id opens that one · `/resume` is another name for it",
  },
  { name: "/ext", what: "extensions: versions, what is active, what it is used for" },
  { name: "/tasks", what: "background commands: what is running, its log, k stops one" },
  { name: "/usage", what: "what this session cost, and the workspace's tool-usage journal" },
  { name: "/settings", what: "the effective tui.toml values and which file each came from" },
  { name: "/compact", args: "[focus]", what: "summarise this session and continue in a new one; this file stays" },
  { name: "/outcome", args: "<verdict> [note]", what: "success | partial | failure — unjudged is not the same as failed" },
  {
    name: "/with",
    args: "[<id>[@version]]",
    what: "a new tab carrying a registered extension's prompt and skills; nothing is activated. no argument lists what is registered (`/as` is the old name; `/evolve` still rebuilds and wears the shipped evolution package)",
  },
  {
    name: "/agent",
    args: "[<name> <task…>]",
    what: "delegate a task to an agent defined in .nulya/agents or ~/.nulya/agents: a session of its own, in its own tab, whose report comes back here. no name lists them",
  },
  { name: "/step", what: "continue after a spent step budget (nothing continues by itself)" },
  { name: "/cancel", what: "stop the running step at the kernel's next step boundary" },
  { name: "/fold", what: "collapse every card" },
  { name: "/help", what: "every key and every command" },
  { name: "/quit", what: "leave" },
]

/**
 * The names that dispatch but are NOT on the table, and what each one is — the
 * four in this file's header, in one place a reader can check the claim
 * against.
 *
 * `ui/App.tsx` decides what each one does (`/resume` shares its branch with
 * `/sessions`, `/clear` with `/new`; `/as` and `/evolve` have their own), but
 * the RESERVATION belongs here: an alias is dispatched before a package command
 * is even looked up, so a package allowed to claim `/clear` would register a
 * command that could never fire.
 */
export const aliases: Readonly<Record<string, string>> = {
  as: "/with",
  evolve: "/with, on the shipped evolution package",
  clear: "/new",
  resume: "/sessions",
}

/**
 * Built-in command names, bare (no leading `/`) — what `packageCommands.ts`
 * checks a package command against so a built-in can never be shadowed (D8).
 * The aliases are in it for the same reason the listed names are: this front
 * end answers them, so nothing else may claim them.
 */
export const builtin_names: ReadonlySet<string> = new Set([
  ...commands.map((command) => command.name.slice(1)),
  ...Object.keys(aliases),
])

/**
 * The commands `text` could still become, best first.
 *
 * Only a first word is completed: once there is a space the person is typing
 * arguments, and a menu over their argument is noise. An exact name still
 * matches so the line explaining what Enter is about to do stays up.
 */
export function completions(text: string): Command[] {
  if (!text.startsWith("/")) return []
  const head = text.split(/\s/)[0] ?? text
  if (head.length < text.length) {
    const exact = commands.find((command) => command.name === head)
    return exact ? [exact] : []
  }
  return commands.filter((command) => command.name.startsWith(head))
}
