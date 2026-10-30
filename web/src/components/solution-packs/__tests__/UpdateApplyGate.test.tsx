// @vitest-environment jsdom
/**
 * Component-level tests — REQ-381 design §4.4 (EO-002 blocked-apply UX).
 *
 * TEST-DESIGNER audit: no component-level test previously covered
 * UpdateApplyGate's client-side pre-block / server-side 409-named-banner
 * split, which is the concrete UI mechanism the acceptance criterion
 * ("attempting to apply with an outstanding decision leaves the update
 * unapplied and shows the endpoint's named unresolved process") maps to.
 * The e2e spec exercises the real flow end-to-end but has never been run
 * (see audit report); this file proves the same logic at the component
 * boundary, runnable without a live backend.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, fireEvent } from '@testing-library/react'
import { UpdateApplyGate } from '../UpdateApplyGate'

expect.extend(jestDomMatchers)

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('UpdateApplyGate — EO-002 client-side pre-block', () => {
  it('TC-1: Apply button is disabled while hasUnresolvedConflicts is true', () => {
    render(
      <UpdateApplyGate
        hasUnresolvedConflicts
        unresolvedCount={1}
        onApply={vi.fn()}
        applyState="idle"
        blockedDetail={null}
      />,
    )

    expect(screen.getByTestId('update-apply-btn')).toBeDisabled()
    expect(screen.getByTestId('update-apply-unresolved-hint')).toHaveTextContent(
      '1 artefact still needs a decision',
    )
  })

  it('TC-2: Apply button is enabled once hasUnresolvedConflicts is false', () => {
    render(
      <UpdateApplyGate
        hasUnresolvedConflicts={false}
        unresolvedCount={0}
        onApply={vi.fn()}
        applyState="idle"
        blockedDetail={null}
      />,
    )

    expect(screen.getByTestId('update-apply-btn')).not.toBeDisabled()
    expect(screen.queryByTestId('update-apply-unresolved-hint')).not.toBeInTheDocument()
  })

  it('TC-3: pluralizes the unresolved-count hint for more than one outstanding artefact', () => {
    render(
      <UpdateApplyGate
        hasUnresolvedConflicts
        unresolvedCount={3}
        onApply={vi.fn()}
        applyState="idle"
        blockedDetail={null}
      />,
    )

    expect(screen.getByTestId('update-apply-unresolved-hint')).toHaveTextContent(
      '3 artefacts still need a decision',
    )
  })

  it('TC-4: Apply button is disabled while a submission is already in flight, even with no unresolved conflicts', () => {
    render(
      <UpdateApplyGate
        hasUnresolvedConflicts={false}
        unresolvedCount={0}
        onApply={vi.fn()}
        applyState="submitting"
        blockedDetail={null}
      />,
    )

    expect(screen.getByTestId('update-apply-btn')).toBeDisabled()
  })

  it('TC-5: clicking an enabled Apply button fires onApply', () => {
    const onApply = vi.fn()
    render(
      <UpdateApplyGate
        hasUnresolvedConflicts={false}
        unresolvedCount={0}
        onApply={onApply}
        applyState="idle"
        blockedDetail={null}
      />,
    )

    fireEvent.click(screen.getByTestId('update-apply-btn'))

    expect(onApply).toHaveBeenCalledTimes(1)
  })
})

describe('UpdateApplyGate — EO-002 server-side authoritative block (409 banner)', () => {
  it('TC-6: a populated blockedDetail renders a banner naming the real unresolved artefact from the endpoint response', () => {
    render(
      <UpdateApplyGate
        hasUnresolvedConflicts={false}
        unresolvedCount={0}
        onApply={vi.fn()}
        applyState="idle"
        blockedDetail={{ artefactType: 'process_definition', artefactId: 'adapted-proc' }}
      />,
    )

    const banner = screen.getByTestId('update-apply-blocked-banner')
    expect(banner).toHaveTextContent('process_definition')
    expect(banner).toHaveTextContent('adapted-proc')
    expect(banner).toHaveAttribute('role', 'alert')
  })

  it('TC-7: no blockedDetail renders no banner', () => {
    render(
      <UpdateApplyGate
        hasUnresolvedConflicts={false}
        unresolvedCount={0}
        onApply={vi.fn()}
        applyState="idle"
        blockedDetail={null}
      />,
    )

    expect(screen.queryByTestId('update-apply-blocked-banner')).not.toBeInTheDocument()
  })

  it('TC-8: the banner names whichever artefact the server response identifies, not a hardcoded value (regression guard against a swapped/stale prop)', () => {
    render(
      <UpdateApplyGate
        hasUnresolvedConflicts={false}
        unresolvedCount={0}
        onApply={vi.fn()}
        applyState="idle"
        blockedDetail={{ artefactType: 'form_definition', artefactId: 'some-other-artefact' }}
      />,
    )

    const banner = screen.getByTestId('update-apply-blocked-banner')
    expect(banner).toHaveTextContent('form_definition')
    expect(banner).toHaveTextContent('some-other-artefact')
    expect(banner).not.toHaveTextContent('process_definition')
  })
})

describe('UpdateApplyGate — REQ-631 part B', () => {
  const base = { hasUnresolvedConflicts: false, unresolvedCount: 0, onApply: vi.fn(), applyState: 'idle' as const, blockedDetail: null }

  it('A1 applyAllowed=false hides the button and shows the restricted message', () => {
    render(<UpdateApplyGate {...base} applyAllowed={false} restrictedMessage="needs manage" />)
    expect(screen.queryByTestId('update-apply-btn')).toBeNull()
    expect(screen.getByTestId('update-apply-restricted')).toHaveTextContent('needs manage')
  })

  it('A1 errorMessage renders as an alert; defaults keep the button and no extras', () => {
    const { unmount } = render(<UpdateApplyGate {...base} errorMessage="boom" />)
    expect(screen.getByTestId('update-apply-error')).toHaveTextContent('boom')
    expect(screen.getByTestId('update-apply-btn')).toBeInTheDocument()
    unmount()
    render(<UpdateApplyGate {...base} />)
    expect(screen.queryByTestId('update-apply-error')).toBeNull()
    expect(screen.queryByTestId('update-apply-restricted')).toBeNull()
  })
})
