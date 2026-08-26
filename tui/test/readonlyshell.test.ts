/**
 * The read-only command classifier (tui.md §11, T65) — a pure function, so the
 * whole of it is a table.
 *
 * Every case here is written in the one direction the file is written in: a
 * veto is cheap and a false allow is not. So the `asks` table is the load-
 * bearing half, and each of its rows is a way a command line can reach out past
 * itself; the `allows` half exists to keep the feature from being a very
 * elaborate way of always asking.
 */
import { describe, expect, test } from "bun:test"
import { classifyShellCommand, isReadOnlyShellCommand } from "../src/readonlyshell.ts"

const readOnly = (command: string, extra: string[] = []) => isReadOnlyShellCommand(command, extra)

describe("commands that only read", () => {
  const allows = [
    "ls",
    "ls -la src",
    "pwd",
    "cat README.md",
    "head -n 40 build.zig",
    "wc -l src/*.zig",
    "grep -rn TODO src",
    "rg --files-with-matches gate",
    "fd -e zig",
    "echo hello",
    "which zig",
    "date",
    "du -sh .",
    "tree -L 2",
    "find . -name '*.zig'",
    "sort names.txt",
    "git status",
    "git status --short",
    "git diff HEAD~1",
    "git log --oneline -20",
    "git show abc123",
    "git rev-parse --abbrev-ref HEAD",
    "git ls-files",
    "git branch -a",
    "git branch --show-current",
    "git remote -v",
    "git stash list",
    "git tag -l 'v0.*'",
    "git --no-pager log -1",
    "git -C tui status",
    "nulya help",
    "nulya config show --json",
    "nulya ext list",
    "nulya ext inspect std",
    "nulya session list --json",
    "nulya session events s-1-a",
    "nulya task list --json",
    "nulya skill load guide",
    "nulya src loop.zig",
    "zig version",
    "zig env",
    "bun --version",
    "node --version",
    // The compound forms, when every segment clears.
    "git status && git log --oneline -5",
    "cat build.zig | grep addTest",
    "ls; pwd",
    "grep -rn foo src 2>&1",
    "wc -l < build.zig",
  ]
  for (const command of allows) {
    test(command, () => expect(classifyShellCommand(command)).toBeNull())
  }
})

describe("commands that go to a person", () => {
  const asks: [string, string][] = [
    // Every veto vector, one row each.
    ["git status && rm -rf .", "one clean segment says nothing about the next"],
    ["git status; rm -rf .", "`;` splits too"],
    ["ls || rm -rf .", "so does `||`"],
    ["cat x | sh", "and a pipe"],
    ["ls\nrm -rf .", "and a newline"],
    ["git -c core.fsmonitor=calc status", "`-c` hands git a program to run"],
    ["git --exec-path=/tmp/evil status", "so does moving the toolset"],
    ["find . -exec rm {} \\;", "find's actions are the dangerous half"],
    ["find . -delete", "including the one with no command in it"],
    ["find . -fprint out.txt", "…and the ones that write a file"],
    ["ls `whoami`", "a backtick: substitution in POSIX, escape in PowerShell"],
    ["echo `date`", "quoted or not, it is refused"],
    ["cat $(which zig)", "command substitution"],
    ['echo "$(rm -rf .)"', "including inside double quotes"],
    ["diff <(ls a) <(ls b)", "process substitution"],
    ["ls > file", "output redirection"],
    ["ls >> file", "appending is still writing"],
    ["echo hi 2> err.log", "a numbered stream still writes a file"],
    ["ls &> out", "`&>` too"],
    ["cat 'unterminated", "an unterminated quote is a parse this file will not guess at"],
    ['cat "still open', "either quote"],
    ["FOO=bar ls", "an environment prefix is a program run in an environment nobody read"],
    ["eval 'ls'", "eval"],
    ["exec ls", "exec"],
    ["sh -c 'ls'", "a shell wrapper"],
    ["bash -c ls", "any shell"],
    ["xargs rm", "xargs runs what it is fed"],
    ["env FOO=1 ls", "env with arguments is a wrapper"],
    ["sudo ls", "and so is sudo"],
    ["ls &", "a lone `&` backgrounds in POSIX and calls in PowerShell"],
    // The closed list: not recognised is not allowed.
    ["rm -rf build", "not on the list"],
    ["zig build test", "a build is not a read"],
    ["curl https://example.com", "network"],
    ["./ls", "a relative path is a file in the workspace, not a program name"],
    ["sed -i 's/a/b/' f", "sed is not on the list at all"],
    ["awk '{system(\"rm -rf .\")}'", "nor awk"],
    ["sort -o out.txt in.txt", "sort writes with -o"],
    ["rg --pre ./run.sh foo", "ripgrep's preprocessor runs a program"],
    ["fd -x rm", "so does fd's --exec"],
    ["git branch -D old", "deleting a branch"],
    ["git branch new-thing", "a bare operand CREATES a branch"],
    ["git stash pop", "stash's other verbs change the tree"],
    ["git tag v1.0", "tagging"],
    ["git diff --output=out.diff", "the one read-only-looking verb that writes"],
    ["git commit -m x", "a verb that is not on the list"],
    ["nulya ext build extensions/std", "a nulya verb that is not a projection"],
    ["nulya session step s-1-a", "least of all this one"],
    ["nulya demo", "it runs a model"],
    ["", "nothing to judge"],
  ]
  for (const [command, why] of asks) {
    test(`${JSON.stringify(command)} — ${why}`, () => expect(classifyShellCommand(command)).not.toBeNull())
  }
})

