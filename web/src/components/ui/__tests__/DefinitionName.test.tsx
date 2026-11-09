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

  describe('T-1515 edge cases', () => {
    const LONG = 'assets_' + 'very_long_technical_id_'.repeat(8)

    it.each(['en', 'ru', 'kk'] as const)('E1: unknown id falls back to the technical id in %s, never "undefined"', (locale) => {
      act(() => useUiLocaleStore.getState().setLocale(locale))
      const { container } = render(<DefinitionName name="tenant_custom_flow" version="2" />)
      expect(container).toHaveTextContent('tenant_custom_flow v2')
      expect(container.textContent).not.toMatch(/undefined|null|NaN/)
    })

    it.each(['en', 'ru', 'kk'] as const)('E2: missing version keeps label and bare id (no "v", no "undefined") in %s', (locale) => {
      act(() => useUiLocaleStore.getState().setLocale(locale))
      const { container } = render(<DefinitionName name="assets_writeoff" />)
      expect(screen.getByTestId('definition-technical-id').textContent).toBe('assets_writeoff')
      expect(screen.getByTitle('assets_writeoff')).toBeInTheDocument()
      expect(container.textContent).not.toMatch(/undefined|null/)
    })

    it('E3: empty version string is treated as no version', () => {
      const { container } = render(<DefinitionName name="assets_writeoff" version="" />)
      expect(screen.getByTestId('definition-technical-id').textContent).toBe('assets_writeoff')
      expect(container.textContent).not.toMatch(/ v$|undefined/)
      expect(definitionDisplayText('assets_writeoff', '', 'kk')).toBe('Активті есептен шығару')
      expect(definitionDisplayText('unknown_x', '', 'kk')).toBe('unknown_x')
      expect(definitionDisplayText('unknown_x', undefined, 'en')).toBe('unknown_x')
    })

    it('E4: empty name does not render undefined', () => {
      const { container } = render(<DefinitionName name="" version="1" />)
      expect(container.textContent).not.toMatch(/undefined|null/)
      expect(definitionDisplayText('', undefined, 'ru')).toBe('')
    })

    it('E5: prototype-like names are plain text, not catalog hits', () => {
      for (const n of ['constructor', 'toString', '__proto__', 'hasOwnProperty']) {
        const { container, unmount } = render(<DefinitionName name={n} version="1" />)
        expect(container.textContent).toBe(`${n} v1`)
        expect(screen.queryByTestId('definition-technical-id')).toBeNull()
        unmount()
      }
    })

    it('E6: a long unknown id is rendered whole as one text', () => {
      const { container } = render(<DefinitionName name={LONG} version="10.2.3" />)
      expect(container.textContent).toBe(`${LONG} v10.2.3`)
    })

    it('E7: a catalog name with a long version keeps the full id in tooltip and second line', () => {
      const v = '1.0.0-' + 'rc'.repeat(30)
      render(<DefinitionName name="assets_writeoff" version={v} />)
      expect(screen.getByTitle(`assets_writeoff v${v}`)).toBeInTheDocument()
      expect(screen.getByTestId('definition-technical-id')).toHaveTextContent(`assets_writeoff v${v}`)
    })
  })
})
