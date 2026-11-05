/** stockNames — GH 3767 / REQ-724, T-1378. The names of the masters a page of the register points at now come from the
 *  shared reference label (`@/lib/references`): "code - title", never an id. Kept as the stock screens' import point. */
export { useReferenceLabels as useNames } from '@/lib/references/useReferenceLabels'
