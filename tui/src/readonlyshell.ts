/**
 * Is this `shell` command one that only READS?
 *
 * A pure function over the command string, sitting in the approval chain
 * between `[approvals] allow` and the mode fallback. It exists for one reason:
 * in `ask` mode a person is asked about every call no rule settles, and the
 * overwhelming majority of those are `git status`, `ls`, `cat` — questions whose
 * answer was never in doubt and whose only effect is to teach the person that
 * the dialog is noise to press Enter through. Answering the boring ones here is
 * what keeps the interesting one legible.
 *
 * IT IS NOT A SECURITY BOUNDARY, and nothing here should ever be read as one.
 * The kernel's own line on this has not moved: `shell` and an extension are
 * equally privileged, and real isolation
 * waits for the sandbox. Which is exactly why the READ-ONLY
 * CEILING — the one an agent definition or a package's `contributes.policy`
 * raises — does not use this file: that ceiling refuses `shell` outright,
 * because "no OS sandbox means you cannot tell `cat foo` from `rm foo`"
 * (agents-and-review §1, invariant 5), and a string classifier does not change
 * that fact. What this decides is only "must a person be interrupted for this",
 * with the person one keystroke away and every call still on screen.
 *
 * So the whole file is written in one direction: a veto is cheap and a false
 * allow is not. Every rule is a reason to ASK, never a reason to permit, the
 * command list is closed (an unrecognised program is asked about, always), and
 * anything the parser cannot account for — an unterminated quote, a shape it
 * has no case for — is a question, not a guess.
 *
 * Two dialects, one parser. The tokenizer below is POSIX-shaped, and every
 * place where PowerShell differs, it differs by making MORE things special:
 * a backtick is PowerShell's escape character, `&` is its call operator,
 * `$(…)` is substitution in both. Each of those is an unconditional veto here,
 * so a command this file clears parses the same, and does the same, under
 * either shell.
 */

/** Why a command is not classifiable as read-only, or `null` when it is. */
export type ShellVeto = string | null

/**
 * One simple command: the words of a single segment, after quote removal.
 * `git status --short` is three words; the operators that separated it from its
 * neighbours are gone, because each segment is judged entirely on its own.
 */
type Segment = string[]

type ParseResult = { ok: true; segments: Segment[] } | { ok: false; reason: string }

const isSpace = (c: string) => c === " " || c === "\t"
const isDelimiter = (c: string) => isSpace(c) || c === "\n" || c === "\r" || c === ";" || c === "|" || c === "&"

/**
 * Split a command line into simple commands at the TOP level, quote-aware.
 *
 * Only the separators that mean "and then run this too" split: `&&`, `||`, `|`,
 * `;`, and a newline. Everything else the shell would treat as syntax — a
 * substitution, a redirection that writes, a lone `&` — ends the parse with a
 * reason instead, because a classifier that skipped over syntax it did not
 * model would be judging a different command than the one that runs.
 */
