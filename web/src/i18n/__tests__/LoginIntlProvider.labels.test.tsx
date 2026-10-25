// @vitest-environment jsdom
/**
 * REQ-553 -- the public login page wording is fixed: LoginIntlProvider never
 * uses the merged catalog and no request to the labels route is made.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, screen } from '@testing-library/react'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { useIntl } from 'react-intl'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

const { mockGetMerged, mockGetToken } = vi.hoisted(() => ({
  mockGetMerged: vi.fn(),
  mockGetToken: vi.fn(),
}))

vi.mock('@/api/labels', () => ({ labelsApi: { getMerged: mockGetMerged } }))
vi.mock('@/api/client', () => ({ getToken: mockGetToken }))

import { LoginIntlProvider } from '../LoginIntlProvider'
import { loginMessages } from '../loginMessages'

function Probe({ id }: { id: string }) {
  const intl = useIntl()
  return <p data-testid="probe">{intl.formatMessage({ id })}</p>
}

beforeEach(() => {
  vi.spyOn(navigator, 'languages', 'get').mockReturnValue(['en'])
  mockGetToken.mockReturnValue('tok')
  mockGetMerged.mockReset()
  mockGetMerged.mockResolvedValue({ locale: 'en', messages: {} })
})

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('REQ-553 login page is unaffected (AC4)', () => {
  it('T4a renders bundled login text and never calls the labels API', async () => {
    const id = Object.keys(loginMessages.en)[0]
    render(
      <LoginIntlProvider>
        <Probe id={id} />
      </LoginIntlProvider>,
    )
    expect(screen.getByTestId('probe').textContent).toBe(loginMessages.en[id])
    expect(mockGetMerged).not.toHaveBeenCalled()
  })

  it('T4b login provider and page source never reference the labels API or hook', () => {
    for (const rel of ['LoginIntlProvider.tsx', join('..', 'pages', 'LoginPage.tsx')]) {
      const src = readFileSync(join(__dirname, '..', rel), 'utf8')
      expect(src).not.toMatch(/api\/labels|useMergedEntitiesMessages|labelsApi/)
    }
  })
})
