/** Pure package policy for the compact TUI plugin. */
import { describe, expect, test } from "bun:test"
import {
  activate,
  briefOf,
  compactResult,
  requestMarker,
  summaryMarker,
  withoutMarker,
} from "../../extensions/compact/tui/compact.ts"
import type {
  CommandSpec,
  ExtRunResult,
  LedgerEventView,
  PanelSpec,
  PluginApi,
  SessionView,
} from "nulya-tui/plugin-api"

test("compact markers remain package-owned and strip without losing their body", () => {
  const request = `${requestMarker}\n# Context compaction\n\nWrite a brief.`
  const summary = `${summaryMarker}\n## Task\nship it`
  expect(withoutMarker(request)).toContain("# Context compaction")
  expect(withoutMarker(summary)).toBe("## Task\nship it")
  expect(withoutMarker(summaryMarker)).toBe("")
})

test("only a complete accepted handoff shape is a proposal", () => {
  expect(briefOf(JSON.stringify({ done: "read", next_task: "write", keep: "paths" }))).toEqual({
    done: "read",
    next_task: "write",
    keep: "paths",
    drop: "",
  })
  expect(briefOf('{"done":"read"}')).toBeNull()
  expect(briefOf("{" )).toBeNull()
})

test("compact results require a real child session id", () => {
  expect(compactResult('{"session":"s-child","parent":{"session":"s-parent","seq":2}}', "", 0).session).toBe("s-child")
  expect(() => compactResult("{}", "", 0)).toThrow("no session id")
  expect(() => compactResult("refused", "", 1)).toThrow("refused")
})


interface CompactBench {
  panelOpen(): boolean
  panelText(): string
  escape(): void
  enter(): void
  emit(session: string, call: string, next: string, seq?: number): void
  switchTo(session: SessionView | null): void
  extRunWith(run: () => Promise<ExtRunResult>): void
  opened: { id: string; wakePending: boolean }[]
  notices: string[]
}

function session(
  id: string,
  role: SessionView["role"] = "driver",
  permissionMode: SessionView["permissionMode"] = "ask",
): SessionView {
  return {
    id,
    model: "scripted",
    members: [],
    role,
    status: "idle",
    activity: "idle",
    permissionMode,
  }
}

function compactBench(initial = session("s-a")): CompactBench {
  let current: SessionView | null = initial
  let open = false
  let panelSpec: PanelSpec | null = null
  let eventObserver: ((event: LedgerEventView, session: string, source: "live" | "replay") => void) | null = null
  let sessionObserver: ((session: SessionView | null) => void) | null = null
  let run = async (): Promise<ExtRunResult> => {
    throw new Error("extRun was not configured")
  }
  const opened: { id: string; wakePending: boolean }[] = []
  const notices: string[] = []

  const api = {
    pkg: { id: "compact", version: "v-test" },
    registerCommand(_spec: CommandSpec) {},
    registerCard() {},
    registerUserTurn() {},
    registerWidget() {},
    registerPanel(spec: PanelSpec) {
      panelSpec = spec
      return {
        open() { open = true },
        close() {
          if (!open) return
          open = false
          spec.onClose?.()
        },
        isOpen: () => open,
      }
    },
    observe: {
      onStream: () => () => {},
      onEvent(cb: NonNullable<typeof eventObserver>) {
        eventObserver = cb
        return () => { eventObserver = null }
      },
      onSession(cb: NonNullable<typeof sessionObserver>) {
        sessionObserver = cb
        cb(current)
        return () => { sessionObserver = null }
      },
      tasks: () => [],
      session: () => current,
    },
    actions: {
      appendNote: async () => {},
      extRun: async () => await run(),
      extRunPackage: async () => ({ code: 0, stdout: "", stderr: "" }),
      openTab: (id: string, options?: { wakePending?: boolean }) => {
        opened.push({ id, wakePending: options?.wakePending ?? false })
        current = session(id, "driver", current?.permissionMode ?? "ask")
        sessionObserver?.(current)
      },
      wearNext: () => {},
    },
    state: { get: () => undefined, set: () => {} },
    notice: (text: string) => notices.push(text),
  } as unknown as PluginApi

  activate(api)

  const panel = (): PanelSpec => {
    if (!panelSpec) throw new Error("compact did not register its panel")
    return panelSpec
  }

  return {
    panelOpen: () => open,
    panelText: () => open
      ? panel().render(80).map((line) => line.map((span) => span.text).join("")).join("\n")
      : "",
    escape() {
      if (!open) return
      open = false
      panel().onClose?.()
    },
    enter() {
      if (!open) throw new Error("the panel is closed")
      panel().onKey?.({ name: "return", ctrl: false, shift: false, meta: false })
    },
    emit(id, call, next, seq = 1) {
      const brief = JSON.stringify({ done: `done ${next}`, next_task: next, keep: `${next}.md` })
      eventObserver?.({ seq, kind: "assistant", calls: [{ id: call, tool: "handoff", args: brief }] }, id, "live")
      eventObserver?.({ seq: seq + 1, kind: "tool_results", results: [{ call_id: call, ok: true }] }, id, "live")
    },
    switchTo(next) {
      current = next
      sessionObserver?.(next)
    },
    extRunWith(next) { run = next },
    opened,
    notices,
  }
}

