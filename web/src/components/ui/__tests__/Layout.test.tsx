// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Package, Ruler } from 'lucide-react'
import { MemoryRouter } from 'react-router-dom'
import { useState } from 'react'
import { Banner } from '../Banner'
import { DetailHeader } from '../DetailHeader'
import { DropZone } from '../DropZone'
import { FileRow } from '../FileRow'
import { LanguageSwitcher, loadLocale } from '../LanguageSwitcher'
import { MasterDetail } from '../MasterDetail'
import { PageHeader } from '../PageHeader'
import { TopBar } from '../TopBar'
import { TypePicker } from '../TypePicker'

expect.extend(jestDomMatchers)
afterEach(() => {
  cleanup()
  window.localStorage.clear()
})

describe('PageHeader', () => {
  it('renders eyebrow, title, lede and actions', () => {
    render(<PageHeader eyebrow="Work" title="Org units" lede="Manage units." actions={<button>Add</button>} />)
    expect(screen.getByRole('heading', { level: 1, name: 'Org units' })).toBeInTheDocument()
    expect(screen.getByText('Work')).toHaveClass('eyebrow')
    expect(screen.getByText('Manage units.')).toHaveClass('lf-pagehead__lede')
    expect(screen.getByTestId('page-header-actions')).toContainElement(screen.getByRole('button', { name: 'Add' }))
  })

  it('omits optional parts when absent', () => {
    render(<PageHeader title="Only title" />)
    expect(screen.queryByTestId('page-header-actions')).not.toBeInTheDocument()
    expect(document.querySelector('.eyebrow')).toBeNull()
  })
})

