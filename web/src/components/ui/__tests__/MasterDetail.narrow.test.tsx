// @vitest-environment jsdom
/** T-1183: under 900px a selected record replaces the list; data-detail, the back button, Escape, the labels. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import { DetailHeader } from '../DetailHeader'
import { MasterDetail } from '../MasterDetail'
import { uiMessages } from '../uiMessages'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'

expect.extend(jestDomMatchers)
afterEach(() => {
  cleanup()
  act(() => useUiLocaleStore.getState().setLocaleTransient('en'))
})

/** A screen the way the real ones work: a row opens the record, back / close / Escape clear the selection. */
function Screen() {
  const [sel, setSel] = useState<string | null>(null)
  return (
    <div
      onKeyDown={(e) => {
        if (e.key === 'Escape' && sel !== null) setSel(null)
      }}
    >
      <MasterDetail
        detailOpen={sel !== null}
        onBack={() => setSel(null)}
        master={<button onClick={() => setSel('a')}>row a</button>}
        detail={sel !== null ? <DetailHeader title={`Record ${sel}`} /> : <p>pick</p>}
      />
    </div>
  )
}

describe('MasterDetail narrow screens', () => {
  it('data-detail follows the selection and the detail section is lf-md__detail', async () => {
    render(<Screen />)
    const md = screen.getByTestId('master-detail')
    expect(md).not.toHaveAttribute('data-detail')
    expect(screen.getByTestId('master-detail-detail')).toHaveClass('lf-md__detail')
    await userEvent.click(screen.getByText('row a'))
    expect(md).toHaveAttribute('data-detail', 'open')
    expect(screen.getByRole('heading', { name: 'Record a' })).toBeInTheDocument()
  })

  it('the back button calls onBack, is a lf-md__back button and is reachable by keyboard', async () => {
    const onBack = vi.fn()
    render(<MasterDetail detailOpen onBack={onBack} master={<p>list</p>} detail={<DetailHeader title="R" />} />)
    const back = screen.getByRole('button', { name: 'Back to the list' })
    expect(back).toHaveClass('lf-md__back')
    await userEvent.tab()
    expect(back).toHaveFocus()
    await userEvent.keyboard('{Enter}')
    expect(onBack).toHaveBeenCalledTimes(1)
  })

  it('back clears the selection in a screen; Escape closes too', async () => {
    render(<Screen />)
    await userEvent.click(screen.getByText('row a'))
    await userEvent.click(screen.getByTestId('master-detail-back'))
    expect(screen.getByTestId('master-detail')).not.toHaveAttribute('data-detail')
    await userEvent.click(screen.getByText('row a'))
    await userEvent.keyboard('{Escape}')
    expect(screen.getByTestId('master-detail')).not.toHaveAttribute('data-detail')
  })

  it('no back button without onBack', () => {
    render(<MasterDetail master={<p>l</p>} detail={<DetailHeader title="R" />} />)
    expect(screen.queryByTestId('master-detail-back')).not.toBeInTheDocument()
  })

  it.each(['en', 'ru', 'kk'] as const)('the back label exists in %s and is shown', (lang) => {
    expect(uiMessages[lang].back.length).toBeGreaterThan(0)
    act(() => useUiLocaleStore.getState().setLocaleTransient(lang))
    render(<MasterDetail detailOpen onBack={() => {}} master={<p>l</p>} detail={<DetailHeader title="R" />} />)
    expect(screen.getByTestId('master-detail-back')).toHaveTextContent(uiMessages[lang].back)
  })
})