function parseCommand(command: string): ParseResult {
  const segments: Segment[] = []
  let words: Segment = []
  let word = ""
  let started = false
  // Set by `<`: the word that follows names a file to read FROM, so it is not
  // an argument to the program and must not be judged as one.
  let dropNext = false

  const pushWord = () => {
    if (!started) return
    if (dropNext) dropNext = false
    else words.push(word)
    word = ""
    started = false
  }
  const endSegment = () => {
    pushWord()
    segments.push(words)
    words = []
  }
  const take = (c: string) => {
    word += c
    started = true
  }

  let i = 0
  while (i < command.length) {
    const c = command[i]!
    const next = command[i + 1]
    // A backtick is substitution in POSIX and the escape character in
    // PowerShell. Refusing it unconditionally — quoted or not — is what lets
    // one parser speak for both shells (see the header).
    if (c === "`") return { ok: false, reason: "backtick" }
    if (c === "$" && next === "(") return { ok: false, reason: "command substitution" }
    if ((c === "<" || c === ">") && next === "(") return { ok: false, reason: "process substitution" }

    if (c === "'") {
      const end = command.indexOf("'", i + 1)
      if (end < 0) return { ok: false, reason: "unterminated quote" }
      word += command.slice(i + 1, end)
      started = true
      i = end + 1
      continue
    }
    if (c === '"') {
      i++
      let closed = false
      while (i < command.length) {
        const q = command[i]!
        if (q === "\\" && i + 1 < command.length) {
          word += command[i + 1]!
          started = true
          i += 2
          continue
        }
        if (q === "`") return { ok: false, reason: "backtick" }
        if (q === "$" && command[i + 1] === "(") return { ok: false, reason: "command substitution" }
        if (q === '"') {
          closed = true
          i++
          break
        }
        word += q
        started = true
        i++
      }
      if (!closed) return { ok: false, reason: "unterminated quote" }
      started = true
      continue
    }
    if (c === "\\") {
      if (i + 1 >= command.length) return { ok: false, reason: "trailing escape" }
      take(command[i + 1]!)
      i += 2
      continue
    }
    if (c === ">") {
      // `2>&1` is the one redirection that creates nothing: it points a stream
      // that already exists at another one. It is spelled out exactly, with the
      // `2` still sitting in the current word, and anything else that reaches a
      // `>` is a write.
      if (started && word === "2" && command.slice(i).startsWith(">&1")) {
        const after = command[i + 3]
        if (after === undefined || isDelimiter(after)) {
          word = ""
          started = false
          i += 3
          continue
        }
      }
      return { ok: false, reason: "output redirection" }
    }
    if (c === "<") {
      pushWord()
      dropNext = true
      i++
      continue
    }
    if (c === "&") {
      if (next === "&") {
        endSegment()
        i += 2
        continue
      }
      // `&>` writes; a lone `&` backgrounds a job in POSIX and CALLS a program
      // in PowerShell. Neither is a shape this file has a case for.
      return { ok: false, reason: next === ">" ? "output redirection" : "unsupported `&`" }
    }
    if (c === "|") {
      if (next === "&") return { ok: false, reason: "unsupported `|&`" }
      endSegment()
      i += next === "|" ? 2 : 1
      continue
    }
    if (c === ";") {
      endSegment()
      i++
      continue
    }
    if (c === "\n" || c === "\r") {
      endSegment()
      i++
      continue
    }
    if (isSpace(c)) {
      pushWord()
      i++
      continue
    }
    take(c)
    i++
  }
  endSegment()

  const real = segments.filter((s) => s.length > 0)
  if (real.length === 0) return { ok: false, reason: "no command" }
  return { ok: true, segments: real }
}

/**
 * Programs that run OTHER programs. Vetoed by name wherever they appear, and
 * kept as their own list rather than simply being left off the allow list,
 * because `[approvals] readonly_commands` can add entries and this is the rule
 * those additions are still measured against (nobody gets to allow `sh -c`).
 */
const wrappers = new Set([
  "eval", "exec", "source", ".",
  "sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "ash",
  "pwsh", "powershell", "cmd", "command", "start",
  "xargs", "sudo", "doas", "su", "runas",
  "nohup", "setsid", "nice", "timeout", "time", "watch", "script",
  "ssh", "scp", "docker", "make", "npm", "npx", "bunx", "yarn", "pnpm",
])

/**
 * Commands whose whole argument list is data, not a program.
 *
 * `sed` and `awk` are deliberately NOT here, and the reason is the same for
 * both: their operand is a program in another language, and that language can
 * write files (`sed`'s `w`, awk's `print > f`) and run commands (GNU `s///e`,
 * awk's `system()`). No flag-level check makes that sound — `sed -i` is only
 * the most visible of several ways out — and classifying a program in another
 * language is not what a command classifier does. `find` stays because its
 * dangerous verbs are FLAGS, which is exactly the thing this file can see.
 * Somebody who wants `sed -n` waved through can say so in
 * `[approvals] readonly_commands`, and that is their decision to make.
 */
