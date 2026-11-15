/** AssetCountWork — T-1933 / REQ-822 (K7a). The slot below the facts of an order where K7b (count sheet) and K7c (result,
 *  signing, print) add their panels. It renders nothing in K7a. */
import type { AssetCountOrder } from './assetCounts.api'

export function AssetCountWork({ order }: { order: AssetCountOrder }) {
  void order
  return null
}
