// @vitest-environment jsdom
/** W2–W6 — T-1924: the "Official form" menu (ДА-2 / ҰМА-2) in the asset card header. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import type { AccessState } from '@/auth/access/types'
import { clearAllToasts } from '@/hooks/useToast'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { documentsEn, documentsKk, documentsRu } from '../documents/documentsMessages'
import { fakeServer, problem, rec, renderAssets } from './assetsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-assets' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const access = (...permissions: string[]): AccessState => ({ status: 'ready', info: { roles: [], platform_tenant: false, permissions } })
const FULL = access('AssetsCardWrite', 'AssetsRead', 'AssetsPost')
const PATH = '/admin/assets/cards'
const PRINT = '/api/v1/modules/assets/cards/c-1/print'
const DATA = {
  assets_card: [
    rec('c-1', 'assets_card', { inventory_number: 'FA-1', name: 'Asset FA-1', kind: 'fixed' }),
    rec('c-2', 'assets_card', { inventory_number: 'FA-2', name: 'Asset FA-2', kind: 'fixed' }),
    rec('c-8', 'assets_card', { inventory_number: 'FA-8', name: 'Asset FA-8', kind: 'fixed', active: false }),
  ],
}
const file = (cd: string | null) => ({ blob: new Blob(['x']), contentType: 'application/pdf', contentDisposition: cd })
let downloads: string[] = []

const select = async (no: string) => {
  fireEvent.click(await screen.findByText(no))
  await screen.findByTestId('detail-tabs')
}

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  clientMock.get.mockImplementation(async (p: string) => (p.endsWith('/lock') ? { posted: false, held: true } : { rows: [], next_cursor: null }))
  fakeServer(clientMock, DATA)
  useUiLocaleStore.getState().setLocaleTransient('en')
  downloads = []
  URL.createObjectURL = vi.fn(() => 'blob:x')
  URL.revokeObjectURL = vi.fn()
  vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (this: HTMLAnchorElement) {
    downloads.push(this.download)
  })
})
afterEach(() => {
  cleanup()
  clearAllToasts()
  vi.restoreAllMocks()
})

describe('W2 the menu', () => {
  it.each([
    ['en', 'DA-2 form'],
    ['ru', 'Форма ДА-2'],
    ['kk', 'ҰМА-2 нысаны'],
  ] as const)('an active card offers only the DA-2 form in %s', async (loc, label) => {
    useUiLocaleStore.getState().setLocaleTransient(loc)
    renderAssets(PATH, FULL)
    await select('FA-1')
    fireEvent.click(screen.getByTestId('official-form-menu'))
    expect(screen.getByTestId('form-da2-pdf')).toHaveTextContent(label)
    expect(screen.getByTestId('form-da2-docx')).toHaveTextContent(label)
    for (const other of ['da1', 'da3', 'da4']) {
      expect(screen.queryByTestId(`form-${other}-pdf`)).toBeNull()
      expect(screen.queryByTestId(`form-${other}-docx`)).toBeNull()
    }
  })
  it('a retired card has the menu too', async () => {
    renderAssets(PATH, FULL)
    fireEvent.click(await screen.findByLabelText(/show retired/i))
    await select('FA-8')
    expect(screen.getByTestId('official-form-menu')).toBeInTheDocument()
  })
})

describe('W3 permission', () => {
  it('without AssetsRead the card panel has no menu', async () => {
    renderAssets(PATH, access('AssetsCardWrite'))
    await select('FA-1')
    expect(screen.queryByTestId('official-form-menu')).toBeNull()
  })
})

describe('W4 download', () => {
  it('picking the .docx calls the card route with the UI language and saves a fallback name', async () => {
    clientMock.getBlob.mockResolvedValue(file(null))
    renderAssets(PATH, FULL)
    await select('FA-1')
    fireEvent.click(screen.getByTestId('official-form-menu'))
    fireEvent.click(screen.getByTestId('form-da2-docx'))
    await waitFor(() => expect(downloads).toEqual(['FA-1_DA-2.docx']))
    expect(clientMock.getBlob).toHaveBeenCalledWith(PRINT, { form: 'da2', format: 'docx', lang: 'ru' })
  })
  it('the Kazakh UI asks for kk', async () => {
    useUiLocaleStore.getState().setLocaleTransient('kk')
    clientMock.getBlob.mockResolvedValue(file('attachment; filename="X_DA-2.pdf"'))
    renderAssets(PATH, FULL)
    await select('FA-1')
    fireEvent.click(screen.getByTestId('official-form-menu'))
    fireEvent.click(screen.getByTestId('form-da2-pdf'))
    await waitFor(() => expect(downloads).toEqual(['X_DA-2.pdf']))
    expect(clientMock.getBlob).toHaveBeenCalledWith(PRINT, { form: 'da2', format: 'pdf', lang: 'kk' })
  })
})

describe('W5 errors and busy state', () => {
  it('a 422 shows the banner for that card only', async () => {
    clientMock.getBlob.mockRejectedValue(problem(422, { reason: 'print_unsupported_character' }))
    renderAssets(PATH, FULL)
    await select('FA-1')
    fireEvent.click(screen.getByTestId('official-form-menu'))
    fireEvent.click(screen.getByTestId('form-da2-pdf'))
    const box = await screen.findByTestId('card-print-error')
    expect(box).toHaveTextContent(documentsEn['assets.doc.print.reason.print_unsupported_character']!)
    fireEvent.click(screen.getByText('FA-2'))
    await waitFor(() => expect(screen.queryByTestId('card-print-error')).toBeNull())
  })
  it('a 404 names the card', async () => {
    clientMock.getBlob.mockRejectedValue(problem(404, {}))
    renderAssets(PATH, FULL)
    await select('FA-1')
    fireEvent.click(screen.getByTestId('official-form-menu'))
    fireEvent.click(screen.getByTestId('form-da2-pdf'))
    expect(await screen.findByTestId('card-print-error')).toHaveTextContent(documentsEn['assets.doc.form.cardNotFound']!)
  })
  it('while the file is on its way the trigger is busy and disabled', async () => {
    let done: (v: ReturnType<typeof file>) => void = () => {}
    clientMock.getBlob.mockReturnValue(new Promise((res) => { done = res }))
    renderAssets(PATH, FULL)
    await select('FA-1')
    fireEvent.click(screen.getByTestId('official-form-menu'))
    fireEvent.click(screen.getByTestId('form-da2-pdf'))
    await waitFor(() => expect(screen.getByTestId('official-form-menu')).toHaveAttribute('aria-busy', 'true'))
    expect(screen.getByTestId('official-form-menu')).toBeDisabled()
    done(file(null))
    await waitFor(() => expect(downloads).toEqual(['FA-1_DA-2.pdf']))
  })
})

describe('W6 catalogs', () => {
  it('the two new keys exist in ru and kk and differ from en', () => {
    for (const k of ['assets.doc.form.da2', 'assets.doc.form.cardNotFound']) {
      expect(documentsRu[k]?.trim(), k).toBeTruthy()
      expect(documentsKk[k]?.trim(), k).toBeTruthy()
      expect(documentsRu[k]).not.toBe(documentsEn[k])
      expect(documentsKk[k]).not.toBe(documentsEn[k])
    }
  })
})
