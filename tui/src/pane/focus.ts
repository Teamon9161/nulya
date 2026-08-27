/**
 * Who owns the keyboard, in one function (goals/tui-shell.md §0).
 *
 * "High freedom without fights" rests on two structural rules, and this is the
 * second of them: **the keyboard has a single arbiter, and it is the host**.
 * Before T68 the answer was spread across a chain of `if`s in `App.tsx`, each
 * one correct and none of them stating the order out loud. Nothing about the
 * order changes here — this file is that chain, written down as a value so it
 * can be read, tested, and pointed at when S2 asks "can my surface have the
 * keyboard?" (answer: only when a person focused its pane, and only when no
 * trusted zone is up).
 *
 * The order, outermost first:
 *
 *  1. the composer dialogs the host owns — the checkout question, `/with`,
 *     `/agent`, `/mode`, and the approval question. These are the TRUSTED ZONE
 *     (§1.1): the screens that would be a security incident if a package could
 *     imitate or outrank them.
 *  2. the focused pane, when its surface claims the keyboard (a full-screen
 *     view: `/ext`, `/sessions`, …). Before T68 this was `overlay.active()`.
 *  3. a plugin's panel.
 *  4. browse mode.
 *  5. the composer — the default, and the only one that is not exclusive.
 *
 * MODIFIED KEYS ARE NOT ARBITRATED. Ctrl+C has to keep working while a call
 * waits — killing the step is one of the two ways out of a question nobody
 * wants to answer — so a chord skips every owner that could swallow it and the
 * host's own keymap layers see it. That is why `modified` is an input rather
 * than something a caller filters beforehand: the exception belongs next to the
 * rule it excepts.
 *
 * Esc and Ctrl+C never appear here at all. They are registered as OpenTUI
 * keymap layers by the host and are answered before this function is consulted
 * — "Esc/Ctrl+C always belong to the host" (§2) is enforced by them not being
 * part of the arbitration in the first place.
 */
import type { PaneId, SurfaceId } from "./tree.ts"

export type DialogKind = "checkout" | "with" | "agent" | "mode" | "approval"

export type FocusOwner =
  | { readonly kind: "dialog"; readonly dialog: DialogKind }
  | { readonly kind: "surface"; readonly pane: PaneId; readonly surface: SurfaceId }
  | { readonly kind: "plugin-panel" }
  | { readonly kind: "browse" }
  | { readonly kind: "composer" }

export interface FocusState {
  /** Ctrl or Meta is held: the chord outranks every claim below (see above). */
  readonly modified: boolean
  /**
   * A directory this screen just walked into is asking to be trusted
   * (goals/tui-shell.md §5.3b point 6, DESIGN §9). Outermost of the dialogs
   * because it is the only one that grants AUTHORITY rather than choosing
   * something: it is put once per directory, and until it is answered the
   * things it is about take no part in any session.
   */
  readonly checkout: boolean
  readonly withPicker: boolean
  readonly agentPicker: boolean
  readonly modePicker: boolean
  /** A tool call is stopped at the gate, waiting for an answer. */
  readonly approval: boolean
  /** The focused pane, but only when its surface claims the keyboard. */
  readonly keyboardPane: { readonly pane: PaneId; readonly surface: SurfaceId } | null
  readonly pluginPanel: boolean
  readonly browse: boolean
}

export function resolveFocus(state: FocusState): FocusOwner {
  if (!state.modified) {
    // The three pickers in the order they can stack: `/with` and `/agent` are
    // only ever opened on purpose, while the mode picker can be opened FROM the
    // approval dialog by clicking the chip — the one moment two of these are on
    // screen at once (tui.md §5.7, T31).
    if (state.checkout) return { kind: "dialog", dialog: "checkout" }
    if (state.withPicker) return { kind: "dialog", dialog: "with" }
    if (state.agentPicker) return { kind: "dialog", dialog: "agent" }
    if (state.modePicker) return { kind: "dialog", dialog: "mode" }
    if (state.approval) return { kind: "dialog", dialog: "approval" }
  }
  const pane = state.keyboardPane
  if (pane) return { kind: "surface", pane: pane.pane, surface: pane.surface }
  if (!state.modified && state.pluginPanel) return { kind: "plugin-panel" }
  if (state.browse) return { kind: "browse" }
  return { kind: "composer" }
}

/**
 * Whether the composer may keep its cursor. Everything else on this screen is
 * exclusive, and a box that still blinks is a box saying "type here" (T28).
 */
export function composerHasKeyboard(owner: FocusOwner): boolean {
  return owner.kind === "composer"
}

/** Whether a host-owned dialog is up — what hides a package's panel outright. */
export function dialogUp(owner: FocusOwner): boolean {
  return owner.kind === "dialog"
}
