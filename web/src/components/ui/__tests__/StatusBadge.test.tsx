// @vitest-environment jsdom
/**
 * Unit tests — StatusBadge, now a thin wrapper over StatusPill (T-1166).
 *
 * The REQ-272/REQ-375/REQ-383 cases keep their ids. Their old assertions were
 * about inline colour tokens and a pulse animation; the badge now renders the
 * design-system pill (tone class + glyph shape + word), so the same cases assert
 * tone and glyph. Every status resolves to a word AND a glyph (never colour alone).
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { StatusBadge } from '../StatusBadge'
import { applyBrandingColors } from '@/theming/applyBranding'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function expectPill(tone: string, glyph: string): void {
  const badge = screen.getByTestId('status-badge')
  expect(badge).toHaveClass('lf-pill', `lf-pill--${tone}`)
  expect(badge).toHaveAttribute('data-tone', tone)
  expect(badge).toHaveAttribute('data-glyph', glyph)
  expect(screen.getByTestId('status-pill-glyph')).toBeInTheDocument()
}

describe('StatusBadge', () => {
  it('TC-REQ272-06: definition/DEPRECATED resolves warning tone, half glyph, and shows the word', () => {
    render(<StatusBadge status="DEPRECATED" domain="definition" />)
    expectPill('warning', 'half')
    expect(screen.getByTestId('status-badge')).toHaveTextContent('DEPRECATED')
    expect(screen.getByTestId('status-badge')).toHaveAttribute('data-status', 'DEPRECATED')
    expect(screen.getByTestId('status-badge')).toHaveAttribute('data-domain', 'definition')
  })

  it('TC-REQ272-07: instance/ERROR resolves danger tone with the triangle glyph', () => {
    render(<StatusBadge status="ERROR" domain="instance" />)
    expectPill('danger', 'triangle')
  })

  it('TC-REQ272-08: instance/ACTIVE resolves info tone with the half glyph (no pulse animation any more)', () => {
    render(<StatusBadge status="ACTIVE" domain="instance" />)
    expectPill('info', 'half')
    expect(screen.getByTestId('status-pill-glyph').getAttribute('style')).toBeNull()
  })

  it('TC-REQ272-09: task/PENDING resolves info tone and now carries a glyph too', () => {
    render(<StatusBadge status="PENDING" domain="task" />)
    expectPill('info', 'half')
  })

  it('TC-REQ272-10: an unresolved (timer, status) pair renders the neutral fallback without throwing', () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect(() => render(<StatusBadge status="EXPIRED" domain="timer" />)).not.toThrow()
    expectPill('neutral', 'ring')
  })

  it('TC-REQ272-11: an unresolved (dlq, status) pair renders the neutral fallback without throwing', () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect(() => render(<StatusBadge status="STUCK" domain="dlq" />)).not.toThrow()
    expectPill('neutral', 'ring')
  })

  it('TC-REQ375-01: rollout/running resolves info tone, half glyph', () => {
    render(<StatusBadge status="running" domain="rollout" />)
    expect(screen.getByTestId('status-badge')).toHaveAttribute('data-domain', 'rollout')
    expectPill('info', 'half')
  })

  it('TC-REQ375-02: rollout/completed resolves success tone, dot glyph', () => {
    render(<StatusBadge status="completed" domain="rollout" />)
    expectPill('success', 'dot')
  })

  it('TC-REQ375-03: rollout-outcome/succeeded resolves success tone', () => {
    render(<StatusBadge status="succeeded" domain="rollout-outcome" />)
    expect(screen.getByTestId('status-badge')).toHaveAttribute('data-domain', 'rollout-outcome')
    expectPill('success', 'dot')
  })

  it('TC-REQ375-04: rollout-outcome/failed resolves danger tone', () => {
    render(<StatusBadge status="failed" domain="rollout-outcome" />)
    expectPill('danger', 'triangle')
  })

  it('TC-REQ375-05: rollout-outcome/pending resolves info tone', () => {
    render(<StatusBadge status="pending" domain="rollout-outcome" />)
    expectPill('info', 'half')
  })

  it('TC-REQ375-06: rollout/"succeeded" (a rollout-outcome value) falls through to the fallback: the two tables are not merged', () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    render(<StatusBadge status="succeeded" domain="rollout" />)
    expectPill('neutral', 'ring')
  })

  it('TC-T1166-01: event-retirement-outcome/skipped is neutral with the dash glyph', () => {
    render(<StatusBadge status="skipped" domain="event-retirement-outcome" />)
    expectPill('neutral', 'dash')
  })

  describe('REQ-383/AC3 — a tenant brand colour change does not alter any StatusBadge resolution', () => {
    it('TC-REQ383-01: definition/DEPRECATED keeps tone and glyph after applyBrandingColors', () => {
      render(<StatusBadge status="DEPRECATED" domain="definition" />)
      const badge = screen.getByTestId('status-badge')
      const before = badge.outerHTML

      applyBrandingColors({ primary: 'rebeccapurple' })

      expect(badge.outerHTML).toBe(before)
    })

    it('TC-REQ383-02: instance/ACTIVE is identical after applyBrandingColors', () => {
      render(<StatusBadge status="ACTIVE" domain="instance" />)
      const badge = screen.getByTestId('status-badge')
      const before = badge.outerHTML

      applyBrandingColors({ primary: 'darkorange' })

      expect(badge.outerHTML).toBe(before)
    })

    it('TC-REQ383-03: no representative badge uses the tenant-controlled current tone', () => {
      render(<StatusBadge status="DEPRECATED" domain="definition" />)
      render(<StatusBadge status="ACTIVE" domain="instance" />)
      render(<StatusBadge status="PENDING" domain="task" />)
      render(<StatusBadge status="running" domain="rollout" />)

      for (const badge of screen.getAllByTestId('status-badge')) {
        expect(badge).not.toHaveClass('lf-pill--current')
        expect(badge.getAttribute('style')).toBeNull()
      }
    })
  })
})
