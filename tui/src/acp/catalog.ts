/**
 * What a session's FROZEN composition offers a client.
 *
 * Read from the header and the sealed manifests it names, never from the store's
 * `current`: composition freezes at `session new`, so an `ext activate` after
 * that changes the next session and not this one. Nothing here runs a package —
 * the manifest is the schema's single truth.
 */
import type { AvailableCommand } from "@agentclientprotocol/sdk"
import type { Workspace } from "../nulya/bin.ts"
import { readContributions, readHeader } from "../nulya/files.ts"

export interface Catalog {
  /** `contributes.commands`, pooled over the members, in header order. */
  commands: AvailableCommand[]
  /**
   * Whether the `todo` this session's model can call is `extensions/plan`'s.
   * A checklist becomes an ACP `plan`, and a tool of that name from any other
   * package is not one.
   */
  planTodo: boolean
}

const empty_catalog: Catalog = { commands: [], planTodo: false }

export async function readCatalog(ws: Workspace, id: string): Promise<Catalog> {
  const header = await readHeader(ws, id)
  if (!header) return empty_catalog
  const commands: AvailableCommand[] = []
  let planTodo = false
  for (const member of header.composition.active) {
    const contributes = await readContributions(ws, member.id, member.version)
    for (const command of contributes.commands) {
      commands.push({ name: command.name, description: command.description })
    }
    if (member.id === "plan" && contributes.tools.includes("todo")) planTodo = true
  }
  return { commands, planTodo }
}
