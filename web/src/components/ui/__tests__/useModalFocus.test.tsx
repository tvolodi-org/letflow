// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { useRef, useState } from 'react'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { useModalFocus } from '../useModalFocus'

expect.extend(jestDomMatchers)
afterEach(cleanup)

function Box({ onClose, busy, empty, label = 'box', children }: { onClose: () => void; busy?: boolean; empty?: boolean; label?: string; children?: React.ReactNode }) {
  const ref = useRef<HTMLDivElement | null>(null)
  useModalFocus(ref, { onClose, busy })
  return (
    <div ref={ref} tabIndex={-1} role="dialog" aria-modal="true" aria-label={label} data-testid={label}>
      {empty ? null : (
        <>
          <button>first</button>
          <button>last</button>
        </>
      )}
      {children}
    </div>
  )
}

function Host({ onClose = () => {}, busy = false }: { onClose?: () => void; busy?: boolean }) {
  const [open, setOpen] = useState(false)
  return (
    <>
      <button onClick={() => setOpen(true)}>opener</button>
      {open && <Box busy={busy} onClose={() => { onClose(); setOpen(false) }} />}
    </>
  )
}

describe('useModalFocus', () => {
  it('D2a: moves focus to the first focusable on open and back to the opener on close', () => {
    render(<Host />)
    const opener = screen.getByText('opener')
    opener.focus()
    fireEvent.click(opener)
    expect(screen.getByText('first')).toHaveFocus()
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(screen.queryByRole('dialog')).toBeNull()
    expect(opener).toHaveFocus()
  })

  it('D2b: Tab and Shift+Tab wrap inside the dialog', () => {
    render(<Box onClose={() => {}} />)
    screen.getByText('last').focus()
    fireEvent.keyDown(window, { key: 'Tab' })
    expect(screen.getByText('first')).toHaveFocus()
    fireEvent.keyDown(window, { key: 'Tab', shiftKey: true })
    expect(screen.getByText('last')).toHaveFocus()
  })

  it('D2b2: Tab pulls focus back in when it is outside', () => {
    render(<><button>outside</button><Box onClose={() => {}} /></>)
    screen.getByText('outside').focus()
    fireEvent.keyDown(window, { key: 'Tab' })
    expect(screen.getByText('first')).toHaveFocus()
  })

  it('D2c: Escape closes, but not while busy', () => {
    const onClose = vi.fn()
    const { rerender } = render(<Box onClose={onClose} busy />)
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).not.toHaveBeenCalled()
    rerender(<Box onClose={onClose} />)
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('D2d: no focusable child focuses the container', () => {
    render(<Box onClose={() => {}} empty />)
    expect(screen.getByRole('dialog')).toHaveFocus()
    fireEvent.keyDown(window, { key: 'Tab' })
    expect(screen.getByRole('dialog')).toHaveFocus()
  })

  it('D4: with a nested dialog only the inner one reacts to Escape', () => {
    const outer = vi.fn()
    const inner = vi.fn()
    render(
      <Box label="outer" onClose={outer}>
        <Box label="inner" onClose={inner} />
      </Box>,
    )
    // The inner dialog focused itself last; Escape comes from inside it.
    screen.getAllByText('first')[1].focus()
    fireEvent.keyDown(screen.getAllByText('first')[1], { key: 'Escape' })
    expect(inner).toHaveBeenCalledTimes(1)
  })

  it('D6: an opener removed while the dialog was open does not throw', () => {
    function Removable() {
      const [stage, setStage] = useState<'closed' | 'open' | 'gone'>('closed')
      return (
        <>
          {stage !== 'gone' && <button onClick={() => setStage('open')}>opener</button>}
          {stage === 'open' && <Box onClose={() => setStage('gone')} />}
        </>
      )
    }
    render(<Removable />)
    fireEvent.click(screen.getByText('opener'))
    expect(() => fireEvent.keyDown(window, { key: 'Escape' })).not.toThrow()
    expect(screen.queryByRole('dialog')).toBeNull()
  })
})
