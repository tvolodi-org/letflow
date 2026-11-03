// @vitest-environment jsdom
/** P1/P2: GH 3650 / REQ-675 criterion 1, the picker and the module lists. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen } from '@testing-library/react'
import { REGISTERED_MODULES, getInstalledImportTypes } from '@/modules/registry'
import { INSTALLED, renderPage } from './importTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/hooks/useInstalledModules', async () => {
  const kit = await import('./importMocks')
  return { useInstalledModules: () => ({ data: kit.INSTALLED.value }) }
})
vi.mock('@/api/client', async (importOriginal) => {
  const kit = await import('./importMocks')
  return { ...(await importOriginal<object>()), client: kit.clientMock }
})

afterEach(() => cleanup())

describe('P1 picker', () => {
  it('lists the types of the installed modules only, in registry order', () => {
    INSTALLED.value = [
      { module_id: 'catalog_items', version: '1' },
      { module_id: 'org', version: '1' },
    ]
    renderPage()
    const options = screen.getAllByRole('radio').map((o) => o.getAttribute('value'))
    expect(options).toEqual(['org_unit', 'org_position', 'org_employee', 'catalog_uom', 'catalog_item', 'catalog_counterparty', 'catalog_lot'])
    expect(options).not.toContain('location_node')
  })

  it('shows a message and no picker when no module lists a type', () => {
    INSTALLED.value = [{ module_id: 'exam', version: '1' }]
    renderPage()
    expect(screen.queryByRole('radiogroup')).not.toBeInTheDocument()
    expect(screen.getByText('No importable data types are installed.')).toBeInTheDocument()
  })
})

describe('P2 module lists', () => {
  it('the three modules list exactly the eight types in order', () => {
    const all = getInstalledImportTypes(REGISTERED_MODULES.map((m) => ({ module_id: m.id, version: '1' })))
    expect(all.map((t) => t.entityType)).toEqual([
      'org_unit',
      'org_position',
      'org_employee',
      'location_node',
      'catalog_uom',
      'catalog_item',
      'catalog_counterparty',
      'catalog_lot',
    ])
  })

  it('I2: every import type has a non-empty en, ru and kk label', () => {
    for (const t of getInstalledImportTypes(REGISTERED_MODULES.map((m) => ({ module_id: m.id, version: '1' })))) {
      for (const locale of ['en', 'ru', 'kk'] as const) {
        expect(t.labels[locale], `${t.entityType} ${locale}`).toBeTruthy()
      }
    }
  })
})
