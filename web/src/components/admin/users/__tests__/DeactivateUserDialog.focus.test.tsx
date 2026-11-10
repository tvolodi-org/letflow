// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { DeactivateUserDialog } from '../DeactivateUserDialog'

expect.extend(jestDomMatchers)
afterEach(cleanup)

const base = { open: true, displayName: 'Ada', isSubmitting: false, onCancel: () => {}, onConfirm: () => {} }

describe('DeactivateUserDialog focus (T-1586 D3)', () => {
  it('focuses into the dialog, wraps Tab, closes on Escape unless submitting', () => {
    const onCancel = vi.fn()
    const { rerender } = render(<DeactivateUserDialog {...base} onCancel={onCancel} />)
    const input = screen.getByRole('textbox')
    expect(input).toHaveFocus()
    screen.getByRole('button', { name: 'Deactivate' }).focus()
    fireEvent.keyDown(window, { key: 'Tab' })
    expect(input).toHaveFocus()
    fireEvent.keyDown(window, { key: 'Tab', shiftKey: true })
    expect(screen.getByRole('button', { name: 'Deactivate' })).toHaveFocus()
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onCancel).toHaveBeenCalledTimes(1)
    rerender(<DeactivateUserDialog {...base} onCancel={onCancel} isSubmitting />)
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onCancel).toHaveBeenCalledTimes(1)
  })
})
