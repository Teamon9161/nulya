import { For, createMemo } from "solid-js"
import { useBodyWidth, useStyle } from "../theme.ts"
import { hardWrapLines } from "../../ui/columns.ts"
import type { CapabilityItem } from "../../state/session.ts"

/**
 * A `capability_note`: the agent gained a capability mid-session.
 * The ledger note is written for the model and contains invoke/load plumbing;
 * the transcript card is written for the person watching the session. It names
 * the extension and the newly available tools/skills. Version ids appear only
 * where they disambiguate the activation or version change; raw invoke/load
 * commands stay out of the default story.
 *
 * Wrapped at this pane's width (`useBodyWidth`, BUGS.md #10/#17): each line is
 * its own `height={1}` row, so a tool description laid out wider than the
 * column it lands in is cut off rather than continued.
 */
export function CapabilityBanner(props: { item: CapabilityItem; previousVersion?: string | null }) {
  const style = useStyle()
  const body = useBodyWidth()
  const details = createMemo(() => capabilityDetails(props.item.text))
  const title = () => capabilityTitle(props.item.id, props.item.version, props.previousVersion ?? null)
  const room = () => Math.max(16, Math.min(body(), style.maxWidth) - 4)
  const lines = createMemo(() => {
    const rows: string[] = []
    if (props.previousVersion && props.previousVersion !== props.item.version) {
      rows.push(`${props.previousVersion} → ${props.item.version}`)
    }
    for (const tool of details().tools) rows.push(`tool   ${tool.name}${tool.description ? ` — ${tool.description}` : ""}`)
    for (const skill of details().skills) rows.push(`skill  ${skill.name}${skill.description ? ` — ${skill.description}` : ""}`)
    if (rows.length === 0) rows.push("available for the rest of this session")
    return rows.flatMap((row) => hardWrapLines(row, room()))
  })

  return (
    <box flexDirection="column" width="100%" paddingLeft={2}>
      <box flexDirection="row" width="100%">
        <text fg={style.theme.accent.evolve}>{style.glyphs.capability} </text>
        <text fg={style.theme.muted}>{title()}</text>
      </box>
      <box paddingLeft={2} flexDirection="column" width="100%">
        <For each={lines()}>{(line) => <text fg={style.theme.dim} height={1}>{line}</text>}</For>
      </box>
    </box>
  )
}

type CapabilityEntry = { name: string; description: string }

function capabilityDetails(text: string): { tools: CapabilityEntry[]; skills: CapabilityEntry[] } {
  const out = { tools: [] as CapabilityEntry[], skills: [] as CapabilityEntry[] }
  let section: "tools" | "skills" | null = null
  for (const raw of text.split("\n")) {
    const line = raw.trim()
    if (/^tools:?$/i.test(line)) {
      section = "tools"
      continue
    }
    if (/^skills:?$/i.test(line)) {
      section = "skills"
      continue
    }
    if (!line.startsWith("-") || section === null) continue
    const item = parseEntry(line.slice(1).trim())
    out[section].push(item)
  }
  return out
}

function parseEntry(line: string): CapabilityEntry {
  const em = line.indexOf("—")
  const hyphen = line.indexOf(" - ")
  const split = em >= 0 ? em : hyphen >= 0 ? hyphen + 1 : -1
  if (split < 0) return { name: line.trim(), description: "" }
  return { name: line.slice(0, split).trim(), description: line.slice(split + 1).trim() }
}

function capabilityTitle(id: string, version: string, previousVersion: string | null): string {
  if (previousVersion === null) return `extension activated · ${id}@${version}`
  if (previousVersion === version) return `extension available · ${id}@${version}`
  return `extension version changed · ${id}`
}
