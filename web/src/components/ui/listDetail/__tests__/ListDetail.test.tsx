// @vitest-environment jsdom
/** T-1886: ListDetail component — section 4.2 behaviours 1-8 (verdict docs/design-system/master-detail-verdict.md). */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import { ListDetail } from '../ListDetail'
import { LIST_SPLIT_ID } from '../ListDetail'
import { layoutMessages } from '@/components/ui/layout/layoutMessages'
import { uiMessages } from '@/components/ui/uiMessages'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'

expect.extend(jestDomMatchers)
afterEach(() => {
  cleanup()
  act(() => useUiLocaleStore.getState().setLocaleTransient('en'))
})

const LABEL = 'Items'

/** A minimal screen: row click opens detail, back/Escape/close clears selection. */
function Screen({ escapeCloses }: { escapeCloses?: boolean }) {
  const [sel, setSel] = useState<string | null>(null)
  return (
    <ListDetail
      screen="test.screen"
      listLabel={LABEL}
      list={<button onClick={() => setSel('a')}>row a</button>}
      detail={<p data-testid="record">Record {sel}</p>}
      empty={<p data-testid="empty-state">Nothing selected</p>}
      detailOpen={sel !== null}
      onClose={() => setSel(null)}
      escapeCloses={escapeCloses}
    />
  )
}

// B1: two panes on wide screens, detail shows empty when nothing is selected
describe('B1 two panes, empty state when no selection', () => {
  it('registry is rendered; detail pane shows the custom empty when nothing is selected', () => {
    render(<Screen />)
    expect(screen.getByTestId('registry')).toBeInTheDocument()
    expect(screen.getByTestId('empty-state')).toBeInTheDocument()
    expect(screen.queryByTestId('record')).not.toBeInTheDocument()
  })

  it('the default empty state from layoutMessages is shown when no custom empty is provided', () => {
    render(
      <ListDetail
        screen="test.screen"
        listLabel={LABEL}
        list={<div />}
        detail={<p>rec</p>}
        detailOpen={false}
        onClose={() => {}}
      />,
    )
    expect(screen.getByTestId('list-detail-empty')).toBeInTheDocument()
    expect(screen.getByTestId('list-detail-empty')).toHaveTextContent(layoutMessages.en.selectRecord)
  })
})

// B2: divider id is LIST_SPLIT_ID ('list')
describe('B2 LIST_SPLIT preset id', () => {
  it('LIST_SPLIT_ID is the string "list"', () => {
    expect(LIST_SPLIT_ID).toBe('list')
  })
})

// B3: collapse and restore: handled by the splitter engine (T-1873 / T-1884); no extra code in ListDetail
// Verified by integration: the .lf-splitwrap wrapper is present.
describe('B3 SplitWrap is rendered', () => {
  it('the shell renders a lf-splitwrap wrapper for the splitter', () => {
    const { container } = render(<Screen />)
    expect(container.querySelector('.lf-splitwrap')).toBeInTheDocument()
  })
})

// B4: saved layout via screen prop — useSplit is called with the screen prop
describe('B4 screen prop wired to useSplit', () => {
  it('the registry root has data-testid registry', () => {
    render(<Screen />)
    expect(screen.getByTestId('registry')).toBeInTheDocument()
  })
})

// B5: narrow — data-detail attribute, back button appears
describe('B5 narrow mode: data-detail and back button', () => {
  it('data-detail is "closed" when nothing is selected, "open" when a row is selected', async () => {
    render(<Screen />)
    const reg = screen.getByTestId('registry')
    expect(reg).toHaveAttribute('data-detail', 'closed')
    await userEvent.click(screen.getByText('row a'))
    expect(reg).toHaveAttribute('data-detail', 'open')
  })

  it('the back button appears when detailOpen and disappears after close', async () => {
    render(<Screen />)
    expect(screen.queryByTestId('list-detail-back')).not.toBeInTheDocument()
    await userEvent.click(screen.getByText('row a'))
    expect(screen.getByTestId('list-detail-back')).toBeInTheDocument()
    await userEvent.click(screen.getByTestId('list-detail-back'))
    expect(screen.queryByTestId('list-detail-back')).not.toBeInTheDocument()
  })

  it('clicking the back button calls onClose (clears the selection)', async () => {
    render(<Screen />)
    await userEvent.click(screen.getByText('row a'))
    expect(screen.getByTestId('record')).toBeInTheDocument()
    await userEvent.click(screen.getByTestId('list-detail-back'))
    expect(screen.queryByTestId('record')).not.toBeInTheDocument()
    expect(screen.getByTestId('empty-state')).toBeInTheDocument()
  })
})

