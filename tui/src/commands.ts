/**
 * The slash commands, once.
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
 * its own.
 *
 * The built-ins are tried first, so a skill can never take `/model` away.
 *
 * Three names dispatch without being listed: `/as` (an older name for
 * `/with`), `/resume` (the word other harnesses use for what `/sessions`
 * does) and `/exit` (theirs for `/quit`). None is on the table, because a
 * command in this table is a command this front end says exists, and each of
 * these would put a second word on the table for a concept that already has
 * one.
 *
 * `/clear` and `/new` disagree about the TAB, which is exactly what somebody
 * typing `/clear` from another harness is asking for: `/new` opens a second
 * tab and leaves the front one exactly as it was, while `/clear` replaces the
 * front tab's own display with a fresh draft, in place — same slot, same
 * directory, and the session that was there (if any) keeps its file and stays
 * one `/sessions` away. Two words, two things, so `/clear` is listed rather
 * than aliased.
 *
 * They ARE completed, though (`alias_commands`), and that is not a
 * contradiction: not listing is about what this front end advertises, and
 * completing is about answering somebody who has already typed four characters
 * of a word they know from somewhere else. The menu row says where the word
 * goes, so the concept still has one name and the typist still gets an answer.
 *
 * `/evolve` is not an alias and it is not reserved: the evolution package
 * declares it (`contributes.commands`), so it arrives through the package
 * chain like `/ask` — which means it exists exactly
 * when that package is built and active on this machine, and `/ext` is where it
 * comes from. A name reserved here could never have fired.
 */
export interface Command {
  name: string
  /** Argument shape, shown after the name while completing. */
  args?: string
  what: string
}

export const commands: Command[] = [
  { name: "/model", what: "pick the model this conversation runs on" },
  {
    name: "/mode",
    args: "[ask|unsafe]",
    what: "ask before every tool call, or run them all unreviewed; no argument opens the picker",
  },
  { name: "/provider", what: "endpoints and their keys · add an OpenAI- or Anthropic-compatible one" },
  { name: "/effort", args: "<level|auto>", what: "change this tab's effort now; the next step runs with it" },
  {
    name: "/env",
    args: "[<target>]",
    what:
      "where the next session's shell runs: local | wsl | wsl:<distro> · no argument lists what this machine can reach · only shell moves, this harness stays here",
  },
  {
    name: "/new",
    args: "[--profile p] [--model id]",
    what: "a SECOND tab, on the last pick or the named profile — this tab is untouched",
  },
  {
    name: "/clear",
    args: "[--profile p] [--model id]",
    what: "replace THIS tab with a fresh draft, in place — the old session's file stays on disk",
  },
  {
    name: "/sessions",
    args: "[<id>]",
    what: "everything in .nulya/sessions · Enter opens one · an id opens that one · `/resume` is another name for it",
  },
  {
    name: "/cwd",
    args: "[<path>]",
    what: "which directory this tab works in · no argument opens the browser · `no project` needs none",
  },
  {
    name: "/sidebar",
    args: "[<percent>]",
    what: "the session list, docked down the left edge · a number sets its width",
  },
  { name: "/ext", what: "extensions: versions, what is active, what it is used for" },
  { name: "/tasks", what: "background commands: what is running, its log, k stops one" },
  { name: "/usage", what: "what this session cost, and the workspace's tool-usage journal" },
  { name: "/context", what: "how full the window is, and what is filling it" },
  { name: "/settings", what: "the effective tui.toml values and which file each came from" },
  { name: "/outcome", args: "<verdict> [note]", what: "success | partial | failure — unjudged is not the same as failed" },
  {
    name: "/with",
    args: "[<id>[@version]]",
    what: "a new tab carrying a registered extension's prompt and skills; nothing is activated. no argument lists what is registered (`/as` is the old name)",
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
 * three in this file's header, in one place a reader can check the claim
 * against.
 *
 * `ui/App.tsx` decides what each one does (`/resume` shares its branch with
 * `/sessions`, `/as` with `/with`), but the RESERVATION belongs here: an alias
 * is dispatched before a package command is even looked up, so a package
 * allowed to claim `/resume` would register a command that could never fire.
 * Which is exactly why `/evolve` left this table when the evolution package
 * started declaring it.
 */
export const aliases: Readonly<Record<string, string>> = {
  as: "/with",
  exit: "/quit",
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
    const exact = all_commands.find((command) => command.name === head)
    return exact ? [exact] : []
  }
  return all_commands.filter((command) => command.name.startsWith(head))
}

/**
 * The aliases as completions: offered, but never LISTED.
 *
 * The distinction the table's header draws still holds — `/help` and the
 * command table name one word per concept, and `/resume` would advertise a
 * second name for `/sessions`. But refusing to complete them made a different claim:
 * somebody typing `/res` from muscle memory got an empty menu, which is what
 * this front end says when a command does not exist, and the honest answer is
 * that it does and it is spelled `/sessions`. So an alias only shows up once
 * somebody has started typing it, and what it says is where it goes.
 *
 * Behind the listed names on purpose: `/e` offers `/effort` before `/exit`,
 * because the first is the concept and the second is a courtesy.
 */
const alias_commands: Command[] = Object.entries(aliases)
  .map(([name, target]) => ({ name: `/${name}`, what: `another name for ${target}` }))
  .sort((a, b) => a.name.localeCompare(b.name))

const all_commands: Command[] = [...commands, ...alias_commands]
