// @vitest-environment jsdom
/** T-1511: friendly definition names with the technical id as a second line and tooltip; fallback to the id. */
import { describe, it, expect, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, act } from '@testing-library/react'
import { DefinitionName, definitionDisplayText } from '../DefinitionName'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
expect.extend(jestDomMatchers)

afterEach(() => {
  cleanup()
  act(() => useUiLocaleStore.getState().setLocale('en'))
})

describe('DefinitionName', () => {
  it.each([
    ['en', 'Asset write-off'],
    ['ru', 'Списание актива'],
    ['kk', 'Активті есептен шығару'],
  ] as const)('D1: catalog key shows the %s label, the technical id as second line and tooltip', (locale, label) => {
    act(() => useUiLocaleStore.getState().setLocale(locale))
    render(<DefinitionName name="assets_writeoff" version="1.0.0" />)
    expect(screen.getByText(label)).toBeInTheDocument()
    expect(screen.getByTestId('definition-technical-id')).toHaveTextContent('assets_writeoff v1.0.0')
    expect(screen.getByTitle('assets_writeoff v1.0.0')).toBeInTheDocument()
  })

  it('D2: a name without a catalog entry stays one plain text, no second line', () => {
    render(<DefinitionName name="Order" version="3" />)
    expect(screen.getByText('Order v3')).toBeInTheDocument()
    expect(screen.queryByTestId('definition-technical-id')).toBeNull()
  })

  it('D2b: plain-string form follows the same rule', () => {
    expect(definitionDisplayText('assets_writeoff', '1.0.0', 'ru')).toBe('Списание актива v1.0.0')
    expect(definitionDisplayText('Order', '3', 'ru')).toBe('Order v3')
  })
})
