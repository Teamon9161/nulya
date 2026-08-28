import { expect, test } from "bun:test"
import { sniffImage } from "../src/clipboard.ts"

test("clipboard image sniffing trusts bytes, not helper claims", () => {
  expect(sniffImage(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))).toBe("image/png")
  expect(sniffImage(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]))).toBe("image/jpeg")
  expect(sniffImage(new TextEncoder().encode("not an image"))).toBeNull()
})
