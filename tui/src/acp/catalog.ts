/**
 * What a session's FROZEN composition offers a client.
 *
 * Read from the header and the sealed manifests it names, never from the store's
 * `current`: composition freezes at `session new`, so an `ext activate` after
 * that changes the next session and not this one. Nothing here runs a package —
 * the manifest is the schema's single truth.
 */
import type { Workspace } from "../nulya/bin.ts"
import { readContributions, readHeader } from "../nulya/files.ts"

/** The manifest word for "draw my calls as a checklist" (`ToolSpec.ui.render`). */
const checklist = "checklist"

export interface Catalog {
  /**
   * The tools whose package asked for them to be drawn as a checklist. An ACP
   * `plan` IS a checklist, so a call to one of these becomes a plan update.
   *
   * Asked of the manifest, never of the name: which package this session wears
   * and what it calls its tools are its own business, and a front end that
   * matched `plan`'s `todo` by spelling would both miss the next package to
   * offer a checklist and mistake any other `todo` for one.
   */
  checklistTools: Set<string>
}

const empty_catalog: Catalog = { checklistTools: new Set() }

export async function readCatalog(ws: Workspace, id: string): Promise<Catalog> {
  const header = await readHeader(ws, id)
  if (!header) return empty_catalog
  const checklistTools = new Set<string>()
  for (const member of header.composition.active) {
    const contributes = await readContributions(ws, member.id, member.version)
    for (const [tool, render] of Object.entries(contributes.toolRender)) {
      if (render === checklist) checklistTools.add(tool)
    }
  }
  return { checklistTools }
}

/**
 * NO `available_commands_update` IS SENT, and `contributes.commands` is read
 * here for nothing else.
 *
 * A command arrives as ordinary prompt text — ACP has no invocation method, the
 * agent is expected to recognize the `/name` prefix — so advertising one is a
 * promise this adapter would have to keep by hand. Every command a bundled
 * package declares today acts `{"with": …}`: wear this package. Wearing is
 * membership, membership freezes at `session new`, and no driver can add one to
 * a live session. So the menu would offer a mode and deliver a text prefix.
 *
 * Advertising only the actions that CAN be kept (`{"run"}`, `{"skill"}`) is the
 * shape to grow into, but nothing in a member package declares one yet, and
 * turning the notification back on before those two verbs execute would rebuild
 * the same lie for the first package that does. Both halves land together, or
 * neither. `{"with"}` needs more than that: `session/set_mode` answered by a
 * `session new --parent <id>:<seq> --carry --with <pkg>` fork — the primitive
 * for "change the composition, keep the conversation" — which costs the identity
 * this adapter currently leans on, where an ACP session id IS a nulya one.
 *
 * The notification may be sent at any point in a session and as often as it
 * likes, so bringing it back later costs nothing that was spent here.
 */
