// @vitest-environment jsdom
/** T1/T2: GH 3650 / REQ-675 criterion 2, the template download. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { access, chooseType, clientMock, renderPage } from './importTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/hooks/useInstalledModules', async () => {
  const kit = await import('./importMocks')
  return { useInstalledModules: () => ({ data: kit.INSTALLED.value }) }
})
vi.mock('@/api/client', async (importOriginal) => {
  const kit = await import('./importMocks')
  return { ...(await importOriginal<object>()), client: kit.clientMock }
})

const downloads: string[] = []

beforeEach(() => {
  clientMock.postBlob.mockReset()
  downloads.length = 0
  URL.createObjectURL = vi.fn(() => 'blob:t')
  URL.revokeObjectURL = vi.fn()
  vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (this: HTMLAnchorElement) {
    downloads.push(this.download)
  })
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('T1 template', () => {
  it('posts the export route with the two filters and saves <type>-template.xlsx', async () => {
    clientMock.postBlob.mockResolvedValue({ blob: new Blob(['x']), contentType: 'x' })
    renderPage()
    chooseType('catalog_uom')
    fireEvent.click(screen.getByTestId('import-template'))
    await waitFor(() => expect(downloads).toEqual(['catalog_uom-template.xlsx']))
    expect(clientMock.postBlob).toHaveBeenCalledWith('/api/v1/entities/records/catalog_uom/export?format=xlsx', {
      entity_type: 'catalog_uom',
      filters: [
        { field: 'external_ref_id', op: 'is_null' },
        { field: 'external_ref_id', op: 'is_not_null' },
      ],
    })
  })

  it('shows a message when the download fails', async () => {
    clientMock.postBlob.mockRejectedValue({ status: 500 })
    renderPage()
    fireEvent.click(screen.getByTestId('import-template'))
    expect(await screen.findByTestId('import-template-failed')).toBeInTheDocument()
  })
})

describe('T2 permission', () => {
  it('has no template button without EntitiesRecordsExport', () => {
    renderPage(access('EntitiesRecordsImport'))
    expect(screen.queryByTestId('import-template')).not.toBeInTheDocument()
  })
})
