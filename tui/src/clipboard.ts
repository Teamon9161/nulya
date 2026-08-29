import { createHostClipboard, type ClipboardReadResult, type HostClipboardService } from "@opentui/core"
import { sniffImage } from "./image.ts"
import type { ImageInput } from "./nulya/cli.ts"

/**
 * The host clipboard, for the paste this front end takes over (tui.md §11, T79).
 *
 * A terminal can bracket-paste TEXT and has no protocol for anything else, so
 * an image has to be asked for from the desktop clipboard directly. The first
 * version of this shelled out to `pngpaste` / `wl-paste` / `xclip` — which
 * covered macOS and Linux, left Windows with no image paste at all, and left
 * the composer holding half a gesture: `Ctrl+V` was intercepted, an image was
 * looked for, and if there was none the keypress had already been eaten.
 *
 * So this asks for BOTH representations, and the composer pastes whichever came
 * back. That is the arrangement tcode arrived at with `arboard` (`app/input.rs`
 * `paste_from_clipboard`), for the same reason: half a clipboard is a platform
 * edge that never stops producing surprises. Here it costs nothing extra —
 * OpenTUI already ships a native clipboard service on all three platforms
 * (Windows included, where it converts a `CF_BITMAP` to PNG for us).
 *
 * What this does NOT do is replace the terminal's own paste. A terminal that
 * turns `Ctrl+V` into a bracketed paste keeps doing that and never delivers the
 * key here at all; `Composer.onPaste` is still where those arrive.
 */

/** What the clipboard had, in the terms the composer acts on. */
export type ClipboardPaste =
  | { kind: "image"; image: ImageInput }
  | { kind: "text"; text: string }
  /** A clipboard we could read that holds nothing we can paste. */
  | { kind: "empty" }
  /** No readable clipboard here at all — a remote host, a headless session. */
  | { kind: "unavailable"; why: string }

/**
 * The MIME essences we ask for, in preference order. Images first: a copied
 * screenshot usually also offers a text rendering of itself, and the picture is
 * what somebody who copied a picture meant.
 *
 * Essences only — a parametrised type (`text/plain;charset=utf-8`) is rejected
 * by the service before it reads anything.
 */
const wanted = ["image/png", "image/jpeg", "text/plain"] as const

/**
 * One service for the process, created on first use.
 *
 * Long-lived for tcode's reason (`app/mod.rs`): a clipboard opened per paste
 * pays its setup on every keystroke and, on X11, can print to the terminal
 * underneath the alternate screen. Lazy because most sessions never paste, and
 * a screen should not wait on a desktop service to open.
 */
let service: HostClipboardService | null = null
function host(): HostClipboardService {
  service ??= createHostClipboard({ timeoutMs: 2_000 })
  return service
}

/** Let go of the desktop service. Not required to exit — it holds nothing open. */
export async function releaseClipboard(): Promise<void> {
  const open = service
  service = null
  if (open) await open.dispose().catch(() => {})
}

/** The one call this makes on the service. A seam, so tests need no desktop. */
export type ClipboardReader = (types: readonly [string, ...string[]]) => Promise<ClipboardReadResult>

const fromHost: ClipboardReader = (types) => host().read({ preferredTypes: types })

export async function readClipboard(read: ClipboardReader = fromHost): Promise<ClipboardPaste> {
  let result: ClipboardReadResult
  try {
    result = await read(wanted)
  } catch (error) {
    // A clipboard that throws is a clipboard we do not have. It is never worth
    // an error screen: the terminal's own paste is right there.
    return { kind: "unavailable", why: error instanceof Error ? error.message : String(error) }
  }
  switch (result.status) {
    case "read": {
      const bytes = result.representation.bytes
      // The bytes decide, not the label: `sniffImage` is what says this is a
      // PNG, so a host that mislabels a representation cannot put arbitrary
      // bytes into a turn as an image.
      const sniffed = sniffImage(bytes)
      if (sniffed) return { kind: "image", image: { bytes, mediaType: sniffed } }
      if (result.representation.mimeType.startsWith("image/")) {
        return { kind: "empty" }
      }
      const text = new TextDecoder().decode(bytes)
      return text.length === 0 ? { kind: "empty" } : { kind: "text", text }
    }
    case "empty":
      return { kind: "empty" }
    case "limit-exceeded":
      return { kind: "unavailable", why: "what is on the clipboard is larger than this can read" }
    case "timed-out":
      return { kind: "unavailable", why: "the clipboard did not answer" }
    case "failed":
      return { kind: "unavailable", why: result.error.message }
    default:
      // `unsupported` (no clipboard on this host) and `cancelled`.
      return { kind: "unavailable", why: "no clipboard is reachable from here" }
  }
}
