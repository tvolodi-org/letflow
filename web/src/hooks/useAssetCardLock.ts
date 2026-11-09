/** useAssetCardLock — T-1490 / G3. Reads whether an asset card has a posted document (its inventory number is then
 *  read-only). The module supplies the key and the fetcher (hooks may not import a module); the caller interprets the
 *  result, and the form fails closed while it is unknown. */
import { useQuery } from '@tanstack/react-query'

export function useAssetCardLock(
  queryKey: readonly unknown[],
  queryFn: () => Promise<{ posted: boolean }>,
  enabled: boolean,
) {
  return useQuery({ queryKey, queryFn, enabled, retry: false })
}
