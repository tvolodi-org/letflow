// @vitest-environment jsdom
/** T-1185 — FetchError and SkeletonLayout are drawn with the shared components and tokens:
 *  a danger Banner with Retry, Skeleton bars, no inline style except the bar width. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { FetchError } from '../FetchError'
import { SkeletonLayout } from '../SkeletonLayout'

expect.extend(jestDomMatchers)
afterEach(cleanup)

describe('T-1185 FetchError', () => {
  it('is a danger Banner with a working Retry button and no inline style', () => {
    const onRetry = vi.fn()
    const { container } = render(<FetchError onRetry={onRetry} />)
    expect(screen.getByTestId('banner')).toHaveAttribute('data-tone', 'danger')
    expect(screen.getByRole('alert')).toHaveTextContent('Something went wrong loading this content.')
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(onRetry).toHaveBeenCalledTimes(1)
    expect(container.querySelectorAll('[style]')).toHaveLength(0)
  })
})

describe('T-1185 SkeletonLayout', () => {
  it('draws rowCount x columns Skeleton bars; only the bar width is inline', () => {
    const { container } = render(
      <SkeletonLayout columns={[{ widthPercent: 30 }, { widthPercent: 70 }]} rowCount={3} />,
    )
    const root = screen.getByLabelText('Loading content')
    expect(root).toHaveAttribute('aria-busy', 'true')
    expect(screen.getAllByTestId('skeleton')).toHaveLength(6)
    expect(root).not.toHaveAttribute('style')
    for (const el of Array.from(container.querySelectorAll('[style]'))) {
      expect(el).toHaveAttribute('data-testid', 'skeleton')
      expect((el as HTMLElement).style.cssText).toMatch(/^width: \d+%;$/)
    }
  })
})
