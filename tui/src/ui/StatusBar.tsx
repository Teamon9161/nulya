import { createMemo } from "solid-js"
import { useTerminalDimensions } from "@opentui/solid"
import { useStyle } from "../render/theme.ts"
import type { SessionSnapshot } from "../state/session.ts"
import type { DriverStatus } from "../state/driver.ts"

function compact(n: number): string {
  if (n < 1000) return String(n)
  if (n < 1_000_000) return `${(n / 1000).toFixed(1)}k`
  return `${(n / 1_000_000).toFixed(1)}M`
}

/**
 * One line: what this process has counted, what is happening right now, and the
 * three keys worth knowing. Token totals are `since attach` on purpose — the
 * stream reports per-step usage and history before we attached is unknown
 * (tui.md §4.5).
 */
export function StatusBar(props: {
  snapshot: SessionSnapshot
  status: DriverStatus
  spinnerFrame: string
  hint?: string
}) {
  const style = useStyle()
  const dimensions = useTerminalDimensions()

  const usage = createMemo(() => {
    const u = props.snapshot.usage
    if (u.input === 0 && u.output === 0) return "no usage yet"
    const cache = u.input > 0 ? Math.round((u.cacheRead / u.input) * 100) : 0
    return `↑${compact(u.input)} ↓${compact(u.output)} cache ${cache}% · since attach`
  })

  const activity = createMemo(() => {
    if (props.snapshot.error) return `error: ${props.snapshot.error}`
    if (props.status === "canceling") return `${props.spinnerFrame} canceling`
    if (props.status === "stepping") {
      const tool = props.snapshot.activeTool
      return `${props.spinnerFrame} ${tool ? tool : "model"}`
    }
    if (props.status === "sending") return `${props.spinnerFrame} sending`
    if (props.snapshot.lastStopped === "budget") return "step budget spent · /step to continue"
    if (props.snapshot.lastStopped === "canceled") return "canceled"
    return "idle"
  })

  const color = () =>
    props.snapshot.error ? style.theme.err : props.snapshot.lastStopped === "budget" ? style.theme.warn : style.theme.dim

  return (
    <box flexDirection="row" width="100%" paddingLeft={1} paddingRight={1}>
      <box flexGrow={1} flexShrink={1}>
        <text fg={color()}>
          {usage()} · {activity()} · {props.hint ?? "Esc cancel · Ctrl+O fold · /help"}
        </text>
      </box>
      {dimensions().width >= 60 ? (
        <text fg={style.theme.dim}>
          step {props.snapshot.steps} · driver
        </text>
      ) : null}
    </box>
  )
}
