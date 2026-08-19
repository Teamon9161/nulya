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
 */
export interface Command {
  name: string
  /** Argument shape, shown after the name while completing. */
  args?: string
  what: string
}

export const commands: Command[] = [
  { name: "/model", what: "pick the model the next session runs on" },
  { name: "/mode", args: "[ask|auto]", what: "ask before every tool call, or let them run; no argument switches" },
  { name: "/provider", what: "endpoints and their keys · add an OpenAI- or Anthropic-compatible one" },
  { name: "/effort", args: "<level|auto>", what: "change this tab's effort now; the next step runs with it" },
  { name: "/new", args: "[--profile p] [--model id]", what: "a session on the last pick, or on the named profile" },
  { name: "/sessions", what: "everything in .nulya/sessions · Enter opens one" },
  { name: "/ext", what: "extensions: versions, what is active, what it is used for" },
  { name: "/tasks", what: "background commands: what is running, its log, k stops one" },
  { name: "/usage", what: "what this session cost, and the workspace's tool-usage journal" },
  { name: "/settings", what: "the effective tui.toml values and which file each came from" },
  { name: "/compact", args: "[focus]", what: "summarise this session and continue in a new one; this file stays" },
  { name: "/outcome", args: "<verdict> [note]", what: "success | partial | failure — unjudged is not the same as failed" },
  { name: "/evolve", what: "build the evolution package and start a session wearing it" },
  { name: "/as", args: "<id>[@version]", what: "a session carrying a built extension's prompt and skills; nothing is activated" },
  { name: "/step", what: "continue after a spent step budget (nothing continues by itself)" },
  { name: "/cancel", what: "stop the running step at the kernel's next step boundary" },
  { name: "/fold", what: "collapse every card" },
  { name: "/help", what: "every key and every command" },
  { name: "/quit", what: "leave" },
]

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
