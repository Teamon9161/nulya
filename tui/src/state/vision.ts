import type { ImageModel, ModelView } from "../nulya/cli.ts"

/** Effective claims come from the same shell resolver as append and carry.
 * Older binaries only supplied the trusted global catalog. */
export function imageAccepted(
  claims: readonly ImageModel[] | undefined,
  provider: string,
  model: string,
  catalog: readonly ModelView[],
): boolean {
  if (claims !== undefined) return claims.some((claim) => claim.provider === provider && claim.model === model)
  return catalog.find((entry) => entry.id === model)?.vision === true
}
