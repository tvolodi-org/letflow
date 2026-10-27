// @vitest-environment jsdom
/**
 * REQ-343 AC4 — the exam-admin landing page carries a visible, one-line
 * note about the exam_assignment gap (no assignment screen; assignment is
 * enforced since REQ-582, the old session.ex FINDING no-op is gone). Also covers: all ten entity types are
 * reachable from the landing page's own nav cards, and no exam_assignment
 * or parent_id workaround renders anywhere on this page.
 *
 * ISS-0655: `tag` was missing from BILIMBAGA_ENTITY_TYPES (nine, not ten)
 * -- this suite's card-count assertion below is the "all wired types show
 * a card" half of that regression's coverage; the config-vs-pack-directory
 * half lives in web/src/config/__tests__/bilimbagaEntities.test.ts.
 */
import { describe, it, expect, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
expect.extend(jestDomMatchers)

import BilimBagaAdminPage from '../BilimBagaAdminPage'
import { BILIMBAGA_ENTITY_TYPES } from '@/config/bilimbagaEntities'

afterEach(() => cleanup())

describe('REQ-343 AC4 — exam_assignment gap note', () => {
  it('renders a visible note that there is no assignment screen and that assignment is enforced (REQ-582)', () => {
    render(
      <MemoryRouter>
        <BilimBagaAdminPage />
      </MemoryRouter>,
    )

    const note = screen.getByTestId('bilimbaga-exam-assignment-gap-note')
    expect(note).toBeInTheDocument()
    // REQ-582 part B replaced the no-op check_assigned/3: the copy no longer
    // cites the old FINDING section, it says assignment is enforced.
    expect(note.textContent).toContain('no screen here to assign')
    expect(note.textContent).toContain('REQ-582')
    expect(note.textContent).toContain('cannot be started')
  })
})

describe('REQ-343 AC1/AC5 — all ten entity types reachable from this landing page', () => {
  it('renders one nav card per admin-manageable BilimBaga entity type, including tag', () => {
    render(
      <MemoryRouter>
        <BilimBagaAdminPage />
      </MemoryRouter>,
    )

    for (const { entityType } of BILIMBAGA_ENTITY_TYPES) {
      const link = screen.getByTestId(`bilimbaga-nav-${entityType}`)
      expect(link).toBeInTheDocument()
      expect(link.getAttribute('href')).toBe(`/admin/bilimbaga/${entityType}`)
    }
    expect(BILIMBAGA_ENTITY_TYPES).toHaveLength(10)
    expect(screen.getByTestId('bilimbaga-nav-tag')).toBeInTheDocument()
  })
})

describe('REQ-343 AC3 — no exam_assignment or parent_id workaround on this page', () => {
  it('never renders a parent_id field or a fabricated exam_assignment list', () => {
    render(
      <MemoryRouter>
        <BilimBagaAdminPage />
      </MemoryRouter>,
    )

    expect(screen.queryByTestId(/parent_id/)).toBeNull()
    expect(screen.queryByTestId('bilimbaga-nav-exam_assignment')).toBeNull()
  })
})
