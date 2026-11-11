// @vitest-environment jsdom
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { afterEach, describe, expect, it } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import { FormattedMessage } from 'react-intl'
import { createModuleIntlProvider } from '../createModuleIntlProvider'

const Provider = createModuleIntlProvider({ en: { hi: 'Hello' }, ru: { hi: 'Привет' }, kk: { hi: 'Сәлем' } })

expect.extend(jestDomMatchers)
afterEach(cleanup)

describe('createModuleIntlProvider', () => {
  it.each([
    ['en', 'Hello'],
    ['ru', 'Привет'],
    ['kk', 'Сәлем'],
  ] as const)('renders a catalog string in %s', (locale, text) => {
    render(
      <Provider locale={locale}>
        <FormattedMessage id="hi" />
      </Provider>,
    )
    expect(screen.getByText(text)).toBeInTheDocument()
  })

  it('falls back to the UI-language store when no locale is given', () => {
    render(
      <Provider>
        <FormattedMessage id="hi" />
      </Provider>,
    )
    expect(screen.getByText(/Hello|Привет|Сәлем/)).toBeInTheDocument()
  })
})
