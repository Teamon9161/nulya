import type { ImageInput } from "./nulya/cli.ts"

/**
 * Read an image from the host clipboard. Terminals can bracket-paste text but
 * have no byte-level image paste protocol, so Ctrl+V has to ask the desktop
 * clipboard directly. Each helper is optional; failure falls through to the
 * next one without putting its diagnostics on the TUI.
 */
export async function clipboardImage(
  platform = process.platform,
  env: Record<string, string | undefined> = process.env,
): Promise<ImageInput | null> {
  const candidates: { argv: string[]; mediaType: ImageInput["mediaType"] }[] = []
  if (platform === "darwin") {
    candidates.push({ argv: ["pngpaste", "-"], mediaType: "image/png" })
  } else if (platform === "linux") {
    if (env["WAYLAND_DISPLAY"]) {
      candidates.push(
        { argv: ["wl-paste", "--no-newline", "--type", "image/png"], mediaType: "image/png" },
        { argv: ["wl-paste", "--no-newline", "--type", "image/jpeg"], mediaType: "image/jpeg" },
      )
    }
    candidates.push(
      { argv: ["xclip", "-selection", "clipboard", "-t", "image/png", "-o"], mediaType: "image/png" },
      { argv: ["xclip", "-selection", "clipboard", "-t", "image/jpeg", "-o"], mediaType: "image/jpeg" },
    )
  }

  for (const candidate of candidates) {
    try {
      const child = Bun.spawn(candidate.argv, { stdout: "pipe", stderr: "ignore" })
      const [code, bytes] = await Promise.all([child.exited, new Response(child.stdout).bytes()])
      if (code !== 0 || bytes.length === 0) continue
      const mediaType = sniffImage(bytes)
      if (mediaType) return { bytes, mediaType }
    } catch {
      // A missing helper is just the next candidate, not a prompt error.
    }
  }
  return null
}

export function sniffImage(bytes: Uint8Array): ImageInput["mediaType"] | null {
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 &&
    bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a
  ) return "image/png"
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg"
  return null
}
