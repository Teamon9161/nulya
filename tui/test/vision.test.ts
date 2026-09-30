import { expect, test } from "bun:test"
import { imageAccepted } from "../src/state/vision.ts"
import type { ModelView } from "../src/nulya/cli.ts"

test("vision UI uses effective claims scoped to the frozen provider, not a profile's current selection", () => {
  const claims = [{ provider: "codex", model: "gpt-6.1-sol" }]
  expect(imageAccepted(claims, "codex", "gpt-6.1-sol", [])).toBe(true)
  expect(imageAccepted(claims, "openai", "gpt-6.1-sol", [])).toBe(false)
  expect(imageAccepted(claims, "codex", "unknown", [])).toBe(false)
  const catalog: ModelView[] = [{ id: "custom", label: "", efforts: [], default_effort: null, context_window: null, vision: true }]
  expect(imageAccepted([], "codex", "custom", catalog)).toBe(false)
  expect(imageAccepted(undefined, "codex", "custom", catalog)).toBe(true)
  expect(imageAccepted(undefined, "codex", "unknown", catalog)).toBe(false)
})
