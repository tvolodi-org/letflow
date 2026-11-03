// @vitest-environment jsdom
import { describe, it, expect, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { StatusPill, type StatusGlyph, type StatusTone } from '../StatusPill'

afterEach(cleanup)

describe('T-1166 — StatusPill', () => {
  it('TC-T1166-10: renders the word with a glyph element (never colour alone)', () => {
    render(<StatusPill tone="success">Active</StatusPill>)
    const pill = screen.getByTestId('status-pill')
    expect(pill).toHaveTextContent('Active')
    expect(pill).toContainElement(screen.getByTestId('status-pill-glyph'))
    expect(screen.getByTestId('status-pill-glyph')).toHaveAttribute('aria-hidden', 'true')
  })

  it.each<StatusTone>(['success', 'info', 'warning', 'danger', 'neutral', 'current'])(
    'TC-T1166-11: tone %s maps to its class',
    (tone) => {
      render(<StatusPill tone={tone}>x</StatusPill>)
      expect(screen.getByTestId('status-pill')).toHaveClass(`lf-pill--${tone}`)
      cleanup()
    },
  )

  it.each<[StatusGlyph, string]>([
    ['dot', 'lf-glyph'],
    ['ring', 'lf-glyph--ring'],
    ['half', 'lf-glyph--half'],
    ['triangle', 'lf-glyph--triangle'],
    ['dash', 'lf-glyph--dash'],
  ])('TC-T1166-12: glyph %s maps to its class', (glyph, cls) => {
    render(
      <StatusPill tone="neutral" glyph={glyph}>
        x
      </StatusPill>,
    )
    expect(screen.getByTestId('status-pill-glyph')).toHaveClass(cls)
    cleanup()
  })
})
