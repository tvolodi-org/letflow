// @vitest-environment jsdom
/** T-1716: the whole user detail page follows the UI language, role names included. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { renderWithAccess } from '@/auth/access/testing'
import { roleLabel } from '@/auth/access'
import { UI_LOCALES, useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { usersMessages } from '../usersMessages'
expect.extend(jestDomMatchers)

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return { ...actual, useNavigate: () => vi.fn(), useParams: () => ({ userId: 'u1' }) }
})

const user = { id: 'u1', username: 'ann', display_name: 'Ann', email: 'ann@x.io', status: 'active', auth_source: 'oidc', inserted_at: '', updated_at: '' }
const idle = { mutate: vi.fn(), isPending: false }
vi.mock('@/hooks/useAdminUsers', () => ({
  useAdminUser: () => ({ data: user, isLoading: false, isError: false, error: null, refetch: vi.fn() }),
  useAdminRoles: () => ({ data: { items: [{ id: 'r1', name: 'TENANT_ADMIN' }] } }),
  useAdminGroups: () => ({ data: { items: [] } }),
  useUpdateAdminUser: () => idle,
  useDeactivateAdminUser: () => idle,
  useSendPasswordResetInstructions: () => idle,
}))

import UserDetailPage from '../UserDetailPage'

afterEach(cleanup)

describe.each(UI_LOCALES)('T-1716 user detail page, locale %s', (locale) => {
  it('labels, actions and role names follow the language', () => {
    useUiLocaleStore.getState().setLocaleTransient(locale)
    renderWithAccess(<MemoryRouter><UserDetailPage /></MemoryRouter>, 'tenantAdmin')
    const m = usersMessages[locale]
    expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent(m.detailTitle)
    for (const t of [m.back, m.username, m.status, m.displayName, m.email, m.roleAssignments, m.groupMemberships, m.save, m.deactivate]) {
      expect(screen.getAllByText(t).length, t).toBeGreaterThan(0)
    }
    expect(screen.getByText(roleLabel('TENANT_ADMIN', locale))).toBeInTheDocument()
    if (locale !== 'en') {
      expect(m.detailTitle).not.toBe(usersMessages.en.detailTitle)
      expect(screen.queryByText('Role assignments')).toBeNull()
      expect(screen.queryByText('Save changes')).toBeNull()
    }
  })
})