const plain = new Set([
  "ls", "dir", "pwd", "cat", "type", "head", "tail", "wc", "which", "where",
  "echo", "tree", "file", "stat", "du", "df", "date", "whoami", "hostname",
  "printenv", "basename", "dirname", "realpath", "uname", "id", "uptime",
  "grep", "diff", "cmp", "md5sum", "sha256sum", "cksum", "column", "nl", "rev", "seq",
])

/** Version and environment queries, for tools that answer them and nothing else. */
const version_tools = new Set([
  "zig", "bun", "node", "deno", "python", "python3", "cargo", "rustc", "go",
  "tsc", "java", "dotnet", "gcc", "clang", "ruby", "perl", "php", "curl", "rg", "fd", "jq",
])
const version_args = new Set(["--version", "-v", "-V", "version", "env", "--help", "-h", "help"])

/** `git <verb>` where the verb only reads, with the flags that make it write vetoed. */
const git_readonly = new Set([
  "status", "diff", "log", "show", "blame", "rev-parse", "ls-files", "ls-remote",
  "describe", "shortlog", "cat-file", "rev-list", "whatchanged", "grep", "show-ref",
])

/**
 * `git branch` with only these is a listing. Everything else — a bare operand
 * included, since `git branch <name>` CREATES one — sends it to the person.
 */
const git_branch_flags = new Set([
  "-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose", "-l", "--list",
  "--merged", "--no-merged", "--contains", "--no-contains", "--show-current",
  "--sort", "--format", "--color", "--no-color", "-i", "--ignore-case",
])

/** `nulya <verb…>` that only projects what is already on disk. */
const nulya_readonly: string[][] = [
  ["help"], ["config", "show"], ["ext", "list"], ["ext", "inspect"], ["ext", "api"],
  ["session", "list"], ["session", "events"], ["task", "list"], ["task", "status"],
  ["skill", "list"], ["skill", "load"], ["src"],
]

const isAssignment = (word: string) => /^[A-Za-z_][A-Za-z0-9_]*=/.test(word)
const isAbsolute = (word: string) => /^([A-Za-z]:[\\/]|[\\/])/.test(word)
const hasSeparator = (word: string) => word.includes("/") || word.includes("\\")

/**
 * The program a segment names, or null when this file will not guess.
 *
 * A bare name (`ls`) is itself; an ABSOLUTE path is read by its basename, minus
 * a `.exe`, because that is how the model spells `$NULYA_EXE`. A RELATIVE path
 * is refused outright: `./ls` is a file in the workspace, and the whole premise
 * of a name-based allow list is that the name says which program runs.
 */
function programOf(word: string): string | null {
  if (!hasSeparator(word)) return word.toLowerCase().replace(/\.exe$/, "")
  if (!isAbsolute(word)) return null
  const base = word.split(/[\\/]/).pop() ?? ""
  return base.length === 0 ? null : base.toLowerCase().replace(/\.exe$/, "")
}

function classifyGit(args: string[]): ShellVeto {
  let at = 0
  // Top-level flags before the verb. `-c` is a configuration injection point
  // (`git -c core.fsmonitor=… status` runs a program of the caller's choosing),
  // and `--exec-path` moves the whole toolset; both are vetoed by not being on
  // this list, which is why the list is what it is rather than a denylist.
  while (at < args.length && args[at]!.startsWith("-")) {
    const flag = args[at]!
    if (flag === "--no-pager" || flag === "-P" || flag === "--paginate") {
      at++
      continue
    }
    if (flag === "-C") {
      at += 2
      continue
    }
    return `git ${flag}`
  }
  const verb = args[at]
  if (verb === undefined) return "bare git"
  const rest = args.slice(at + 1)
  if (git_readonly.has(verb)) {
    // `git diff --output=<file>` is the one read-only-looking verb that writes.
    if (rest.some((a) => a === "--output" || a.startsWith("--output="))) return "git --output"
    return null
  }
  if (verb === "branch") {
    for (const arg of rest) {
      if (!arg.startsWith("-")) return "git branch operand"
      const name = arg.split("=")[0]!
      if (!git_branch_flags.has(name)) return `git branch ${name}`
    }
    return null
  }
  if (verb === "remote") {
    if (rest.length === 0) return null
    if (rest[0] === "-v" || rest[0] === "--verbose") return rest.length === 1 ? null : "git remote"
    if (rest[0] === "show" || rest[0] === "get-url") return null
    return "git remote"
  }
  if (verb === "stash") {
    return rest[0] === "list" || rest[0] === "show" ? null : "git stash"
  }
  if (verb === "tag") {
    if (rest.length === 0) return null
    // `-l <pattern>` lists; a bare operand creates a tag.
    if (rest[0] === "-l" || rest[0] === "--list") return null
    return "git tag"
  }
  return `git ${verb}`
}

