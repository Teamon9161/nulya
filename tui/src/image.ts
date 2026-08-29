import { isAbsolute, resolve } from "node:path"
import type { ImageInput } from "./nulya/cli.ts"

/**
 * An image on its way into a draft: what counts as one, how big one may be, and
 * the second way to hand one over — its path.
 *
 * The clipboard route (`clipboard.ts`) is only reachable on a terminal that
 * hands `Ctrl+V` (or `Alt+V`) to the application. Most keep that key for
 * themselves, and what arrives here instead is a bracketed paste of TEXT — which
 * is exactly what copying a file in a file manager, or dragging one onto the
 * window, produces: the path. So a paste that is nothing but the path of a
 * picture is the picture, on every terminal there is, and the gesture stops
 * depending on which key the terminal was willing to give up.
 *
 * The suffix decides only whether to LOOK; the bytes decide what it is. That is
 * the kernel's own rule for `session append --image` (DESIGN §9.5) — a file
 * named `.png` that is not one is not one — and it is why this never has to
 * trust a name.
 */

/**
 * The kernel refuses anything larger, one image at a time, and deliberately
 * will not resize on your behalf (DESIGN §9.5). Said here so the refusal lands
 * on the gesture rather than on the turn a draft was built for.
 */
export const max_image_bytes = 5 * 1024 * 1024

/** The two formats the kernel takes, told from their first bytes. */
export function sniffImage(bytes: Uint8Array): ImageInput["mediaType"] | null {
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 &&
    bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a
  ) return "image/png"
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg"
  return null
}

/** What a pasted path turned out to be. */
export type PastedImage =
  | { kind: "image"; image: ImageInput }
  /** A picture, and one this session could never send. */
  | { kind: "oversize"; bytes: number }
  /** No such file, or bytes that are not a picture — the paste was only text. */
  | { kind: "none" }

const suffixes = [".png", ".jpg", ".jpeg"]

/**
 * The path of an image file, if that is the whole of this paste.
 *
 * Whole, because anything else is prose that happens to mention a file, and
 * swallowing that would make paste unpredictable. A line break is the giveaway:
 * one path never has one, a log always does.
 */
export function imagePathIn(text: string): string | null {
  const one = text.trim()
  if (one.length === 0 || one.length > 4096 || /[\r\n]/.test(one)) return null
  const bare = unquoted(one)
  const path = bare.toLowerCase().startsWith("file://") ? fromFileUri(bare) : bare
  if (!path) return null
  const lower = path.toLowerCase()
  return suffixes.some((suffix) => lower.endsWith(suffix)) ? path : null
}

/**
 * One pair of quotes off. A file manager quotes what it hands over as soon as
 * the path has a space in it, and that pair belongs to the gesture, not to the
 * name of the file.
 */
function unquoted(text: string): string {
  for (const quote of ['"', "'"]) {
    if (text.length >= 2 && text.startsWith(quote) && text.endsWith(quote)) return text.slice(1, -1)
  }
  return text
}

/** `file:///C:/pictures/a.png` — what a desktop hands over instead of a path. */
function fromFileUri(uri: string): string | null {
  let url: URL
  try {
    url = new URL(uri)
  } catch {
    return null
  }
  if (url.protocol !== "file:") return null
  const decoded = decodeURIComponent(url.pathname)
  // `file:///C:/…`: that leading slash belongs to the URI, not to the path.
  const path = /^\/[A-Za-z]:/.test(decoded) ? decoded.slice(1) : decoded
  return url.hostname ? `//${url.hostname}${path}` : path
}

/**
 * Read what a pasted path names, relative to the workspace the tab talks about
 * rather than to wherever this process was started.
 *
 * The head is read first: a name is not evidence, and a file that is not a
 * picture must cost one small read rather than however large it happens to be.
 */
export async function readImageFile(path: string, dir?: string): Promise<PastedImage> {
  const full = isAbsolute(path) ? path : resolve(dir ?? process.cwd(), path)
  try {
    const file = Bun.file(full)
    const head = new Uint8Array(await file.slice(0, 8).arrayBuffer())
    const mediaType = sniffImage(head)
    // A missing file reads as an empty head, which is not a picture either.
    if (!mediaType) return { kind: "none" }
    if (file.size > max_image_bytes) return { kind: "oversize", bytes: file.size }
    return { kind: "image", image: { bytes: new Uint8Array(await file.arrayBuffer()), mediaType } }
  } catch {
    // A directory named `.png`, a permission, a path this OS will not have:
    // all of them mean the same thing to a paste — it was text.
    return { kind: "none" }
  }
}

/** The one sentence for the one limit, wherever the image came from. */
export function tooLarge(bytes: number): string {
  const mb = (bytes / (1024 * 1024)).toFixed(1)
  return `that image is ${mb} MB · the limit is 5 MB per image, and nothing here will resize it for you`
}
