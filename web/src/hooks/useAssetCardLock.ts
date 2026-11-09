/** useAssetCardLock — T-1490 / G3. Reads whether an asset card has a posted document (its inventory number is then
 *  read-only). Returns the query result for the caller to interpret; the form fails closed while it is unknown. */
import { useQuery } from '@tanstack/react-query'
import { assetsApi } from '@/modules/assets/assets.api'
import { assetsQueryKeys } from '@/modules/assets/assetsQueryKeys'

export function useAssetCardLock(tenantId: string, cardId: string, enabled: boolean) {
  return useQuery({
    queryKey: assetsQueryKeys.cardLock(tenantId, cardId),
    queryFn: () => assetsApi.cardLock(cardId),
    enabled,
    retry: false,
  })
}
