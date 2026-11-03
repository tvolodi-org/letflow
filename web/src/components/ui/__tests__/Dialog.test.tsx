// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import { Dialog } from '../Dialog'
import { ConfirmDialog } from '../ConfirmDialog'

expect.extend(jestDomMatchers)
afterEach(cleanup)

function Harness({ onConfirm = vi.fn() }: { onConfirm?: () => void }) {
  const [open, setOpen] = useState(false)
  return (
    <>
      <button onClick={() => setOpen(true)}>Opener</button>
      <Dialog open={open} title="Move unit" subtitle="Head office" onConfirm={onConfirm} onCancel={() => setOpen(false)}>
        <input aria-label="Parent" />
      </Dialog>
    </>
  )
}

describe('Dialog', () => {
  it('renders nothing while closed', () => {
    render(<Dialog open={false} title="T" onConfirm={vi.fn()} onCancel={vi.fn()} />)
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('is a labelled modal dialog with title, subtitle and size class', () => {
    render(<Dialog open title="Move unit" subtitle="Head office" size="l" onConfirm={vi.fn()} onCancel={vi.fn()} />)
    const d = screen.getByRole('dialog', { name: 'Move unit' })
    expect(d).toHaveAttribute('aria-modal', 'true')
    expect(d).toHaveClass('lf-dialog', 'lf-dialog--l')
    expect(screen.getByText('Head office')).toBeInTheDocument()
  })

  it('focuses the confirm button on open and returns focus to the opener on close', async () => {
    const user = userEvent.setup()
    render(<Harness />)
    const opener = screen.getByRole('button', { name: 'Opener' })
    await user.click(opener)
    expect(screen.getByTestId('dialog-confirm')).toHaveFocus()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(opener).toHaveFocus()
  })

  it('traps Tab and Shift+Tab inside the dialog', async () => {
    const user = userEvent.setup()
    render(<Harness />)
    await user.click(screen.getByRole('button', { name: 'Opener' }))
    // order: close, parent input, cancel, confirm
    expect(screen.getByTestId('dialog-confirm')).toHaveFocus()
    await user.tab()
    expect(screen.getByTestId('dialog-close')).toHaveFocus()
    await user.tab({ shift: true })
    expect(screen.getByTestId('dialog-confirm')).toHaveFocus()
  })

  it('Escape calls onCancel; Escape is ignored while loading', () => {
    const onCancel = vi.fn()
    const { rerender } = render(<Dialog open title="T" onConfirm={vi.fn()} onCancel={onCancel} />)
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onCancel).toHaveBeenCalledTimes(1)
    rerender(<Dialog open isLoading title="T" onConfirm={vi.fn()} onCancel={onCancel} />)
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onCancel).toHaveBeenCalledTimes(1)
  })

  it('loading disables both buttons and marks confirm with the spinner class', () => {
    render(<Dialog open isLoading title="T" onConfirm={vi.fn()} onCancel={vi.fn()} />)
    expect(screen.getByTestId('dialog-confirm')).toBeDisabled()
    expect(screen.getByTestId('dialog-confirm')).toHaveClass('is-loading')
    expect(screen.getByTestId('dialog-cancel')).toBeDisabled()
    expect(screen.getByRole('dialog')).toHaveAttribute('aria-busy', 'true')
  })

  it('shows a write error inside the body', () => {
    render(<Dialog open error="Parent is retired" title="T" onConfirm={vi.fn()} onCancel={vi.fn()} />)
    const err = screen.getByTestId('dialog-error')
    expect(err).toHaveTextContent('Parent is retired')
    expect(screen.getByRole('dialog')).toContainElement(err)
  })

  it('danger variant styles confirm as danger; confirm/cancel texts and clicks work', async () => {
    const user = userEvent.setup()
    const onConfirm = vi.fn()
    render(<Dialog open confirmVariant="danger" confirmText="Retire" cancelText="Keep" title="T" onConfirm={onConfirm} onCancel={vi.fn()} />)
    expect(screen.getByRole('button', { name: 'Keep' })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Retire' }))
    expect(onConfirm).toHaveBeenCalledTimes(1)
    expect(screen.getByRole('button', { name: 'Retire' })).toHaveClass('lf-btn--danger')
  })
})

describe('ConfirmDialog (props kept: body, confirmText, cancelText, isLoading)', () => {
  it('renders body and default en texts, with the old test ids', () => {
    render(<ConfirmDialog open title="Discard?" body="Changes are lost." onConfirm={vi.fn()} onCancel={vi.fn()} />)
    expect(screen.getByTestId('confirm-dialog')).toBeInTheDocument()
    expect(screen.getByText('Changes are lost.')).toBeInTheDocument()
    expect(screen.getByTestId('confirm-dialog-confirm')).toHaveTextContent('Confirm')
    expect(screen.getByTestId('confirm-dialog-cancel')).toHaveTextContent('Cancel')
  })

  it('isLoading disables the buttons; error is shown inside', () => {
    render(<ConfirmDialog open isLoading error="Boom" title="T" body="b" confirmText="Yes" cancelText="No" onConfirm={vi.fn()} onCancel={vi.fn()} />)
    expect(screen.getByTestId('confirm-dialog-confirm')).toBeDisabled()
    expect(screen.getByTestId('confirm-dialog-cancel')).toBeDisabled()
    expect(screen.getByTestId('confirm-dialog-error')).toHaveTextContent('Boom')
  })
})
