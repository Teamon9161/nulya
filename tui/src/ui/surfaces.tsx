/**
 * The host's own surfaces, registered into the same table a package will use
 * (goals/tui-shell.md §5.1: "the host is the first consumer, so the API cannot
 * be more honest for itself than for anybody else").
 *
 * Each entry is one of the screens that existed before T68, unchanged — what is
 * new is that the host now says out loud, per screen, the two things a pane
 * needs to know about it:
 *
 *  - WHO OWNS IT. All of these are `host`. `/ext`, `/provider` and the approval
 *    chain are trusted zones (§1.1) and the chrome rule (§1 推论一) is that a
 *    package may never draw them: letting the audited decorate the audit room.
 *    That rule is enforceable because ownership is a field, not a convention.
 *  - WHETHER IT TAKES THE KEYBOARD. Every full-screen view does; the transcript
 *    does not — its pane is where the composer's keystrokes are ABOUT, not
 *    where they go. That single boolean is what `overlay.active()` used to mean
 *    and is now the only definition of it.
 *
 * The JSX itself stays in `App`: these screens take a dozen props apiece off
 * state the host holds, and threading that through a registry would buy nothing
 * but a second set of types. A definition is an identity plus a thunk.
 *
 * No `onKey` here. The host's overlays listen for themselves through OpenTUI —
 * they did before this table existed, and the table did not make that wrong.
 * S2's packages cannot install a global listener, which is who that field is
 * for.
 */
import type { JSX } from "solid-js"
import { host_owner, type SurfaceDefinition } from "../pane/registry.ts"
import { main_surface, overlay_surfaces } from "../state/panes.ts"

/** One thunk per screen, in the host's own vocabulary. */
export interface HostViews {
  transcript: () => JSX.Element
  sessions: () => JSX.Element
  ext: () => JSX.Element
  tasks: () => JSX.Element
  help: () => JSX.Element
  settings: () => JSX.Element
  usage: () => JSX.Element
  model: () => JSX.Element
  provider: () => JSX.Element
}

function surface(
  id: string,
  title: string,
  claimsKeyboard: boolean,
  render: () => JSX.Element,
): SurfaceDefinition<JSX.Element> {
  return { id, title, owner: host_owner, claimsKeyboard, render }
}

export function hostSurfaces(views: HostViews): SurfaceDefinition<JSX.Element>[] {
  return [
    // The one surface that does not claim the keyboard: what is typed while it
    // is up belongs to the composer below it.
    surface(main_surface, "transcript", false, views.transcript),
    surface(overlay_surfaces.sessions, "sessions", true, views.sessions),
    surface(overlay_surfaces.ext, "extensions", true, views.ext),
    surface(overlay_surfaces.tasks, "tasks", true, views.tasks),
    surface(overlay_surfaces.help, "help", true, views.help),
    surface(overlay_surfaces.settings, "settings", true, views.settings),
    surface(overlay_surfaces.usage, "usage", true, views.usage),
    surface(overlay_surfaces.model, "model", true, views.model),
    surface(overlay_surfaces.provider, "providers", true, views.provider),
  ]
}
