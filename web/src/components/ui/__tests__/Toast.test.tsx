// @vitest-environment jsdom
/**
 * Unit tests — REQ-275: Toast (ToastContainer/ToastItem) design-system primitive
 *
 * TC-REQ275-07: renders nothing (null) when the store is empty
 * TC-REQ275-08: success/warning auto-dismiss from the rendered DOM at 4s; error does not
 *   dismiss at 4s but does at 8s (own test per the design's per-behaviour requirement)
 * TC-REQ275-09: manual close (the close button) removes an error toast from the DOM
 *   independent of its 8s timer having elapsed
 * TC-REQ275-10: cap of 4 rendered items — a 5th toast drops the oldest from the DOM
 * TC-REQ275-11: top-right stacking order — newest-first DOM order (index 0 = topmost)
 * TC-REQ275-12: aria-live="polite" on success/warning items, "assertive" on error items
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup, within, act } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { ToastContainer } from '../Toast'
import { useToast, clearAllToasts } from '../../../hooks/useToast'

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  cleanup()
  clearAllToasts()
  vi.useRealTimers()
})

describe('REQ-275 — Toast (ToastContainer)', () => {
  it('TC-REQ275-07: renders nothing when there are no toasts', () => {
    render(<ToastContainer />)
    expect(screen.queryByTestId('toast-container')).not.toBeInTheDocument()
  })

  it('TC-REQ275-08: success/warning auto-dismiss at 4s; error is sticky', () => {
    render(<ToastContainer />)
    const toast = useToast()
    act(() => {
      toast.success('Task completed successfully')
      toast.warning('Instance is in an error state')
      toast.error('Failed to cancel instance')
    })

    expect(screen.getAllByTestId('toast-item')).toHaveLength(3)

    act(() => {
      vi.advanceTimersByTime(4000)
    })
    // success and warning gone, error remains
    const remainingAt4s = screen.getAllByTestId('toast-item')
    expect(remainingAt4s).toHaveLength(1)
    expect(remainingAt4s[0]).toHaveAttribute('data-variant', 'error')

    act(() => {
      vi.advanceTimersByTime(60000)
    })
    // errors stay until dismissed (NOTES.md section 2)
    expect(screen.getAllByTestId('toast-item')).toHaveLength(1)
  })

  it('TC-REQ275-09: manual close removes an error toast from the DOM before its 8s timer elapses', () => {
    render(<ToastContainer />)
    const toast = useToast()
    act(() => {
      toast.error('Failed to cancel instance')
    })

    const item = screen.getByTestId('toast-item')
    expect(item).toBeInTheDocument()

    const closeBtn = within(item).getByTestId('toast-close')
    fireEvent.click(closeBtn)

    expect(screen.queryByTestId('toast-item')).not.toBeInTheDocument()

    // Advancing past the original 8s must not throw or resurrect anything.
    expect(() => act(() => vi.advanceTimersByTime(8000))).not.toThrow()
    expect(screen.queryByTestId('toast-item')).not.toBeInTheDocument()
  })

  it('TC-REQ275-10: cap of 4 rendered items — a 5th toast drops the oldest from the DOM', () => {
    render(<ToastContainer />)
    const toast = useToast()
    act(() => {
      toast.success('first')
      toast.success('second')
      toast.success('third')
      toast.success('fourth')
    })
    expect(screen.getAllByTestId('toast-item')).toHaveLength(4)

    act(() => {
      toast.success('fifth')
    })
    const items = screen.getAllByTestId('toast-item')
    expect(items).toHaveLength(4)
    expect(screen.queryByText('first')).not.toBeInTheDocument()
    expect(screen.getByText('fifth')).toBeInTheDocument()
  })

  it('TC-REQ275-11: top-right stacking order — DOM order is newest-first (index 0 topmost)', () => {
    render(<ToastContainer />)
    const toast = useToast()
    act(() => {
      toast.success('oldest')
      toast.success('middle')
      toast.success('newest')
    })

    const messages = screen.getAllByTestId('toast-message').map((el) => el.textContent)
    expect(messages).toEqual(['newest', 'middle', 'oldest'])

    const container = screen.getByTestId('toast-container')
    expect(container).toHaveClass('lf-toasts')
  })

  it('TC-REQ275-12: aria-live is "polite" for success/warning and "assertive" for error', () => {
    render(<ToastContainer />)
    const toast = useToast()
    act(() => {
      toast.success('s')
      toast.warning('w')
      toast.error('e')
    })

    const items = screen.getAllByTestId('toast-item')
    const byVariant = Object.fromEntries(
      items.map((el) => [el.getAttribute('data-variant'), el.getAttribute('aria-live')]),
    )
    expect(byVariant.success).toBe('polite')
    expect(byVariant.warning).toBe('polite')
    expect(byVariant.error).toBe('assertive')
  })

  it('info tone renders with the info class and polite status; error is role=alert and sticky', () => {
    render(<ToastContainer />)
    const toast = useToast()
    act(() => {
      toast.info('Linked')
      toast.error('Not saved', { description: 'Try again' })
    })
    const items = screen.getAllByTestId('toast-item')
    const error = items.find((el) => el.getAttribute('data-variant') === 'error')!
    const info = items.find((el) => el.getAttribute('data-variant') === 'info')!
    expect(info).toHaveClass('lf-toast', 'lf-toast--info')
    expect(info).toHaveAttribute('role', 'status')
    expect(error).toHaveClass('lf-toast--danger')
    expect(error).toHaveAttribute('role', 'alert')
    expect(within(error).getByTestId('toast-description')).toHaveTextContent('Try again')
  })

  it('the close button is a named icon button', () => {
    render(<ToastContainer />)
    act(() => {
      useToast().success('ok')
    })
    expect(screen.getByRole('button', { name: 'Dismiss notification' })).toHaveClass('lf-btn--icon')
  })
})
