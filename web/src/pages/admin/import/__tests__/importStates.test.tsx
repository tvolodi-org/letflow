// @vitest-environment jsdom
/** S6 restyle: every screen state, the shared components used, and the keyboard rules. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { clearAllToasts } from '@/hooks/useToast'
import { access, chooseFile, clientMock, ok, refused, renderPage, xlsxFile } from './importTestKit'

expect.extend(jestDomMatchers)

const hook = vi.hoisted(() => ({ state: {} as Record<string, unknown>, refetch: vi.fn() }))
vi.mock('@/hooks/useInstalledModules', async () => {
  const kit = await import('./importMocks')
  return { useInstalledModules: () => ({ data: kit.INSTALLED.value, refetch: hook.refetch, ...hook.state }) }
})
vi.mock('@/api/client', async (importOriginal) => {
  const kit = await import('./importMocks')
  return { ...(await importOriginal<object>()), client: kit.clientMock }
})

beforeEach(() => {
  hook.state = {}
  hook.refetch.mockReset()
  clientMock.postRaw.mockReset()
})
afterEach(() => {
  cleanup()
  clearAllToasts()
})

describe('S6 states', () => {
  it('loading: a skeleton, no picker', () => {
    hook.state = { isLoading: true, data: undefined }
    renderPage()
    expect(screen.getByTestId('import-loading')).toHaveAttribute('aria-busy', 'true')
    expect(screen.queryByRole('radiogroup')).not.toBeInTheDocument()
  })

  it('load error: a banner with a retry that refetches', () => {
    hook.state = { isError: true, data: undefined }
    renderPage()
    expect(screen.getByTestId('import-load-error')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('import-load-retry'))
    expect(hook.refetch).toHaveBeenCalledTimes(1)
  })

  it('empty: text and an action that refetches', () => {
    hook.state = { data: [] }
    renderPage()
    expect(screen.getByTestId('import-empty')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Check again' }))
    expect(hook.refetch).toHaveBeenCalledTimes(1)
  })

  it('no permission: the template action is hidden', () => {
    renderPage(access('EntitiesRecordsImport'))
    expect(screen.queryByTestId('import-template')).not.toBeInTheDocument()
  })

  it('write error: shown as a danger banner next to the actions', async () => {
    clientMock.postRaw.mockRejectedValue({ status: 500, message: 'x', code: '500' })
    renderPage()
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('import-check'))
    const err = await screen.findByTestId('import-error')
    expect(err.querySelector('.lf-banner--danger')).not.toBeNull()
  })

  it('success: a toast, the steps all done, and a tally', async () => {
    clientMock.postRaw.mockImplementation(async (path: string) => ({
      results: [ok(2, 'created')],
      ...(path.includes('dry_run') ? { dry_run: true } : {}),
    }))
    renderPage()
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('import-check'))
    await waitFor(() => expect(screen.getByTestId('import-confirm')).toBeEnabled())
    expect(screen.getByText('Ready to import')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('import-confirm'))
    await screen.findByTestId('import-summary')
    expect(await screen.findByTestId('toast-message')).toHaveTextContent('Import finished')
    expect(screen.getAllByTestId('step').every((s) => s.className.includes('is-done'))).toBe(true)
  })

  it('refused rows: pill, error row, mono ids, and why Import is off', async () => {
    clientMock.postRaw.mockResolvedValue({ dry_run: true, results: [ok(2, 'created', 'ITM-1'), refused(3, 'cycle')] })
    renderPage()
    chooseFile(xlsxFile())
    fireEvent.click(screen.getByTestId('import-check'))
    await screen.findByTestId('import-dry-run')
    expect(screen.getByText('Needs fixing')).toBeInTheDocument()
    expect(screen.getByTestId('import-why')).toBeInTheDocument()
    const rows = screen.getAllByTestId('datatable-row')
    expect(rows[1]).toHaveClass('is-error')
    expect(screen.getByText('ITM-1')).toHaveClass('mono')
  })
})

describe('S6 keyboard', () => {
  it('the type picker is a radio group reachable by keyboard; the file choice is a real button', () => {
    renderPage()
    expect(screen.getByRole('radiogroup')).toBeInTheDocument()
    const radios = screen.getAllByRole('radio')
    expect(radios.length).toBeGreaterThan(1)
    expect(radios.every((r) => r.tagName === 'INPUT')).toBe(true)
    expect(screen.getByTestId('dropzone-choose').tagName).toBe('BUTTON')
  })

  it('a file that is not .xlsx is refused at the drop zone, next to it', () => {
    renderPage()
    chooseFile(new File(['x'], 'notes.txt'))
    expect(screen.getByTestId('dropzone-error')).toHaveTextContent('Choose an .xlsx file.')
    expect(screen.getByTestId('import-check')).toBeDisabled()
  })
})
