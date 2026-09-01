/**
 * The host's own surfaces, registered into the same table a package will use
 * (goals/tui-shell.md §5.1: "the host is the first consumer, so the API cannot
 * be more honest for itself than for anybody else").
 *
 * Each entry is one of the screens that existed unchanged — what is
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
import { main_surface, overlay_surfaces, sidebar_surface, subagent_surface, tab_surface } from "../state/panes.ts"

/**
 * One thunk per screen, in the host's own vocabulary.
 *
 * The mount is passed along because two of these can now be on screen at
 * the same time — the sessions list docked while `/sessions` is also in front —
 * and a view that listens for keys has to know whether it is the one being
 * typed at. Every other thunk ignores the argument, which is the honest shape:
 * a screen that does not care is written as though it had never been offered.
 */
export interface HostViews {
  /** The portal: the active tab's own pane tree, drawn. */
  tab: (mount: SurfaceMount) => JSX.Element
  transcript: (mount: SurfaceMount) => JSX.Element
  /** One delegation, followed in a pane of the tab that made it. */
  subagent: (mount: SurfaceMount) => JSX.Element
  sessions: (mount: SurfaceMount) => JSX.Element
  sidebar: (mount: SurfaceMount) => JSX.Element
  ext: (mount: SurfaceMount) => JSX.Element
  tasks: (mount: SurfaceMount) => JSX.Element
  help: (mount: SurfaceMount) => JSX.Element
  settings: (mount: SurfaceMount) => JSX.Element
  usage: (mount: SurfaceMount) => JSX.Element
  model: (mount: SurfaceMount) => JSX.Element
  provider: (mount: SurfaceMount) => JSX.Element
  cwd: (mount: SurfaceMount) => JSX.Element
  /** The same browser, choosing a directory on a `remote:` `/env` target instead of this tab's own. */
  envdir: (mount: SurfaceMount) => JSX.Element
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
    /**
     * The portal into the front tab's own tree.
     *
     * `claimsKeyboard: false`, and it is never consulted: `focusThrough`
     * resolves the app tree's focus one hop further whenever it lands here, so
     * the answer always comes from the leaf that is actually being typed at.
     * The honest value for a surface that is a hole in the screen is "claims
     * nothing", and saying it here means no reader has to special-case the id.
     */
    surface(tab_surface, "tab", false, views.tab),
    // The one surface that does not claim the keyboard: what is typed while it
    // is up belongs to the composer below it.
    surface(main_surface, "transcript", false, views.transcript),
    /**
     * A delegation, watched. It CLAIMS the keyboard for the reason the
     * docked rail does: focusing it is how you scroll back through what the
     * sub-agent has been doing, and a pane that answers `j` while the composer
     * still blinks is the trap that boolean exists to prevent.
     */
    surface(subagent_surface, "sub-agent", true, views.subagent),
    /**
     * The sessions list, docked.
     *
     * It CLAIMS the keyboard: `claimsKeyboard` asks "does focusing this pane
     * take the keyboard away from the composer", and the honest answer for a
     * list you drive with `j` is yes. A sidebar has no reason to stop a
     * person typing, and that is kept true where it actually lives:
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
    /**
     * The directory browser (§5.3b). A PLACE rather than an identity, so its
     * title carries no glyph (§6.5) — and an overlay rather than a composer
     * dialog because it is a list that can outgrow the screen and therefore
     * needs a scrollbox, which is the line §6.5 draws between the two
     * skeletons.
     */
    surface(overlay_surfaces.cwd, "directory", true, views.cwd),
    /**
     * The same browser, a second registration: choosing WHERE on a `remote:`
     * target a session's workspace goes, rather than this tab's own directory
     *. Two surface ids because two things
     * can be true at once about "is the directory browser up" — this tab's
     * own `/cwd` and a pending `/env` choice are unrelated questions, and one
     * flag answering both would make picking a remote workspace look like it
     * also moved the tab.
     */
    surface(overlay_surfaces.envdir, "remote directory", true, views.envdir),
  ]
}
