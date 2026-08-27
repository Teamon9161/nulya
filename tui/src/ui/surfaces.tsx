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
import { host_owner, type SurfaceMount, type SurfaceDefinition } from "../pane/registry.ts"
import { main_surface, overlay_surfaces, sidebar_surface } from "../state/panes.ts"

/**
 * One thunk per screen, in the host's own vocabulary.
 *
 * The mount is passed along (T69) because two of these can now be on screen at
 * the same time — the sessions list docked while `/sessions` is also in front —
 * and a view that listens for keys has to know whether it is the one being
 * typed at. Every other thunk ignores the argument, which is the honest shape:
 * a screen that does not care is written as though it had never been offered.
 */
export interface HostViews {
  transcript: (mount: SurfaceMount) => JSX.Element
  sessions: (mount: SurfaceMount) => JSX.Element
  sidebar: (mount: SurfaceMount) => JSX.Element
  ext: (mount: SurfaceMount) => JSX.Element
  tasks: (mount: SurfaceMount) => JSX.Element
  help: (mount: SurfaceMount) => JSX.Element
  settings: (mount: SurfaceMount) => JSX.Element
  usage: (mount: SurfaceMount) => JSX.Element
  model: (mount: SurfaceMount) => JSX.Element
  provider: (mount: SurfaceMount) => JSX.Element
}

function surface(
  id: string,
  title: string,
  claimsKeyboard: boolean,
  render: (mount: SurfaceMount) => JSX.Element,
): SurfaceDefinition<JSX.Element> {
  return { id, title, owner: host_owner, claimsKeyboard, render }
}

export function hostSurfaces(views: HostViews): SurfaceDefinition<JSX.Element>[] {
  return [
    // The one surface that does not claim the keyboard: what is typed while it
    // is up belongs to the composer below it.
    surface(main_surface, "transcript", false, views.transcript),
    /**
     * The sessions list, docked (T69).
     *
     * It CLAIMS the keyboard, which is not what T68 forecast, and the field's
     * own definition is why: `claimsKeyboard` asks "does focusing this pane
     * take the keyboard away from the composer", and the honest answer for a
     * list you drive with `j` is yes. The promise T68 was making — a sidebar
     * has no reason to stop a person typing — is kept where it actually lives:
     * OPENING it does not focus it (`state/sidebar.ts`, `focusNew: false`), so
     * the keyboard only ever comes here because somebody sent it here, and Esc
     * sends it back. The alternative is a pane that answers `j` while the
     * composer still blinks, which is a trap rather than a compromise.
     */
    surface(sidebar_surface, "sessions", true, views.sidebar),
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
