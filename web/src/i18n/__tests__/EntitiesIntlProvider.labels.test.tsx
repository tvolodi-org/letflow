// @vitest-environment jsdom
/**
 * REQ-553 -- EntitiesIntlProvider layers the tenant's merged label catalog
 * (GET /api/v1/labels) over the bundled entities catalog, as plain text.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, screen, waitFor, act } from '@testing-library/react'
import { readFileSync, readdirSync } from 'node:fs'
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

import { EntitiesIntlProvider } from '../EntitiesIntlProvider'
import { entitiesMessages } from '../entitiesMessages'

const ID_A = 'entities.tag.form.submitError'
const ID_B = 'entities.tag.form.conflictError'

function Probe({ id }: { id: string }) {
  const intl = useIntl()
  return <p data-testid="probe">{intl.formatMessage({ id })}</p>
}

function renderProbe(id = ID_A) {
  return render(
    <EntitiesIntlProvider>
      <Probe id={id} />
    </EntitiesIntlProvider>,
  )
}

const bundled = (id: string) => entitiesMessages.en[id]

beforeEach(() => {
  vi.spyOn(navigator, 'languages', 'get').mockReturnValue(['en'])
  mockGetToken.mockReturnValue('tok')
  mockGetMerged.mockReset()
})

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('REQ-553 plain-text rendering (AC1)', () => {
  it.each(['<img src=x onerror=alert(1)>', '<b>bold</b>'])('T1 renders %s literally', async (text) => {
    mockGetMerged.mockResolvedValue({ locale: 'en', messages: { [ID_A]: text } })
    const { container } = renderProbe()
    await waitFor(() => expect(screen.getByTestId('probe').textContent).toBe(text))
    expect(container.querySelector('img')).toBeNull()
    expect(container.querySelector('b')).toBeNull()
  })

  it('T1 src/i18n code uses no dangerouslySetInnerHTML', () => {
    const dir = join(__dirname, '..')
    const files = readdirSync(dir).filter((f) => /\.tsx?$/.test(f))
    expect(files.length).toBeGreaterThan(0)
    for (const f of files) {
      expect(readFileSync(join(dir, f), 'utf8')).not.toContain('dangerouslySetInnerHTML')
    }
  })
})

describe('REQ-553 merge (AC2)', () => {
  it('T2 tenant text for an overridden id, bundled text for the rest', async () => {
    mockGetMerged.mockResolvedValue({ locale: 'en', messages: { [ID_A]: 'Custom' } })
    renderProbe(ID_A)
    await waitFor(() => expect(screen.getByTestId('probe').textContent).toBe('Custom'))
    cleanup()
    renderProbe(ID_B)
    await waitFor(() => expect(mockGetMerged).toHaveBeenCalledTimes(2))
    expect(screen.getByTestId('probe').textContent).toBe(bundled(ID_B))
  })
})

describe('REQ-553 fallback (AC3)', () => {
  it('T3a network error keeps the bundled text, no alert', async () => {
    mockGetMerged.mockRejectedValue(new TypeError('Failed to fetch'))
    renderProbe()
    await waitFor(() => expect(mockGetMerged).toHaveBeenCalled())
    await act(async () => {})
    expect(screen.getByTestId('probe').textContent).toBe(bundled(ID_A))
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('T3b a 500 keeps the bundled text, no alert', async () => {
    mockGetMerged.mockRejectedValue({ status: 500, message: 'boom' })
    renderProbe()
    await waitFor(() => expect(mockGetMerged).toHaveBeenCalled())
    await act(async () => {})
    expect(screen.getByTestId('probe').textContent).toBe(bundled(ID_A))
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('T3c a request that never settles renders the bundled text at once', () => {
    mockGetMerged.mockReturnValue(new Promise(() => {}))
    renderProbe()
    expect(screen.getByTestId('probe').textContent).toBe(bundled(ID_A))
  })

  it('T3d ignores another locale, non-entities ids, unknown ids and non-strings', async () => {
    mockGetMerged.mockResolvedValue({ locale: 'ru', messages: { [ID_A]: 'Russian' } })
    renderProbe()
    await waitFor(() => expect(mockGetMerged).toHaveBeenCalled())
    await act(async () => {})
    expect(screen.getByTestId('probe').textContent).toBe(bundled(ID_A))
    cleanup()

    mockGetMerged.mockResolvedValue({
      locale: 'en',
      messages: { [ID_A]: 42, 'login.title': 'x', 'entities.nope.unknown': 'y' },
    })
    renderProbe()
    await act(async () => {})
    expect(screen.getByTestId('probe').textContent).toBe(bundled(ID_A))
  })

  it('T5 makes no request without a token', async () => {
    mockGetToken.mockReturnValue(null)
    renderProbe()
    await act(async () => {})
    expect(mockGetMerged).not.toHaveBeenCalled()
    expect(screen.getByTestId('probe').textContent).toBe(bundled(ID_A))
  })
})