function deferred<T>(): {
  promise: Promise<T>
  resolve(value: T): void
  reject(error: unknown): void
} {
  let resolve!: (value: T) => void
  let reject!: (error: unknown) => void
  const promise = new Promise<T>((yes, no) => {
    resolve = yes
    reject = no
  })
  return { promise, resolve, reject }
}

async function settlePromises(): Promise<void> {
  // run() awaits extRun and startFollow attaches its own continuation, so a
  // result crosses several promise boundaries before panel state is final.
  for (let at = 0; at < 6; at++) await Promise.resolve()
}

const successfulCompact = (id: string): ExtRunResult => ({
  code: 0,
  stdout: JSON.stringify({ session: id, parent: { session: "s-a" } }),
  stderr: "",
})

describe("compact handoff lifecycle", () => {
  test("a background proposal remains reachable across repeated tab switches", () => {
    const ui = compactBench()
    ui.emit("s-b", "handoff-b", "continue B")
    expect(ui.panelOpen()).toBe(false)

    ui.switchTo(session("s-b"))
    expect(ui.panelText()).toContain("next: continue B")
    ui.switchTo(session("s-a"))
    expect(ui.panelOpen()).toBe(false)
    ui.switchTo(session("s-b"))
    expect(ui.panelText()).toContain("next: continue B")
  })

  test("Esc hides a committed follow without cancelling its driven child", async () => {
    const ui = compactBench()
    const running = deferred<ExtRunResult>()
    ui.extRunWith(() => running.promise)
    ui.emit("s-a", "handoff-1", "continue after follow")
    ui.enter()
    expect(ui.panelText()).toContain("Esc hides this panel; follow continues")

    ui.escape()
    running.resolve(successfulCompact("s-child"))
    await settlePromises()
    expect(ui.opened).toEqual([{ id: "s-child", wakePending: true }])
    expect(ui.panelOpen()).toBe(false)
  })

  test("a hidden failed follow resurfaces as a retry", async () => {
    const ui = compactBench()
    const running = deferred<ExtRunResult>()
    ui.extRunWith(() => running.promise)
    ui.emit("s-a", "handoff-1", "retry this")
    ui.enter()
    ui.escape()

    running.reject(new Error("compact exploded"))
    await settlePromises()
    expect(ui.panelOpen()).toBe(true)
    expect(ui.panelText()).toContain("compact exploded")
    expect(ui.notices.at(-1)).toContain("compact exploded")
  })

  test("an older follow completion cannot close a superseding proposal", async () => {
    const ui = compactBench()
    const first = deferred<ExtRunResult>()
    ui.extRunWith(() => first.promise)
    ui.emit("s-a", "handoff-1", "first next", 1)
    ui.enter()

    ui.emit("s-a", "handoff-2", "latest next", 3)
    expect(ui.panelText()).toContain("next: latest next")
    first.resolve(successfulCompact("s-old-child"))
    await settlePromises()

    expect(ui.opened).toEqual([{ id: "s-old-child", wakePending: true }])
    expect(ui.panelOpen()).toBe(false)
    ui.switchTo(session("s-a"))
    expect(ui.panelText()).toContain("next: latest next")
  })

  test("an unsafe observer starts following when it becomes the driver", async () => {
    const ui = compactBench(session("s-a", "observer", "unsafe"))
    ui.extRunWith(async () => successfulCompact("s-child"))
    ui.emit("s-a", "handoff-1", "continue on takeover")
    expect(ui.panelOpen()).toBe(true)

    ui.switchTo(session("s-a", "driver", "unsafe"))
    await settlePromises()
    expect(ui.opened).toEqual([{ id: "s-child", wakePending: true }])
    expect(ui.panelOpen()).toBe(false)
  })

  test("an unsafe proposal becomes visible when its driver turns into an observer", async () => {
    const waiting = { ...session("s-a", "driver", "unsafe"), activity: "sending" as const }
    const ui = compactBench(waiting)
    ui.emit("s-a", "handoff-1", "continue after the writer returns")
    expect(ui.panelOpen()).toBe(false)

    ui.switchTo(session("s-a", "observer", "unsafe"))
    await settlePromises()
    expect(ui.panelText()).toContain("next: continue after the writer returns")
    expect(ui.opened).toEqual([])
  })
})
