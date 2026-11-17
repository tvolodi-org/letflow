// @vitest-environment jsdom
/** REQ-838: the two harness routes really reach the warning and clear states used by the screenshot matrix. */
import { afterEach, describe, expect, it } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen, act } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { HarnessPage } from '../HarnessPage'

expect.extend(jestDomMatchers)

function renderHarness(name: string) {
  return render(
    <MemoryRouter initialEntries={[`/__harness/${name}`]}>
      <Routes><Route path="/__harness/:screen/*" element={<HarnessPage />} /></Routes>
    </MemoryRouter>,
  )
}

afterEach(() => {
  cleanup()
  window.localStorage.clear()
})

describe('REQ-838 screenshot fixtures', () => {
  it('warning fixture renders the real form warning', async () => {
    renderHarness('stock-document-negative-warning')
    expect(await screen.findByTestId('negative-balance-warning', {}, { timeout: 7000 })).toHaveTextContent('The balance will become negative')
  }, 10000)

  it('clear fixture loads the same form at the exact balance without a warning', async () => {
    renderHarness('stock-document-negative-clear')
    await screen.findByTestId('document-form')
    expect(await screen.findByLabelText('Quantity')).toHaveValue('5')
    await act(async () => undefined)
    expect(screen.queryByTestId('negative-balance-warning')).not.toBeInTheDocument()
  })
})