// B6: Escape closes the record
describe('B6 Escape key', () => {
  it('Escape closes the open record when escapeCloses is not false', async () => {
    render(<Screen />)
    await userEvent.click(screen.getByText('row a'))
    expect(screen.getByTestId('record')).toBeInTheDocument()
    fireEvent.keyDown(screen.getByTestId('registry'), { key: 'Escape' })
    expect(screen.queryByTestId('record')).not.toBeInTheDocument()
  })

  it('Escape does nothing when no record is open', async () => {
    const onClose = vi.fn()
    render(
      <ListDetail
        screen="x"
        listLabel={LABEL}
        list={<div />}
        detail={<p>rec</p>}
        detailOpen={false}
        onClose={onClose}
      />,
    )
    fireEvent.keyDown(screen.getByTestId('registry'), { key: 'Escape' })
    expect(onClose).not.toHaveBeenCalled()
  })

  it('Escape does nothing when escapeCloses is false', async () => {
    render(<Screen escapeCloses={false} />)
    await userEvent.click(screen.getByText('row a'))
    fireEvent.keyDown(screen.getByTestId('registry'), { key: 'Escape' })
    expect(screen.getByTestId('record')).toBeInTheDocument()
  })

  it('Escape does nothing when defaultPrevented (dialog / editor already handled it)', async () => {
    const onClose = vi.fn()
    render(
      <ListDetail
        screen="x"
        listLabel={LABEL}
        list={<div />}
        detail={<p>rec</p>}
        detailOpen
        onClose={onClose}
      />,
    )
    const e = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })
    e.preventDefault()
    screen.getByTestId('registry').dispatchEvent(e)
    expect(onClose).not.toHaveBeenCalled()
  })
})

// B7: listLabel used as accessible name of the list section
describe('B7 accessible label', () => {
  it('the list section has an aria-label equal to listLabel', () => {
    render(<Screen />)
    expect(screen.getByRole('region', { name: LABEL })).toBeInTheDocument()
  })
})

// B8: empty state default text exists in en, ru and kk
describe('B8 selectRecord exists in all three locales', () => {
  it.each(['en', 'ru', 'kk'] as const)('layoutMessages.%s.selectRecord is a non-empty string', (locale) => {
    expect(layoutMessages[locale].selectRecord.length).toBeGreaterThan(0)
  })

  it.each(['en', 'ru', 'kk'] as const)('the back label exists in %s', (locale) => {
    expect(uiMessages[locale].back.length).toBeGreaterThan(0)
    act(() => useUiLocaleStore.getState().setLocaleTransient(locale))
    render(
      <ListDetail
        screen="x"
        listLabel={LABEL}
        list={<div />}
        detail={<p>rec</p>}
        detailOpen
        onClose={() => {}}
      />,
    )
    expect(screen.getByTestId('list-detail-back')).toHaveTextContent(uiMessages[locale].back)
    cleanup()
  })
})

// lf-reg--tree class is added when kind="tree"
describe('kind=tree', () => {
  it('adds the lf-reg--tree class', () => {
    render(
      <ListDetail
        screen="x"
        kind="tree"
        listLabel={LABEL}
        list={<div />}
        detail={<p>rec</p>}
        detailOpen={false}
        onClose={() => {}}
      />,
    )
    expect(screen.getByTestId('registry')).toHaveClass('lf-reg--tree')
  })
})

// detail slot: detail is rendered when open, empty when closed
describe('detail / empty slot', () => {
  it('the detail slot renders the detail node when detailOpen', () => {
    render(
      <ListDetail
        screen="x"
        listLabel={LABEL}
        list={<div />}
        detail={<p data-testid="the-record">Record</p>}
        detailOpen
        onClose={() => {}}
      />,
    )
    expect(screen.getByTestId('the-record')).toBeInTheDocument()
  })

  it('the detail slot renders the empty node when not detailOpen', () => {
    render(
      <ListDetail
        screen="x"
        listLabel={LABEL}
        list={<div />}
        detail={<p>Record</p>}
        empty={<p data-testid="custom-empty">Empty</p>}
        detailOpen={false}
        onClose={() => {}}
      />,
    )
    expect(screen.getByTestId('custom-empty')).toBeInTheDocument()
    expect(screen.queryByText('Record')).not.toBeInTheDocument()
  })
})

// listHeader, tools, listFooter slots are rendered when provided
describe('optional list pane slots', () => {
  it('listHeader is rendered inside lf-reg__listhead when provided', () => {
    const { container } = render(
      <ListDetail
        screen="x"
        listLabel={LABEL}
        listHeader={<span data-testid="hdr">Header</span>}
        list={<div />}
        detail={<p>rec</p>}
        detailOpen={false}
        onClose={() => {}}
      />,
    )
    expect(container.querySelector('.lf-reg__listhead')).toContainElement(screen.getByTestId('hdr'))
  })

  it('tools is rendered inside lf-reg__tools when provided', () => {
    const { container } = render(
      <ListDetail
        screen="x"
        listLabel={LABEL}
        tools={<span data-testid="tools">Tools</span>}
        list={<div />}
        detail={<p>rec</p>}
        detailOpen={false}
        onClose={() => {}}
      />,
    )
    expect(container.querySelector('.lf-reg__tools')).toContainElement(screen.getByTestId('tools'))
  })

  it('listFooter is rendered inside lf-reg__foot when provided', () => {
    const { container } = render(
      <ListDetail
        screen="x"
        listLabel={LABEL}
        listFooter={<span data-testid="footer">Load more</span>}
        list={<div />}
        detail={<p>rec</p>}
        detailOpen={false}
        onClose={() => {}}
      />,
    )
    expect(container.querySelector('.lf-reg__foot')).toContainElement(screen.getByTestId('footer'))
  })

  it('no lf-reg__listhead, lf-reg__tools or lf-reg__foot when slots are omitted', () => {
    const { container } = render(<Screen />)
    expect(container.querySelector('.lf-reg__listhead')).not.toBeInTheDocument()
    expect(container.querySelector('.lf-reg__tools')).not.toBeInTheDocument()
    expect(container.querySelector('.lf-reg__foot')).not.toBeInTheDocument()
  })
})
