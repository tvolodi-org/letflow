/** Shared helpers of the users import tests (T-1633). */
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { ToastContainer } from '@/components/ui/Toast'
import type { ImportResultRow } from '../../import/importModel'
import UsersImportPage from '../UsersImportPage'

export { clientMock } from './usersImportMocks'

export function renderPage(qc: QueryClient = new QueryClient()) {
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <UsersImportPage />
        <ToastContainer />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

export function xlsxFile(name = 'users.xlsx', bytes = 10): File {
  return new File([new Uint8Array(bytes)], name)
}

export function chooseFile(file: File) {
  fireEvent.change(screen.getByTestId('dropzone-input'), { target: { files: [file] } })
}

export function ok(line: number, outcome: 'created' | 'unchanged'): ImportResultRow {
  return { status: 'ok', line, outcome }
}

export function refused(line: number, type: string, header?: string): ImportResultRow {
  return { status: 'error', line, reason: { type, ...(header ? { header } : {}) } }
}

export function apiError(status: number, details?: Record<string, unknown>) {
  return { status, message: 'x', code: String(status), details }
}
