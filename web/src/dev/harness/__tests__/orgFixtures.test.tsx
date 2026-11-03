// @vitest-environment jsdom
/** S1: the org screens' fixtures render through the harness, in the language the harness gives. */
import { afterEach, describe, expect, it } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { HarnessPage } from '../HarnessPage'
import { HARNESS_SCREENS } from '../registry'

function renderHarness(screenName: string, query = '') {
  return render(
    <MemoryRouter initialEntries={[`/__harness/${screenName}${query}`]}>
      <Routes>
        <Route path="/__harness/:screen/*" element={<HarnessPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

afterEach(() => {
  cleanup()
  document.documentElement.removeAttribute('data-theme')
  document.documentElement.removeAttribute('lang')
})

describe('org harness screens', () => {
  it('registers the five screens', () => {
    expect(Object.keys(HARNESS_SCREENS)).toEqual(expect.arrayContaining(['org-legal', 'org-sites', 'org-units', 'org-positions', 'org-employees']))
  })

  it('org-units shows the tree and opens a unit in the panel', async () => {
    renderHarness('org-units')
    expect(await screen.findByRole('tree')).toBeTruthy()
    expect((await screen.findByTestId('detail-header')).textContent).toContain('Accounting')
  })

  it('org-positions and org-employees open a record in the panel', async () => {
    renderHarness('org-positions')
    expect((await screen.findByTestId('detail-header')).textContent).toContain('Chief accountant')
    cleanup()
    renderHarness('org-employees')
    expect((await screen.findByTestId('detail-header')).textContent).toContain('Aigerim Sarsenova')
  })

  it('org-units-new-child opens the create-child form with the parent company pre-filled', async () => {
    renderHarness('org-units-new-child')
    const company = (await screen.findByLabelText('Legal company')) as HTMLSelectElement
    await waitFor(() => expect(company.value).not.toBe(''))
  })

  it('org-legal renders in Russian', async () => {
    renderHarness('org-legal', '?lang=ru')
    expect((await screen.findByRole('heading', { level: 1 })).textContent).toBe('Юридические лица')
  })

  it('the empty state shows the empty list with its action', async () => {
    renderHarness('org-sites', '?state=empty')
    expect(await screen.findByTestId('org-empty')).toBeTruthy()
  })
})
