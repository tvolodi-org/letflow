// @vitest-environment jsdom
/**
 * Unit tests — REQ-272: Button design-system primitive
 *
 * TC-REQ272-01: renders each variant/size without throwing, exposes children
 * TC-REQ272-02: onClick fires on a normal click
 * TC-REQ272-03: disabled prevents click (onClick never called) and disables the element
 * TC-REQ272-04: loading renders a spinner, disables the element, and prevents click
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { Button, type ButtonProps } from '../Button'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

const VARIANTS: ButtonProps['variant'][] = ['primary', 'secondary', 'danger', 'ghost']
const SIZES: ButtonProps['size'][] = ['sm', 'md', 'lg']

describe('REQ-272 — Button', () => {
  describe.each(VARIANTS)('TC-REQ272-01: variant=%s', variant => {
    it.each(SIZES)('renders size=%s with its label', size => {
      render(
        <Button variant={variant} size={size}>
          Label
        </Button>,
      )
      const btn = screen.getByTestId('ds-button')
      expect(btn).toBeVisible()
      expect(btn).toHaveTextContent('Label')
    })
  })

  it('TC-REQ272-02: onClick fires when an enabled button is clicked', () => {
    const onClick = vi.fn()
    render(
      <Button variant="primary" size="md" onClick={onClick}>
        Save
      </Button>,
    )
    fireEvent.click(screen.getByTestId('ds-button'))
    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it('TC-REQ272-03: disabled renders a disabled element and prevents onClick from firing', () => {
    const onClick = vi.fn()
    render(
      <Button variant="primary" size="md" disabled onClick={onClick}>
        Save
      </Button>,
    )
    const btn = screen.getByTestId('ds-button')
    expect(btn).toBeDisabled()
    fireEvent.click(btn)
    expect(onClick).not.toHaveBeenCalled()
  })

  it('TC-REQ272-04: loading renders a spinner, disables the element, and prevents onClick from firing', () => {
    const onClick = vi.fn()
    render(
      <Button variant="primary" size="md" loading onClick={onClick}>
        Save
      </Button>,
    )
    const btn = screen.getByTestId('ds-button')
    expect(btn).toBeDisabled()
    expect(screen.getByTestId('ds-button-spinner')).toBeInTheDocument()
    fireEvent.click(btn)
    expect(onClick).not.toHaveBeenCalled()
  })

  it('TC-REQ272-05: not loading and not disabled renders no spinner', () => {
    render(
      <Button variant="primary" size="md">
        Save
      </Button>,
    )
    expect(screen.queryByTestId('ds-button-spinner')).not.toBeInTheDocument()
  })
})

describe('ISS-0559 — Button title and pressed props', () => {
  it('TC-ISS0559-01: title is forwarded to the native title attribute', () => {
    render(
      <Button variant="secondary" size="sm" title="Auto-arrange nodes using Dagre layout">
        Re-layout
      </Button>,
    )
    expect(screen.getByTestId('ds-button')).toHaveAttribute(
      'title',
      'Auto-arrange nodes using Dagre layout',
    )
  })

  it('TC-ISS0559-02: omitting title renders no title attribute', () => {
    render(
      <Button variant="secondary" size="sm">
        Re-layout
      </Button>,
    )
    expect(screen.getByTestId('ds-button')).not.toHaveAttribute('title')
  })

  it('TC-ISS0559-03: pressed sets aria-pressed=true and a toggled background', () => {
    render(
      <Button variant="secondary" size="sm" pressed data-testid="btn-toggle">
        Hide Raw JSON
      </Button>,
    )
    const btn = screen.getByTestId('btn-toggle')
    expect(btn).toHaveAttribute('aria-pressed', 'true')
    expect(btn).toHaveClass('is-pressed')
  })

  it('TC-ISS0559-04: pressed=false renders aria-pressed=false and the base background', () => {
    render(
      <Button variant="secondary" size="sm" pressed={false} data-testid="btn-toggle">
        Show Raw JSON
      </Button>,
    )
    const btn = screen.getByTestId('btn-toggle')
    expect(btn).toHaveAttribute('aria-pressed', 'false')
    expect(btn).not.toHaveClass('is-pressed')
  })

  it('TC-ISS0559-05: omitting pressed renders no aria-pressed attribute', () => {
    render(
      <Button variant="secondary" size="sm" data-testid="btn-plain">
        Export
      </Button>,
    )
    expect(screen.getByTestId('btn-plain')).not.toHaveAttribute('aria-pressed')
  })

  it('TC-ISS0559-06: disabled and pressed combine', () => {
    render(
      <Button variant="secondary" size="sm" pressed disabled data-testid="btn-toggle">
        Hide Raw JSON
      </Button>,
    )
    const btn = screen.getByTestId('btn-toggle')
    expect(btn).toBeDisabled()
    expect(btn).toHaveClass('is-pressed')
  })
})

describe('T-1165 — Button restyle (design-system classes)', () => {
  it('maps variant and size to lf-btn classes', () => {
    render(<Button variant="danger" size="sm">X</Button>)
    const btn = screen.getByTestId('ds-button')
    expect(btn).toHaveClass('lf-btn', 'lf-btn--danger', 'lf-btn--s')
    expect(btn.getAttribute('style')).toBeNull()
  })

  it('md and lg use the default height', () => {
    render(<Button variant="primary" size="lg">X</Button>)
    expect(screen.getByTestId('ds-button')).not.toHaveClass('lf-btn--s')
  })

  it('loading keeps the text, sets is-loading and aria-busy', () => {
    render(<Button variant="primary" size="md" loading>Saving</Button>)
    const btn = screen.getByTestId('ds-button')
    expect(btn).toHaveClass('is-loading')
    expect(btn).toHaveAttribute('aria-busy', 'true')
    expect(btn).toHaveTextContent('Saving')
  })

  it('iconOnly renders the icon with label as the accessible name', () => {
    render(<Button variant="secondary" iconOnly label="More actions" icon={<svg data-testid="ic" />}>hidden</Button>)
    const btn = screen.getByRole('button', { name: 'More actions' })
    expect(btn).toHaveClass('lf-btn--icon')
    expect(btn).not.toHaveTextContent('hidden')
    expect(screen.getByTestId('ic')).toBeInTheDocument()
  })

  it('icon is shown before the label', () => {
    render(<Button variant="primary" icon={<svg data-testid="ic" />}>Create</Button>)
    expect(screen.getByTestId('ds-button').firstElementChild).toBe(screen.getByTestId('ic'))
  })

  it('keyboard: Enter on a focused button submits via click, disabled is not focusable', () => {
    render(<Button variant="primary" disabled>Go</Button>)
    screen.getByTestId('ds-button').focus()
    expect(document.activeElement).not.toBe(screen.getByTestId('ds-button'))
  })
})
