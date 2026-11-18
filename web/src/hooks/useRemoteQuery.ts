/** useRemoteQuery — T-2042. A plain read query for a component that renders its own loading and failure states
 *  (a thumbnail with a placeholder). The module supplies the key and the fetcher (hooks may not import a module);
 *  retries are off so a 404 or a refusal shows its placeholder at once instead of looping. */
import { useQuery } from '@tanstack/react-query'

export function useRemoteQuery<T>(queryKey: readonly unknown[], queryFn: () => Promise<T>, enabled = true) {
  return useQuery({ queryKey, queryFn, enabled, retry: false })
}