describe('TopBar', () => {
  it('renders breadcrumbs: links before the current crumb, last one aria-current', () => {
    render(
      <MemoryRouter>
        <TopBar crumbs={[{ label: 'Work', to: '/work' }, { label: 'Org units' }]} end={<span>end</span>} />
      </MemoryRouter>,
    )
    expect(screen.getByRole('navigation', { name: 'Breadcrumb' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Work' })).toHaveAttribute('href', '/work')
    expect(screen.getByText('Org units')).toHaveAttribute('aria-current', 'page')
    expect(screen.getByText('end')).toBeInTheDocument()
  })

  it('menu button toggles through its callback and reflects aria-expanded', async () => {
    const onToggle = vi.fn()
    const { rerender } = render(<TopBar onMenuToggle={onToggle} menuControls="nav" />)
    const btn = screen.getByRole('button', { name: 'Open menu' })
    expect(btn).toHaveAttribute('aria-expanded', 'false')
    expect(btn).toHaveAttribute('aria-controls', 'nav')
    await userEvent.click(btn)
    expect(onToggle).toHaveBeenCalledTimes(1)
    rerender(<TopBar onMenuToggle={onToggle} menuOpen />)
    expect(screen.getByRole('button', { name: 'Close menu' })).toHaveAttribute('aria-expanded', 'true')
  })

  it('no menu button without a callback', () => {
    render(<TopBar />)
    expect(screen.queryByTestId('topbar-menu')).not.toBeInTheDocument()
  })
})

describe('MasterDetail and DetailHeader', () => {
  it('renders master and detail panes', () => {
    render(<MasterDetail master={<p>tree</p>} detail={<p>form</p>} />)
    expect(screen.getByTestId('master-detail-master')).toHaveTextContent('tree')
    expect(screen.getByTestId('master-detail-detail')).toHaveTextContent('form')
  })

  it('DetailHeader shows path, title, status and actions', () => {
    render(<DetailHeader path="Head office / IT" title="IT department" status={<span>Active</span>} actions={<button>Edit</button>} />)
    expect(screen.getByRole('heading', { level: 2, name: 'IT department' })).toBeInTheDocument()
    expect(screen.getByText('Head office / IT')).toHaveClass('lf-detail-head__path')
    expect(screen.getByText('Active')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Edit' })).toBeInTheDocument()
  })
})

describe('Banner', () => {
  it.each(['info', 'success', 'warning', 'danger'] as const)('tone %s', (tone) => {
    render(<Banner tone={tone} title="Heads up">text</Banner>)
    const b = screen.getByTestId('banner')
    expect(b).toHaveClass(`lf-banner--${tone}`)
    expect(b).toHaveAttribute('role', tone === 'danger' ? 'alert' : 'status')
    expect(b).toHaveTextContent('Heads up text')
  })

  it('renders an action', async () => {
    const onRetry = vi.fn()
    render(<Banner tone="danger" action={<button onClick={onRetry}>Retry</button>}>Load failed</Banner>)
    await userEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(onRetry).toHaveBeenCalled()
  })
})

describe('TypePicker', () => {
  function Picker({ onChange }: { onChange?: (id: string) => void }) {
    const [v, setV] = useState<string | null>('catalog_item')
    return (
      <TypePicker
        label="Data type"
        value={v}
        onChange={(id) => {
          setV(id)
          onChange?.(id)
        }}
        types={[
          { id: 'catalog_item', label: 'Items', icon: Package },
          { id: 'uom', label: 'Units of measure', icon: Ruler },
        ]}
      />
    )
  }

  it('is a radio group with the value checked', () => {
    render(<Picker />)
    expect(screen.getByRole('radiogroup', { name: 'Data type' })).toBeInTheDocument()
    expect(screen.getByRole('radio', { name: /Items/ })).toBeChecked()
    expect(screen.getByRole('radio', { name: /Units of measure/ })).not.toBeChecked()
  })

  it('click and arrow keys change the value', async () => {
    const onChange = vi.fn()
    const user = userEvent.setup()
    render(<Picker onChange={onChange} />)
    await user.click(screen.getByText('Units of measure'))
    expect(onChange).toHaveBeenLastCalledWith('uom')
    expect(screen.getByRole('radio', { name: /Units of measure/ })).toBeChecked()
    screen.getByRole('radio', { name: /Units of measure/ }).focus()
    await user.keyboard('{ArrowUp}')
    expect(onChange).toHaveBeenLastCalledWith('catalog_item')
  })
})

describe('DropZone and FileRow', () => {
  const xlsx = (name = 'a.xlsx', bytes = 2048) => new File([new Uint8Array(bytes)], name)

  it('empty state: title, limits, choose button', () => {
    render(<DropZone accept=".xlsx" title="Drop an .xlsx file here" limits="up to 2 MB" onFile={vi.fn()} />)
    expect(screen.getByText('Drop an .xlsx file here')).toBeInTheDocument()
    expect(screen.getByTestId('dropzone')).not.toHaveClass('is-over')
    expect(screen.getByRole('button', { name: 'choose a file' })).toBeInTheDocument()
    expect(screen.getByTestId('dropzone')).toHaveTextContent('up to 2 MB')
  })

  it('drag-over highlights, leave clears', () => {
    render(<DropZone accept=".xlsx" title="Drop" onFile={vi.fn()} />)
    const z = screen.getByTestId('dropzone')
    fireEvent.dragOver(z)
    expect(z).toHaveClass('is-over')
    expect(screen.getByText('Release to upload')).toBeInTheDocument()
    fireEvent.dragLeave(z)
    expect(z).not.toHaveClass('is-over')
  })

  it('a dropped valid file reaches onFile', () => {
    const onFile = vi.fn()
    render(<DropZone accept=".xlsx" maxBytes={4096} title="Drop" onFile={onFile} />)
    const f = xlsx()
    fireEvent.drop(screen.getByTestId('dropzone'), { dataTransfer: { files: [f] } })
    expect(onFile).toHaveBeenCalledWith(f)
  })

  it('a file of the wrong type or too large is refused with an error', () => {
    const onFile = vi.fn()
    render(<DropZone accept=".xlsx" maxBytes={4096} title="Drop" invalidText="Use an .xlsx up to 4 KB" onFile={onFile} />)
    fireEvent.drop(screen.getByTestId('dropzone'), { dataTransfer: { files: [xlsx('a.csv')] } })
    expect(screen.getByRole('alert')).toHaveTextContent('Use an .xlsx up to 4 KB')
    fireEvent.drop(screen.getByTestId('dropzone'), { dataTransfer: { files: [xlsx('a.xlsx', 9000)] } })
    expect(onFile).not.toHaveBeenCalled()
  })

  it('the choose button opens the file input (keyboard reachable) and a picked file reaches onFile', async () => {
    const onFile = vi.fn()
    const user = userEvent.setup()
    render(<DropZone accept=".xlsx" title="Drop" onFile={onFile} />)
    const click = vi.spyOn(screen.getByTestId('dropzone-input'), 'click')
    await user.tab()
    expect(screen.getByRole('button', { name: 'choose a file' })).toHaveFocus()
    await user.keyboard('{Enter}')
    expect(click).toHaveBeenCalled()
    await user.upload(screen.getByTestId('dropzone-input'), xlsx())
    expect(onFile).toHaveBeenCalledTimes(1)
  })

  it('chosen state shows FileRow with size and rows, and Replace opens the picker', async () => {
    render(<DropZone accept=".xlsx" title="Drop" chosen={{ file: xlsx('items.xlsx', 9 * 1024), rows: '4 data rows' }} onFile={vi.fn()} />)
    expect(screen.getByText('items.xlsx')).toHaveClass('lf-file__name')
    expect(screen.getByText('9 KB · 4 data rows')).toBeInTheDocument()
    const click = vi.spyOn(screen.getByTestId('dropzone-input'), 'click')
    await userEvent.click(screen.getByRole('button', { name: 'Replace' }))
    expect(click).toHaveBeenCalled()
  })

  it('FileRow shows an invalid-file error under the row', () => {
    render(<FileRow name="x.xlsx" error="Header row missing" onReplace={vi.fn()} replaceText="Заменить" />)
    expect(screen.getByRole('alert')).toHaveTextContent('Header row missing')
    expect(screen.getByRole('button', { name: 'Заменить' })).toBeInTheDocument()
  })
})

describe('LanguageSwitcher', () => {
  const locales = [
    { code: 'en', label: 'English' },
    { code: 'ru', label: 'Русский' },
    { code: 'kk', label: 'Қазақ тілі' },
  ]

  it('is closed by default and opens a menu with the current item checked', async () => {
    render(<LanguageSwitcher locales={locales} current="ru" onChange={vi.fn()} />)
    expect(screen.queryByRole('menu')).not.toBeInTheDocument()
    const trigger = screen.getByTestId('language-switcher-trigger')
    expect(trigger).toHaveAttribute('aria-expanded', 'false')
    await userEvent.click(trigger)
    expect(screen.getByRole('menu')).toBeInTheDocument()
    expect(screen.getByRole('menuitemradio', { name: /Русский/ })).toHaveAttribute('aria-checked', 'true')
    expect(screen.getByRole('menuitemradio', { name: /English/ })).toHaveAttribute('aria-checked', 'false')
  })

  it('choosing persists per user, calls onChange and closes', async () => {
    const onChange = vi.fn()
    render(<LanguageSwitcher locales={locales} current="en" onChange={onChange} userKey="u-1" />)
    await userEvent.click(screen.getByTestId('language-switcher-trigger'))
    await userEvent.click(screen.getByRole('menuitemradio', { name: /Қазақ/ }))
    expect(onChange).toHaveBeenCalledWith('kk')
    expect(loadLocale('u-1', ['en', 'ru', 'kk'])).toBe('kk')
    expect(loadLocale('u-2', ['en', 'ru', 'kk'])).toBeNull()
    expect(screen.queryByRole('menu')).not.toBeInTheDocument()
  })

  it('loadLocale ignores a stored value that is not an allowed locale', () => {
    window.localStorage.setItem('letflow.locale.u-1', 'xx')
    expect(loadLocale('u-1', ['en', 'ru'])).toBeNull()
  })

  it('Escape closes and returns focus; arrows move between items', async () => {
    const user = userEvent.setup()
    render(<LanguageSwitcher locales={locales} current="en" onChange={vi.fn()} />)
    const trigger = screen.getByTestId('language-switcher-trigger')
    trigger.focus()
    await user.keyboard('{ArrowDown}')
    expect(screen.getByRole('menu')).toBeInTheDocument()
    await user.keyboard('{ArrowDown}')
    expect(screen.getByRole('menuitemradio', { name: /English/ })).toHaveFocus()
    await user.keyboard('{ArrowDown}')
    expect(screen.getByRole('menuitemradio', { name: /Русский/ })).toHaveFocus()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('menu')).not.toBeInTheDocument()
    expect(trigger).toHaveFocus()
  })
})
