// @vitest-environment jsdom
/**
 * Unit tests — REQ-272: PageLayout design-system primitive
 *
 * TC-REQ272-12: renders an h1 with the exact title text
 * TC-REQ272-13: renders the actions slot only when actions is passed
 * TC-REQ272-14: content area is constrained by var(--content-max-width) and renders children
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { PageLayout } from '../PageLayout'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-272 — PageLayout', () => {
  it('TC-REQ272-12: renders an h1 page title with the exact title text', () => {
    render(
      <PageLayout title="Workflow Definitions">
        <div>content</div>
      </PageLayout>,
    )
    const heading = screen.getByRole('heading', { level: 1, name: 'Workflow Definitions' })
    expect(heading).toBeVisible()
    expect(screen.getByTestId('page-layout-title')).toHaveTextContent('Workflow Definitions')
  })

  it('TC-REQ272-13: renders the actions slot when actions is passed', () => {
    render(
      <PageLayout title="Workflow Definitions" actions={<button>New</button>}>
        <div>content</div>
      </PageLayout>,
    )
    const actions = screen.getByTestId('page-layout-actions')
    expect(actions).toBeVisible()
    expect(screen.getByRole('button', { name: 'New' })).toBeInTheDocument()
  })

  it('TC-REQ272-13b: omits the actions slot entirely when actions is not passed', () => {
    render(
      <PageLayout title="Workflow Definitions">
        <div>content</div>
      </PageLayout>,
    )
    expect(screen.queryByTestId('page-layout-actions')).toBeNull()
  })

  it('TC-REQ272-14: content area is constrained by var(--content-max-width) and renders children', () => {
    render(
      <PageLayout title="Workflow Definitions">
        <div data-testid="child-content">child</div>
      </PageLayout>,
    )
    const content = screen.getByTestId('page-layout-content')
    expect(content).toHaveStyle({ maxWidth: 'var(--content-max-width)' })
    expect(screen.getByTestId('child-content')).toBeVisible()
  })

  it('T-1717: header and actions use wrapping classes (base.css), not a fixed inline row', () => {
    render(
      <PageLayout title="Process Definitions" actions={<button>New</button>}>
        <div>content</div>
      </PageLayout>,
    )
    expect(screen.getByTestId('page-layout-header')).toHaveClass('lf-page-layout__header')
    expect(screen.getByTestId('page-layout-header').getAttribute('style')).toBeNull()
    expect(screen.getByTestId('page-layout-actions')).toHaveClass('lf-page-layout__actions')
  })
})
