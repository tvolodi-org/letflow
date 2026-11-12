// @vitest-environment jsdom
import { render, screen } from '@testing-library/react'
import { IntlProvider } from 'react-intl'
import { describe, expect, it } from 'vitest'
import { TruncatedNotice } from '../TruncatedNotice'

describe('TruncatedNotice', () => {
  it('shows the message with the row count in an info banner', () => {
    render(
      <IntlProvider locale="en" messages={{ 'x.truncated': 'First {count} only' }}>
        <TruncatedNotice messageId="x.truncated" count={10000} />
      </IntlProvider>,
    )
    expect(screen.getByTestId('list-truncated').textContent).toContain('First 10000 only')
    expect(screen.getByTestId('banner').getAttribute('data-tone')).toBe('info')
  })
})
