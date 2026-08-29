import { expect, test } from "bun:test"
import { readClipboard, sniffImage } from "../src/clipboard.ts"

const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])

test("clipboard image sniffing trusts bytes, not helper claims", () => {
  expect(sniffImage(png)).toBe("image/png")
  expect(sniffImage(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]))).toBe("image/jpeg")
  expect(sniffImage(new TextEncoder().encode("not an image"))).toBeNull()
})

test("one read answers with whichever of the two pastes the clipboard had", async () => {
  const image = await readClipboard(async () => ({
    status: "read",
    representation: { mimeType: "image/png", bytes: png },
  }))
  expect(image).toEqual({ kind: "image", image: { bytes: png, mediaType: "image/png" } })

  // The half that did not exist before: a clipboard holding text is a paste,
  // not "no image here".
  const text = await readClipboard(async () => ({
    status: "read",
    representation: { mimeType: "text/plain", bytes: new TextEncoder().encode("hello") },
  }))
  expect(text).toEqual({ kind: "text", text: "hello" })
})

test("a representation labelled as an image is still judged by its bytes", async () => {
  const lying = await readClipboard(async () => ({
    status: "read",
    representation: { mimeType: "image/png", bytes: new TextEncoder().encode("<script>") },
  }))
  // Not text either: a host that says "image" and hands over something else has
  // told us nothing we can paste.
  expect(lying.kind).toBe("empty")
})

test("no clipboard here is an answer, not a crash", async () => {
  expect((await readClipboard(async () => ({ status: "unsupported" }))).kind).toBe("unavailable")
  expect((await readClipboard(async () => ({ status: "empty" }))).kind).toBe("empty")
  const thrown = await readClipboard(async () => {
    throw new Error("no display")
  })
  expect(thrown).toEqual({ kind: "unavailable", why: "no display" })
})
