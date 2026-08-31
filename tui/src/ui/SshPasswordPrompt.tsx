import { useScreen, useStyle } from "../render/theme.ts"
import { DialogBody, DialogHint, DialogTitle } from "./Dialog.tsx"

/** Host-owned secret entry. The actual bytes never become a text renderable. */
export function SshPasswordPrompt(props: { spec: string; bytes: number }) {
  const style = useStyle()
  const screen = useScreen()
  const bullets = () => "•".repeat(Math.min(props.bytes, Math.max(1, screen().width - 6)))
  return (
    <box flexDirection="column" width="100%" maxWidth={style.maxWidth} paddingLeft={1} paddingRight={1} flexShrink={0}>
      <DialogTitle name="SSH password" caption={props.spec} tone={style.theme.accent.evolve} />
      <DialogBody lines={[bullets() || "(empty)"]} />
      <DialogHint text="Enter connects · Esc cancels · password stays in memory only" width={screen().width} />
    </box>
  )
}