function classifyNulya(args: string[]): ShellVeto {
  for (const verbs of nulya_readonly) {
    if (verbs.every((verb, at) => args[at] === verb)) return null
  }
  return `nulya ${args[0] ?? ""}`.trim()
}

/** One simple command, judged on its own. Returns a reason, or null for read-only. */
function classifySegment(words: Segment, extra: readonly string[]): ShellVeto {
  const first = words[0]!
  if (isAssignment(first)) return "environment assignment"
  const program = programOf(first)
  if (program === null) return "relative path"
  const args = words.slice(1)
  // Before everything, including the person's own additions: a wrapper's whole
  // job is to run something this file never saw.
  if (wrappers.has(program)) return program
  // `env` alone prints the environment; `env FOO=x cmd` is a wrapper.
  if (program === "env") return args.length === 0 ? null : "env with arguments"

  for (const entry of extra) {
    const prefix = entry.trim()
    if (prefix.length === 0) continue
    const line = words.join(" ")
    if (line === prefix || line.startsWith(`${prefix} `)) return null
  }

  if (plain.has(program)) return null
  if (program === "git") return classifyGit(args)
  if (program === "nulya") return classifyNulya(args)
  if (program === "find") {
    const acts = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fls", "-fprint", "-fprint0", "-fprintf"]
    const found = args.find((a) => acts.includes(a))
    return found === undefined ? null : `find ${found}`
  }
  if (program === "sort") {
    const found = args.find((a) => a === "-o" || a === "--output" || a.startsWith("--output="))
    return found === undefined ? null : "sort -o"
  }
  if (program === "rg") {
    // `--pre` and `-z` hand ripgrep a decompressor or a preprocessor to run.
    const found = args.find(
      (a) => a === "--pre" || a.startsWith("--pre=") || a === "--hostname-bin" || a === "-z" || a === "--search-zip",
    )
    return found === undefined ? null : `rg ${found}`
  }
  if (program === "fd") {
    const found = args.find((a) => a === "-x" || a === "--exec" || a === "-X" || a === "--exec-batch")
    return found === undefined ? null : `fd ${found}`
  }
  if (version_tools.has(program)) {
    if (args.length === 0) return `bare ${program}`
    if (args.length === 1 && version_args.has(args[0]!)) return null
    if (args.length === 2 && program === "go" && args[0] === "env") return null
    return `${program} ${args[0]}`
  }
  return program
}

/**
 * The whole command, judged. `null` means every segment of it only reads.
 *
 * Every segment must clear: `git status && rm -rf .` is two commands, and the
 * first one being harmless says nothing at all about the second.
 */
export function classifyShellCommand(command: string, extra: readonly string[] = []): ShellVeto {
  const parsed = parseCommand(command)
  if (!parsed.ok) return parsed.reason
  for (const segment of parsed.segments) {
    const veto = classifySegment(segment, extra)
    if (veto !== null) return veto
  }
  return null
}

export function isReadOnlyShellCommand(command: string, extra: readonly string[] = []): boolean {
  return classifyShellCommand(command, extra) === null
}
