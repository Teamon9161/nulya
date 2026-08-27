/**
 * The surface registry: what a pane can be shown (goals/tui-shell.md §5.1).
 *
 * A SURFACE is one whole screen's worth of content with an owner — the
 * transcript, `/ext`, `/sessions`, and later a package's own T2 face. The host
 * mounts panes THROUGH this table rather than through a hardcoded switch, which
 * is what makes §5.1's promise checkable: the built-in screens are the first
 * consumers of the same API a package will use, so the API cannot quietly be
 * better for the host than for anybody else.
 *
 * S1a registers only the host's own surfaces. The three fields a package will
 * fill in are already the interesting ones, and they are here now because they
 * are what the host has to reason about, not conveniences:
 *
 *  - `owner` — host or package. §1's chrome rule reads this: a trusted zone is
 *    a surface only the host may own, and "the host owns it" has to be a fact
 *    in the table rather than a naming convention.
 *  - `claimsKeyboard` — whether focusing this pane takes the keyboard away from
 *    the composer. Today this is exactly what `overlay.active()` used to mean.
 *  - `onKey` — where keys go while this surface's pane is focused. The host's
 *    own overlays still listen for themselves (they did before this table
 *    existed and nothing about it made them wrong), so it is optional; S2's
 *    packages, which cannot install a global listener, will use it.
 *
 * Name collisions follow the store-roots rule used everywhere else in this
 * repository (goals/tui-shell.md §3.3): FIRST HOLDER WINS and the loser is
 * reported rather than silently dropped. The host registers first, so no
 * package can take `host:*` out from under a screen a person has to trust.
 */
import type { PaneId, SurfaceId } from "./tree.ts"

export type SurfaceOwner = { readonly kind: "host" } | { readonly kind: "package"; readonly id: string }

export const host_owner: SurfaceOwner = { kind: "host" }

/** What a surface is told about the pane it is being drawn into. */
export interface SurfaceMount {
  readonly pane: PaneId
  /** Whether this pane currently holds the keyboard. */
  readonly focused: boolean
}

/** A key offered to the focused surface. Return true to claim it. */
export interface SurfaceKey {
  readonly name: string
  readonly ctrl: boolean
  readonly shift: boolean
  readonly meta: boolean
}

/**
 * A surface definition, generic over what "drawn" means so that the model stays
 * testable without a renderer: the host instantiates it with its own element
 * type, the tests with strings.
 */
export interface SurfaceDefinition<R> {
  readonly id: SurfaceId
  /**
   * How chrome names this surface when it has to — a pane title, a picker row.
   * Not drawn anywhere in S1a: with one pane there is nothing to disambiguate,
   * and a title bar over a single pane is a row of pixels saying what the
   * screen already says (tui.md §6.1 rule 4).
   */
  readonly title: string
  readonly owner: SurfaceOwner
  readonly claimsKeyboard: boolean
  readonly render: (mount: SurfaceMount) => R
  readonly onKey?: (key: SurfaceKey, mount: SurfaceMount) => boolean
}

export type RegisterResult =
  | { readonly accepted: true; readonly dispose: () => void }
  | { readonly accepted: false; readonly shadowedBy: SurfaceOwner }

export interface SurfaceRegistry<R> {
  register(definition: SurfaceDefinition<R>): RegisterResult
  get(id: SurfaceId): SurfaceDefinition<R> | undefined
  has(id: SurfaceId): boolean
  list(): readonly SurfaceDefinition<R>[]
  /** Every registration that lost a name to an earlier holder, in arrival order. */
  shadowed(): readonly { readonly id: SurfaceId; readonly owner: SurfaceOwner }[]
}

export function createSurfaceRegistry<R>(): SurfaceRegistry<R> {
  const held = new Map<SurfaceId, SurfaceDefinition<R>>()
  const lost: { id: SurfaceId; owner: SurfaceOwner }[] = []
  return {
    register(definition) {
      const holder = held.get(definition.id)
      if (holder) {
        lost.push({ id: definition.id, owner: definition.owner })
        return { accepted: false, shadowedBy: holder.owner }
      }
      held.set(definition.id, definition)
      return {
        accepted: true,
        // Only the registration that won may take the name back down: a later
        // arrival disposing would hand the name to nobody.
        dispose: () => {
          if (held.get(definition.id) === definition) held.delete(definition.id)
        },
      }
    },
    get: (id) => held.get(id),
    has: (id) => held.has(id),
    list: () => [...held.values()],
    shadowed: () => lost,
  }
}

/**
 * Whether the surface in a focused pane takes the keyboard.
 *
 * An id with no definition claims nothing: a pane pointing at a surface that is
 * not there must not be able to swallow every keystroke, which is the shape a
 * package failing to load would otherwise take.
 */
export function claimsKeyboard<R>(registry: SurfaceRegistry<R>, surface: SurfaceId | null): boolean {
  if (!surface) return false
  return registry.get(surface)?.claimsKeyboard ?? false
}
