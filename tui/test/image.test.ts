import { expect, test } from "bun:test"
import { mkdtempSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
import { imagePathIn, max_image_bytes, readImageFile, sniffImage } from "../src/image.ts"

const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])

test("image sniffing trusts bytes, not the name or the label on them", () => {
  expect(sniffImage(png)).toBe("image/png")
  expect(sniffImage(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]))).toBe("image/jpeg")
  expect(sniffImage(new TextEncoder().encode("not an image"))).toBeNull()
})

test("a paste is a path only when that is the whole of it", () => {
  expect(imagePathIn("/home/me/shot.png")).toBe("/home/me/shot.png")
  // What a file manager hands over once the path has a space in it.
  expect(imagePathIn('"C:\\Users\\me\\my shot.PNG"  ')).toBe("C:\\Users\\me\\my shot.PNG")
  expect(imagePathIn("file:///C:/pictures/a%20shot.jpg")).toBe("C:/pictures/a shot.jpg")

  // Prose that mentions a file is prose.
  expect(imagePathIn("have a look at shot.png and tell me")).toBeNull()
  expect(imagePathIn("shot.png\nother.png")).toBeNull()
  expect(imagePathIn("notes.txt")).toBeNull()
  expect(imagePathIn("   ")).toBeNull()
})

test("what a pasted path names is decided by reading it", async () => {
  const dir = mkdtempSync(join(tmpdir(), "nulya-tui-image-"))
  writeFileSync(join(dir, "real.png"), png)
  writeFileSync(join(dir, "liar.png"), "text pretending to be a picture")
  writeFileSync(join(dir, "huge.png"), Buffer.concat([Buffer.from(png), Buffer.alloc(max_image_bytes)]))

  const real = await readImageFile(join(dir, "real.png"))
  expect(real).toEqual({ kind: "image", image: { bytes: png, mediaType: "image/png" } })

  // The suffix said picture; the bytes did not, so the paste was only ever text.
  expect((await readImageFile(join(dir, "liar.png"))).kind).toBe("none")
  expect((await readImageFile(join(dir, "gone.png"))).kind).toBe("none")
  expect((await readImageFile(join(dir, "huge.png"))).kind).toBe("oversize")

  // A relative path belongs to the workspace the tab talks about, not to
  // wherever this process happens to have been started.
  expect((await readImageFile("real.png", dir)).kind).toBe("image")
  expect((await readImageFile("real.png")).kind).toBe("none")
})