/**
 * The additions in `[approvals] readonly_commands`: they widen the list of
 * programs, and nothing else. Every veto the parser makes is about the SHAPE of
 * the line, and no entry can spend that.
 */
test("an added entry is a whole-word prefix, still under every veto", () => {
  const extra = ["cargo tree", "kubectl get"]
  expect(readOnly("cargo tree", extra)).toBe(true)
  expect(readOnly("cargo tree --depth 1", extra)).toBe(true)
  expect(readOnly("kubectl get pods", extra)).toBe(true)
  // Not a string prefix: a longer word is a different command.
  expect(readOnly("cargo treeify", extra)).toBe(false)
  // Not the whole command line either: the entry matches one simple command.
  expect(readOnly("cargo tree && rm -rf .", extra)).toBe(false)
  expect(readOnly("cargo tree > deps.txt", extra)).toBe(false)
  expect(readOnly("cargo tree $(whoami)", extra)).toBe(false)
  // And a wrapper is still a wrapper, however it was added.
  expect(readOnly("sh -c ls", ["sh -c"])).toBe(false)
  expect(readOnly("FOO=1 cargo tree", extra)).toBe(false)
  // Without the entry it is an unrecognised program, as everything is.
  expect(readOnly("cargo tree")).toBe(false)
})

/**
 * Quoting is the reason this needs a tokenizer rather than a regex: an operator
 * inside quotes is a character, and a character outside them is an operator.
 */
test("quotes hide operators, and only inside themselves", () => {
  expect(readOnly("grep -rn 'a && b' src")).toBe(true)
  expect(readOnly('grep -rn "a; b" src')).toBe(true)
  expect(readOnly("grep -rn 'a > b' src")).toBe(true)
  expect(readOnly("grep -rn a src && rm -rf .")).toBe(false)
  expect(readOnly("grep -rn 'a' src > out")).toBe(false)
})

/**
 * `2>&1` points a stream that already exists at another one — it creates
 * nothing, which is the whole reason it is the single exception to "a `>` is a
 * write". It is spelled out exactly.
 */
test("2>&1 is the one redirection that makes nothing", () => {
  expect(readOnly("git status 2>&1")).toBe(true)
  expect(readOnly("git status 2>&1 | grep modified")).toBe(true)
  expect(readOnly("git status 2>&1x")).toBe(false)
  expect(readOnly("git status 2>&2")).toBe(false)
  expect(readOnly("git status 1>&2")).toBe(false)
})
