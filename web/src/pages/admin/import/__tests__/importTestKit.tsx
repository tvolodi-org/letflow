/** Shared helpers of the master data import tests (GH 3650 / REQ-675). */
import { ToastContainer } from '@/components/ui/Toast'
import { fireEvent, render, screen } from '@testing-library/react'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import MasterDataImportPage from '../MasterDataImportPage'
import type { ImportResultRow } from '../importModel'

export { clientMock, INSTALLED } from './importMocks'

export function access(...permissions: string[]): AccessState {
  return { status: 'ready', info: { roles: [], platform_tenant: false, permissions } }
}
export const adminAccess = access('EntitiesRecordsImport', 'EntitiesRecordsExport')

export function renderPage(state: AccessState = adminAccess) {
  return render(
    <AccessStateProvider state={state}>
      <MasterDataImportPage />
      <ToastContainer />
    </AccessStateProvider>,
  )
}

export function xlsxFile(name = 'units.xlsx', bytes = 10): File {
  return new File([new Uint8Array(bytes)], name)
}

export function chooseType(id: string) {
  fireEvent.click(screen.getByRole('radio', { name: new RegExp(`${id}$`) }))
}

export function chooseFile(file: File) {
  fireEvent.change(screen.getByTestId('dropzone-input'), { target: { files: [file] } })
}

export function ok(line: number, outcome: 'created' | 'updated' | 'unchanged', id = `E${line}`): ImportResultRow {
  return { status: 'ok', line, outcome, external_ref: { system: 'erp', id } }
}
export function refused(line: number, type: string, extra: Record<string, unknown> = {}): ImportResultRow {
  return { status: 'error', line, reason: { type, ...extra } }
}

export function apiError(status: number, details?: Record<string, unknown>) {
  return { status, message: 'x', code: String(status), details }
}
