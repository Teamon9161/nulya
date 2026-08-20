/**
 * Where a card finds the plugin host (tui-plugin U3).
 *
 * A context rather than a prop threaded through `Transcript` → `Card` →
 * `ToolCard`: the same reason `StyleContext` is one (`render/theme.ts`). A card
 * rendered on its own in a test simply gets `undefined` here and draws the
 * ordinary card, which is exactly the right answer when no plugin is loaded.
 */
import { createContext, useContext } from "solid-js"
import type { PluginHost } from "./host.ts"

export const PluginContext = createContext<PluginHost>()

/** The host, or undefined where none was provided (a test, `plugins = false`). */
export function usePlugins(): PluginHost | undefined {
  return useContext(PluginContext)
}
