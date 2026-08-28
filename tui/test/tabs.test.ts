/**
 * `createTabStore`'s in-place replace (T84): the move `/clear` runs on.
 *
 * `clear` is the one operation this store has that neither `open` nor
 * `replace` are — putting a fresh DRAFT where a tab (draft or session) used
 * to be, in the SAME array slot, without touching whatever session file was
 * behind it. What makes it that operation and not "`close` then `draft`" is
 * exactly what these pin: the slot does not move, the sibling tab beside it
 * is untouched, and a session with something in it survives being cleared
 * even though this very process created it — the same guard `close` and
 * `replace` already lean on (`discardIfUntouched`), now exercised on the
 * path `/clear` takes rather than the paths that already tested it
 * (`lifecycle.test.tsx`).
 *
 * Wording is deliberately not asserted anywhere here (`App.tsx`'s notices are
 * its own concern) — only the mechanism: position, survival, kind.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { createTabStore } from "../src/state/tabs.ts"
import { createSessionState } from "../src/state/session.ts"
import { sessionAppend, sessionNew } from "../src/nulya/cli.ts"
import { sessionExists } from "../src/nulya/files.ts"
import { scripted_env, tempWorkspace, type TempWorkspace } from "./support.ts"

let ws: TempWorkspace

beforeAll(() => {
  ws = tempWorkspace()
})

afterAll(() => {
  ws.cleanup()
})

test("clearing a draft tab puts a fresh draft in the same slot, sibling untouched", () => {
  const store = createTabStore(ws, { kind: "draft" })
  const sibling = store.draft()
  expect(store.tabs().length).toBe(2)
  const firstKey = store.tabs()[0]!.key
  const cleared = store.clear(firstKey)
  // Same length, same slot: index 0 is the new draft, index 1 is the exact
  // tab object `draft()` returned a moment ago — never rebuilt, never moved.
  expect(store.tabs().length).toBe(2)
  expect(store.tabs()[0]).toBe(cleared)
  expect(store.tabs()[1]).toBe(sibling)
  expect(cleared.kind).toBe("draft")
  // A FRESH draft, not the one that slot held before — `clear` replaces the
  // object rather than resetting fields on it (the same reason `retarget`
  // does, `tabs.ts`).
  expect(cleared.key).not.toBe(firstKey)
  store.disposeAll()
})

test("clearing a session tab does not touch its file, even one this process created", async () => {
  const id = await sessionNew(ws, { profile: "scripted" })
  // Queued, not stepped: the ledger file itself stays header-only, but the
  // inbox this deposits into is non-empty — and that alone is enough for
  // `discardIfUntouched` to refuse to remove the session (`files.ts`). The
  // point under test is that `clear` goes through that same guard rather
  // than some more eager "this tab is mine, throw it away" shortcut.
  await sessionAppend(ws, id, "hello")
  const state = createSessionState(id)
  const store = createTabStore(
    ws,
    { kind: "session", id, state, created: true },
    // A long poll keeps the writer-lease wake-up out of this: only `clear`
    // is under test, not the attachment's own background behaviour.
    { env: scripted_env, pollMs: 60_000 },
  )
  try {
    const cleared = store.clear(store.active().key)
    expect(store.tabs().length).toBe(1)
    expect(store.tabs()[0]).toBe(cleared)
    expect(cleared.kind).toBe("draft")
    expect(sessionExists(ws, id)).toBe(true)
  } finally {
    store.disposeAll()
  }
})

test("clearing one of two session tabs leaves its sibling exactly where it was", async () => {
  const first = await sessionNew(ws, { profile: "scripted" })
  const second = await sessionNew(ws, { profile: "scripted" })
  const store = createTabStore(
    ws,
    { kind: "session", id: first, state: createSessionState(first) },
    { env: scripted_env, pollMs: 60_000 },
  )
  const secondTab = store.open(second, { ws })
  try {
    expect(store.tabs().length).toBe(2)
    expect(store.activeIndex()).toBe(1)
    const cleared = store.clear(store.tabs()[0]!.key)
    expect(store.tabs().length).toBe(2)
    // The cleared slot is a draft at index 0; the sibling never moved and is
    // the exact same tab object `open` returned.
    expect(store.tabs()[0]).toBe(cleared)
    expect(cleared.kind).toBe("draft")
    expect(store.tabs()[1]).toBe(secondTab)
    expect(sessionExists(ws, first)).toBe(true)
    expect(sessionExists(ws, second)).toBe(true)
  } finally {
    store.disposeAll()
  }
})
