/** ReferenceLabel — T-1378. One reference value as text ("code - title"), for a detail row or a list cell. */
import { useReferenceLabels } from './useReferenceLabels'
import type { ReferenceType } from './referenceLabel'

export function ReferenceLabel({ type, id }: { type: ReferenceType; id: string | null | undefined }) {
  const label = useReferenceLabels(id ? [{ [type]: [id] }] : [])
  return <>{label(type, id)}</>
}
