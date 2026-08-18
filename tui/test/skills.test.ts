/**
 * Skills as slash commands (tui.md §11, T15).
 *
 * The sentinel round-trip is tcode's `wrap_and_parse_skill_echo_round_trips_
 * through_special_characters` and `ordinary_user_text_is_not_mistaken_for_a_
 * skill_echo`, ported: the format is copied, so the proof that it survives
 * quotes and ampersands should be too.
 *
 * The last test runs against the real binary — a built, activated extension
 * that contributes a skill — because `skill list`'s TSV and `skill load`'s ref
 * format are the kernel's, and a change to either should fail here rather than
 * produce an empty menu.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import {
  clipDescription,
  createSkillTable,
  description_cap,
  echoSummary,
  findSkill,
  parseSkillEcho,
  skillCompletions,
  skillTurn,
  skill_echo_open,
  splitSlash,
  wrapSkillEcho,
} from "../src/skills.ts"
import { skillList, skillLoad, type SkillEntry } from "../src/nulya/cli.ts"
import { completions } from "../src/commands.ts"
import { tempWorkspace, until, type TempWorkspace } from "./support.ts"

let ws: TempWorkspace

const body = "---\nname: greeter\ndescription: say hello properly\n---\nStep one.\nStep two.\nStep three.\n"

beforeAll(() => {
  ws = tempWorkspace()
  const skill = join(ws.dir, ".nulya", "extensions", "manners", "skills", "greeter")
  mkdirSync(skill, { recursive: true })
  writeFileSync(
    join(ws.dir, ".nulya", "extensions", "manners", "extension.json"),
    JSON.stringify({
      schema: "nulya.extension/v2",
      id: "manners",
      contributes: { skills: ["skills/greeter"] },
    }),
  )
  writeFileSync(join(skill, "SKILL.md"), body)
  Bun.spawnSync({ cmd: [ws.bin, "ext", "sync", "--activate"], cwd: ws.dir, env: process.env })
})

afterAll(() => {
  ws.cleanup()
})

test("the echo sentinel round-trips through quotes and ampersands", () => {
  const wrapped = wrapSkillEcho("init", 'say "hi" & bye', "line one\nline two\nline three")
  expect(wrapped.startsWith(skill_echo_open)).toBe(true)
  const echo = parseSkillEcho(wrapped)!
  expect(echo.name).toBe("init")
  expect(echo.args).toBe('say "hi" & bye')
  expect(echo.lines).toBe(3)
  // The body is intact between the markers — the wrapper is provenance, never
  // an edit of what the kernel handed over.
  expect(wrapped).toContain("line one\nline two\nline three")
  expect(echoSummary(echo)).toBe('/init say "hi" & bye · 3 lines')
  expect(echoSummary({ name: "guide", args: "", lines: 187 })).toBe("/guide · 187 lines")
})

test("ordinary user text is not mistaken for a skill echo", () => {
  expect(parseSkillEcho("just a normal message")).toBeNull()
  expect(parseSkillEcho("")).toBeNull()
  // The shape has to be complete: a truncated open tag is not a fold.
  expect(parseSkillEcho('<user-skill name="x"')).toBeNull()
  // Live and replay call this same function on the same bytes, which is the
  // whole reason the format lives in one place.
  const wrapped = wrapSkillEcho("g", "", "one\ntwo")
  expect(parseSkillEcho(wrapped)).toEqual(parseSkillEcho(`${wrapped}`))
})

test("built-ins come first in the menu, so a skill can never take /model away", () => {
  const skills: SkillEntry[] = [
    { ref: "ext:a@v-1/model", name: "model", description: "an impostor" },
    { ref: "ext:a@v-1/guide", name: "guide", description: "how this harness describes itself" },
  ]
  const menu = [...completions("/m"), ...skillCompletions(skills, "/m")].map((c) => c.name)
  expect(menu[0]).toBe("/model")
  expect(menu.filter((name) => name === "/model")).toHaveLength(2) // the built-in, then the skill
  expect(skillCompletions(skills, "/g")).toEqual([
    { name: "/guide", what: "how this harness describes itself" },
  ])
  // Past the first word it is arguments; the exact name still explains itself.
  expect(skillCompletions(skills, "/guide now")).toHaveLength(1)
  expect(skillCompletions(skills, "/nope")).toEqual([])
  expect(skillCompletions(skills, "not a command")).toEqual([])

  expect(description_cap).toBe(100)
  expect(clipDescription("x".repeat(101))).toBe(`${"x".repeat(100)}…`)
  expect(clipDescription("short")).toBe("short")
})

test("the command word splits from its arguments, spacing and all", () => {
  expect(splitSlash("/guide")).toEqual({ name: "guide", args: "" })
  expect(splitSlash("/guide  two  words ")).toEqual({ name: "guide", args: "two  words" })
  expect(findSkill([{ ref: "r", name: "guide", description: "" }], "guide")?.ref).toBe("r")
  expect(findSkill([], "guide")).toBeNull()
})

test("a real /name loads a real skill's body; anything else stays the model's", async () => {
  const listed = await skillList(ws)
  expect(listed.map((s) => s.name)).toEqual(["greeter"])
  expect(listed[0]!.description).toBe("say hello properly")
  expect(listed[0]!.ref).toMatch(/^ext:manners@v-[0-9a-f]+\/greeter$/)
  expect(await skillLoad(ws, listed[0]!.ref)).toBe(body)

  // `/greeter here we go` → one user turn, folded back to one line.
  const turn = (await skillTurn(ws, listed, "/greeter here we go"))!
  const echo = parseSkillEcho(turn)!
  expect(echo.name).toBe("greeter")
  expect(echo.args).toBe("here we go")
  expect(turn).toContain("Step two.")
  expect(echoSummary(echo)).toBe("/greeter here we go · 7 lines")

  // A name no skill has: null, so the caller sends the line verbatim (the
  // behaviour that was there before slash skills existed).
  expect(await skillTurn(ws, listed, "/nosuchskill")).toBeNull()

  // The table is the same listing, loaded in the background.
  const table = createSkillTable(ws)
  await until(() => table.entries().length > 0, 10_000)
  expect(table.entries().map((s) => s.name)).toEqual(["greeter"])
  table.invalidate()
  expect((await table.ready()).map((s) => s.name)).toEqual(["greeter"])
})
