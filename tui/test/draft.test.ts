import { expect, test } from "bun:test"
import { DraftHistory } from "../src/draft.ts"

test("settling concurrent pastes preserves later edits and does not add an undo step", () => {
  const history = new DraftHistory()
  history.record({ text: "中文 ", cursor: 3 })
  history.record({ text: "中文 [a]", cursor: 6 })
  history.record({ text: "中文 [a][b]", cursor: 9 })
  history.record({ text: "中文 [a][b] end", cursor: 13 })
  expect(history.settle("[b]", "two").text).toBe("中文 [a]two end")
  expect(history.settle("[a]", "one").text).toBe("中文 onetwo end")
  expect(history.undo().text).toBe("中文 onetwo")
  expect(history.undo().text).toBe("中文 one")
  expect(history.undo().text).toBe("中文 ")
  expect(history.redo().text).toBe("中文 one")
})

test("a paste resolved while undone lands only in redo history; a new edit discards it", () => {
  const history = new DraftHistory()
  history.record({ text: "keep ", cursor: 5 })
  history.record({ text: "keep [pending]", cursor: 14 })
  history.undo()
  expect(history.settle("[pending]", "image").text).toBe("keep ")
  expect(history.redo()).toEqual({ text: "keep image", cursor: 10 })
  history.undo()
  history.record({ text: "keep new", cursor: 8 })
  expect(history.redo().text).toBe("keep new")
})

test("an empty clipboard answer leaves no phantom undo step", () => {
  const history = new DraftHistory()
  history.record({ text: "keep", cursor: 4 })
  history.record({ text: "keep[pending]", cursor: 13 })
  expect(history.settle("[pending]", "").text).toBe("keep")
  expect(history.undo().text).toBe("")
  expect(history.redo().text).toBe("keep")
})
