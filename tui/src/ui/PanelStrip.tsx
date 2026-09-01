import { For, Show } from "solid-js"
import { useStyle } from "../render/theme.ts"
import { CardFrame, sizeNote } from "../render/cards/CardFrame.tsx"
import { checklistChip, checklistMarker, describeTool } from "../render/registry.ts"
import { renderHintOf, type Contributions } from "../nulya/files.ts"
import type { ToolItem } from "../state/session.ts"

/**
 * `panel: true`: the degraded progress display
 * a front end with no plugin code can still give — the latest call of a
 * declaring tool, projected above the composer whether or not its own card is
 * still on screen. Sits where §4.4b's activity line does (below it, above the
 * composer): "what is happening" and "the plan this is working through" are
 * both read on every glance, so neither belongs scrolled away in the
 * transcript.
 *
 * Reuses `CardFrame` rather than inventing a second card language — folding,
 * hover and the browse-mode selection this project already has are exactly
 * what a foldable strip needs. Its fold state is keyed `panel:<item key>`, a
 * distinct key from the transcript card's own, so opening one does not open
 * the other; they are two views of the same call, not one card in two places.
 *
 * v1 stacks by package order and folds past two rows (goals/tui-plugin.md U2
 * §5, open question 3) — the simplest thing that does not grow without bound
 * when several tools declare `panel: true` at once.
 */
const visible_rows = 2

export function PanelStrip(props: { items: ToolItem[]; contributions: Contributions[] }) {
  const style = useStyle()
  const visible = () => props.items.slice(0, visible_rows)
  const overflow = () => props.items.slice(visible_rows)

  return (
    <Show when={props.items.length > 0}>
      <box flexDirection="column" width="100%">
        <For each={visible()}>
          {(item) => {
            const presentation = () =>
              describeTool({ tool: item.tool, args: item.args, output: item.output }, style.glyphs, {
                render: renderHintOf(props.contributions, item.tool),
              })
            const chip = () => {
              if (item.state === "pending") return "…"
              if (item.state === "running") return "running"
              const items = presentation().checklist
              // Same chip `ChecklistCard` shows (done/total) rather than a
              // line count that would always read "0" — a checklist's own
              // arguments, not its output, are usually where the items live.
              if (items) return checklistChip(items)
              const size = sizeNote(item.output)
              return item.ok === false ? (size.length > 0 ? `${size} · failed` : "failed") : size
            }
            return (
              <CardFrame
                itemKey={`panel:${item.key}`}
                glyph={presentation().glyph}
                accent={style.theme.accent.tool}
                head={presentation().head}
                chip={chip()}
                chipTone={item.ok === false ? "err" : "dim"}
                defaultOpen={false}
                foldable={item.output.length > 0 || (presentation().checklist?.length ?? 0) > 0}
              >
                <Show
                  when={presentation().checklist}
                  fallback={<text fg={style.theme.fg}>{item.output}</text>}
                >
                  <For each={presentation().checklist}>
                    {(entry) => (
                      <text fg={entry.state === "done" ? style.theme.dim : style.theme.fg}>
                        {checklistMarker(entry.state)} {entry.text}
                      </text>
                    )}
                  </For>
                </Show>
              </CardFrame>
            )
          }}
        </For>
        <Show when={overflow().length > 0}>
          <text fg={style.theme.faint}>
            {"  "}+{overflow().length} more panel{overflow().length === 1 ? "" : "s"} · /ext
          </text>
        </Show>
      </box>
    </Show>
  )
}
