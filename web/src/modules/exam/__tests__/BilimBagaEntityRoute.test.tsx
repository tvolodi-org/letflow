// @vitest-environment jsdom
/**
 * ISS-0655 regression test for BilimBagaEntityRoute.
 *
 * REQ-343's route adapter renders the generic EntityCrudPage for a known
 * `:entityType` and a 404 message otherwise. `tag` was missing from
 * BILIMBAGA_ENTITY_TYPES, so `isBilimBagaEntityType('tag')` returned false
 * and `/admin/bilimbaga/tag` rendered the 404 branch despite `tag` being a
 * real, write-accepting pack entity type with no other admin screen. This
 * suite proves every wired type -- explicitly including `tag` -- takes the
 * EntityCrudPage branch, and an unknown type still 404s.
 *
 * EntityCrudPage itself is mocked here: its own generic-CRUD behavior is
 * covered by EntityCrudPage.test.tsx. This suite only proves the route
 * adapter's branch decision.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
expect.extend(jestDomMatchers)

vi.mock('@/pages/entities/EntityCrudPage', () => ({
  EntityCrudPage: ({ entityType, writes }: { entityType: string; writes?: { permission?: string } }) => (
    <div
      data-testid="mock-entity-crud-page"
      data-entity-type={entityType}
      data-write-permission={writes?.permission ?? 'default'}
    />
  ),
}))

import BilimBagaEntityRoute from '../BilimBagaEntityRoute'
import { BILIMBAGA_ENTITY_TYPES } from '@/config/bilimbagaEntities'
import { BILIMBAGA_WRITES } from '../bilimbagaWrites'

afterEach(() => cleanup())

function renderAt(entityType: string) {
  return render(
    <MemoryRouter initialEntries={[`/admin/bilimbaga/${entityType}`]}>
      <Routes>
        <Route path="/admin/bilimbaga/:entityType" element={<BilimBagaEntityRoute />} />
      </Routes>
    </MemoryRouter>,
  )
}

describe('ISS-0655 — BilimBagaEntityRoute renders EntityCrudPage for every wired entity type', () => {
  for (const { entityType } of BILIMBAGA_ENTITY_TYPES) {
    it(`renders EntityCrudPage, not 404, for entityType=${entityType}`, () => {
      renderAt(entityType)

      const page = screen.getByTestId('mock-entity-crud-page')
      expect(page).toBeInTheDocument()
      expect(page.getAttribute('data-entity-type')).toBe(entityType)
      expect(screen.queryByTestId('bilimbaga-entity-not-found')).toBeNull()
    })
  }

  it("regression: /admin/bilimbaga/tag specifically renders EntityCrudPage (this is the exact ISS-0655 404)", () => {
    renderAt('tag')

    expect(screen.getByTestId('mock-entity-crud-page').getAttribute('data-entity-type')).toBe('tag')
    expect(screen.queryByTestId('bilimbaga-entity-not-found')).toBeNull()
  })

  it('still 404s for an entity type that is not in BILIMBAGA_ENTITY_TYPES', () => {
    renderAt('not_a_real_entity_type')

    expect(screen.getByTestId('bilimbaga-entity-not-found')).toBeInTheDocument()
    expect(screen.queryByTestId('mock-entity-crud-page')).toBeNull()
  })

  it('GH 2680: every BilimBaga entity type is written through the exam authoring binding', () => {
    for (const { entityType } of BILIMBAGA_ENTITY_TYPES) {
      const { unmount } = renderAt(entityType)
      expect(screen.getByTestId('mock-entity-crud-page').getAttribute('data-write-permission')).toBe(BILIMBAGA_WRITES.permission)
      expect(BILIMBAGA_WRITES.permission).toBe('ExamAuthoringWrite')
      unmount()
    }
  })
})
