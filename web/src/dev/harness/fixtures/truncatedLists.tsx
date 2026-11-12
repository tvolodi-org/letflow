/** Harness twins of three list screens in the "list was cut" state (T-1803). The entity query route answers the
 *  first page as usual and then keeps saying there is more (a new cursor each time), so the shared loop stops at its page cap and the screen
 *  shows the truncated notice; the other routes of the screen are unchanged. */
import type { FixtureRoute, HarnessScreen } from '../types'
import { catalogItemsScreens } from './catalogItems'
import { locationsScreens } from './locations'
import { orgListScreens } from '../orgFixtures'
import { assetsDocumentsScreens } from './assetsDocuments'
import { stockDocumentsScreens } from './stockDocuments'

function neverEnding(routes: FixtureRoute[]): FixtureRoute[] {
  return routes.map((r) => {
    if (!r.match('/api/v1/entities/query', 'POST')) return r
    return {
      ...r,
      reply: (state, path, body) => {
        const res = r.reply(state, path, body)
        const b = res.body as { items?: unknown[] }
        // every answer carries a new cursor (the loop stops on a repeated one)
        const cursor = (body as { cursor?: string } | undefined)?.cursor
        if (cursor) return { status: res.status, body: { items: [], next_cursor: `${cursor}+` } }
        return { status: res.status, body: { ...b, next_cursor: 'more' } }
      },
    }
  })
}

function twin(source: HarnessScreen | undefined, name: string): HarnessScreen[] {
  return source ? [{ ...source, name, routes: neverEnding(source.routes) }] : [  // T-1804: the document forms of stock and assets when a picker list was cut (the normal twins are stock-document-new-receipt, asset-document-new)
  ...twin(stockDocumentsScreens.find((s) => s.name === 'stock-document-new-receipt'), 'stock-document-new-pickers-truncated'),
  ...twin(assetsDocumentsScreens.find((s) => s.name === 'asset-document-new'), 'asset-document-new-pickers-truncated'),
]
}

export const truncatedListScreens: HarnessScreen[] = [
  ...twin(catalogItemsScreens.find((s) => s.name === 'catalog-items'), 'catalog-items-truncated'),
  ...twin(locationsScreens.find((s) => s.name === 'locations'), 'locations-truncated'),
  ...twin(orgListScreens.find((s) => s.name === 'org-units-list'), 'org-units-truncated'),
  // T-1804: the document forms of stock and assets when a picker list was cut (the normal twins are stock-document-new-receipt, asset-document-new)
  ...twin(stockDocumentsScreens.find((s) => s.name === 'stock-document-new-receipt'), 'stock-document-new-pickers-truncated'),
  ...twin(assetsDocumentsScreens.find((s) => s.name === 'asset-document-new'), 'asset-document-new-pickers-truncated'),
]
