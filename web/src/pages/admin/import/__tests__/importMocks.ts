/** Mock state of the import tests; kept apart from the kit so a vi.mock factory can import it without the page. */
import { vi } from 'vitest'

export const clientMock = { postRaw: vi.fn(), postBlob: vi.fn() }

export const INSTALLED = {
  value: [
    { module_id: 'org', version: '1' },
    { module_id: 'catalog_items', version: '1' },
  ] as { module_id: string; version: string }[],
}
