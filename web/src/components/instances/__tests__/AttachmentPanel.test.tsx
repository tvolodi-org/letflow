// @vitest-environment jsdom
/**
 * Component-level coverage for AttachmentPanel (REQ-212/387 §3.1) — the
 * upload/list widget mounted on InstanceDetailPage. Mocks @/api/attachments
 * directly (same pattern as AttachmentViewerPage.test.tsx).
 */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

const INSTANCE_ID = 'inst-1'

const list = vi.fn()
const upload = vi.fn()
const del = vi.fn()
const storageUsage = vi.fn()

vi.mock('@/api/attachments', () => ({
  attachmentsApi: {
    list: (...args: unknown[]) => list(...args),
    upload: (...args: unknown[]) => upload(...args),
    delete: (...args: unknown[]) => del(...args),
    storageUsage: (...args: unknown[]) => storageUsage(...args),
  },
}))

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 't',
        display_name: 'Admin',
        loginSource: 'oidc' as const,
        tenant_slug: null,
        tenant_display_name: null,
        tenant_id: 'tenant-1',
        tenant_type: null,
      },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

import { AttachmentPanel } from '@/components/instances/AttachmentPanel'

function renderPanel() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <AttachmentPanel instanceId={INSTANCE_ID} />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

function attachmentFixture(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    id: 'att-1',
    instance_id: INSTANCE_ID,
    file_name: 'delivery-note.pdf',
    content_type: 'application/pdf',
    byte_size: 2048,
    uploaded_by: 'lena',
    description: null,
    created_at: '2026-09-23T00:00:00Z',
    ...overrides,
  }
}

beforeEach(() => {
  // Every render mounts useStorageUsage() -- default it to a resolved value
  // so tests that don't care about AC3 aren't left with a dangling pending
  // query. Tests that DO care (AC3) override this per-call below.
  storageUsage.mockResolvedValue({ used_bytes: 0, allowance_bytes: 1_073_741_824 })
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('AttachmentPanel', () => {
  it('lists existing attachments with a View link to the viewer route', async () => {
    list.mockResolvedValue({
      items: [
        {
          id: 'att-1',
          instance_id: INSTANCE_ID,
          file_name: 'delivery-note.pdf',
          content_type: 'application/pdf',
          byte_size: 2048,
          uploaded_by: 'lena',
          description: null,
          created_at: '2026-09-23T00:00:00Z',
        },
      ],
      next_cursor: null,
    })

    renderPanel()

    await waitFor(() => {
      expect(screen.getByText('delivery-note.pdf')).toBeInTheDocument()
    })
    const link = screen.getByTestId('attachment-view-link')
    expect(link).toHaveAttribute('href', `/instances/${INSTANCE_ID}/attachments/att-1`)
  })

  it('uploads a selected file and refetches the list on success', async () => {
    list.mockResolvedValue({ items: [], next_cursor: null })
    upload.mockResolvedValue({
      id: 'att-2',
      instance_id: INSTANCE_ID,
      file_name: 'new-file.pdf',
      content_type: 'application/pdf',
      byte_size: 100,
      uploaded_by: 'lena',
      description: null,
      created_at: '2026-09-23T00:00:00Z',
    })

    renderPanel()
    await waitFor(() => expect(list).toHaveBeenCalled())

    const user = userEvent.setup()
    const fileInput = screen.getByTestId('attachment-file-input') as HTMLInputElement
    const file = new File(['hello'], 'new-file.pdf', { type: 'application/pdf' })
    await user.upload(fileInput, file)

    await user.click(screen.getByTestId('attachment-upload-button'))

    await waitFor(() => {
      expect(upload).toHaveBeenCalledTimes(1)
    })
    const formData = upload.mock.calls[0][1] as FormData
    expect(formData.get('file')).toBeInstanceOf(File)
  })

  // REQ-392 AC1 — remove action: click, confirm, DELETE call, list updates
  // without a full page reload (asserted here by the fact that no navigation
  // happens between the click and the re-query — the same render tree is
  // used throughout).
  describe('AC1 — remove action', () => {
    it('requires a second confirm click before calling DELETE, then updates the list', async () => {
      // First `list` call returns the one attachment; after the delete's
      // onSuccess invalidates the query, the second call returns none —
      // this is what "updates the list without a full page reload" means in
      // a mocked-API component test: the SAME mounted tree reflects the new
      // list data with no re-render() / remount.
      list.mockResolvedValueOnce({ items: [attachmentFixture()], next_cursor: null })
      list.mockResolvedValueOnce({ items: [], next_cursor: null })
      del.mockResolvedValue(undefined)

      renderPanel()
      await waitFor(() => expect(screen.getByText('delivery-note.pdf')).toBeInTheDocument())

      const user = userEvent.setup()

      // First click only arms the confirm affordance -- must NOT call DELETE yet.
      await user.click(screen.getByTestId('attachment-remove-button'))
      expect(del).not.toHaveBeenCalled()
      expect(screen.getByTestId('attachment-remove-confirm-button')).toBeInTheDocument()

      // Second click (the actual confirm) calls DELETE.
      await user.click(screen.getByTestId('attachment-remove-confirm-button'))

      await waitFor(() => expect(del).toHaveBeenCalledTimes(1))
      expect(del).toHaveBeenCalledWith(INSTANCE_ID, 'att-1')

      // List re-fetches (query invalidation) and the row disappears -- no
      // remount, no navigation, same render() call throughout this test.
      await waitFor(() => {
        expect(screen.queryByText('delivery-note.pdf')).not.toBeInTheDocument()
      })
      expect(list).toHaveBeenCalledTimes(2)
    })

    it('lets the user cancel the confirm without calling DELETE', async () => {
      list.mockResolvedValue({ items: [attachmentFixture()], next_cursor: null })

      renderPanel()
      await waitFor(() => expect(screen.getByText('delivery-note.pdf')).toBeInTheDocument())

      const user = userEvent.setup()
      await user.click(screen.getByTestId('attachment-remove-button'))
      await user.click(screen.getByTestId('attachment-remove-cancel-button'))

      expect(del).not.toHaveBeenCalled()
      expect(screen.getByTestId('attachment-remove-button')).toBeInTheDocument()
    })
  })

  // REQ-392 AC2 — distinct, readable rejection messages naming the specific
  // limit hit, one test per rejection kind (per the acceptance criterion's
  // own "verified by a test for each" wording).
  describe('AC2 — distinct rejection messages', () => {
    it('renders the content-type-not-allowed detail text for a 415', async () => {
      list.mockResolvedValue({ items: [], next_cursor: null })
      upload.mockRejectedValue({
        status: 415,
        code: 'unsupported-media-type',
        message: 'Unsupported Media Type',
        details: {
          detail:
            'content type "video/mp4" is not allowed for attachments; allowed types are: application/pdf, image/jpeg, image/png',
        },
      })

      renderPanel()
      await waitFor(() => expect(list).toHaveBeenCalled())

      const user = userEvent.setup()
      const fileInput = screen.getByTestId('attachment-file-input') as HTMLInputElement
      await user.upload(fileInput, new File(['x'], 'clip.mp4', { type: 'video/mp4' }))
      await user.click(screen.getByTestId('attachment-upload-button'))

      const err = await screen.findByTestId('attachment-upload-error')
      expect(err).toHaveAttribute('data-error-kind', 'content-type')
      expect(err).toHaveTextContent('content type "video/mp4" is not allowed')
      expect(err).toHaveTextContent('application/pdf')
    })

    it('renders the storage-quota-exceeded detail text for a 409, distinct from the 415 message', async () => {
      list.mockResolvedValue({ items: [], next_cursor: null })
      upload.mockRejectedValue({
        status: 409,
        code: 'conflict',
        message: 'Conflict',
        details: { detail: 'tenant storage quota has been reached' },
      })

      renderPanel()
      await waitFor(() => expect(list).toHaveBeenCalled())

      const user = userEvent.setup()
      const fileInput = screen.getByTestId('attachment-file-input') as HTMLInputElement
      await user.upload(fileInput, new File(['x'], 'big.pdf', { type: 'application/pdf' }))
      await user.click(screen.getByTestId('attachment-upload-button'))

      const err = await screen.findByTestId('attachment-upload-error')
      expect(err).toHaveAttribute('data-error-kind', 'quota')
      expect(err).toHaveTextContent('tenant storage quota has been reached')
      // Distinct from the 415 message -- neither mentions the other's wording.
      expect(err).not.toHaveTextContent('content type')
      expect(err).not.toHaveTextContent('not allowed for attachments')
    })
  })

  // REQ-392 AC3 — the storage-usage figure's rendered value changes
  // correctly across an accepted upload and a removal, within one test.
  describe('AC3 — storage-usage figure', () => {
    it('rises after an accepted upload and falls after a removal', async () => {
      list.mockResolvedValue({ items: [attachmentFixture()], next_cursor: null })
      storageUsage.mockResolvedValueOnce({ used_bytes: 2048, allowance_bytes: 1_073_741_824 })

      renderPanel()

      await waitFor(() => {
        expect(screen.getByTestId('attachment-storage-usage')).toHaveTextContent('2.0 KB of 1.0 GB used')
      })

      // Accepted upload -- invalidates the storage-usage query, which
      // refetches a higher figure.
      storageUsage.mockResolvedValueOnce({ used_bytes: 4096, allowance_bytes: 1_073_741_824 })
      upload.mockResolvedValue(attachmentFixture({ id: 'att-2', file_name: 'second.pdf', byte_size: 2048 }))

      const user = userEvent.setup()
      const fileInput = screen.getByTestId('attachment-file-input') as HTMLInputElement
      await user.upload(fileInput, new File(['y'], 'second.pdf', { type: 'application/pdf' }))
      await user.click(screen.getByTestId('attachment-upload-button'))

      await waitFor(() => expect(upload).toHaveBeenCalledTimes(1))
      await waitFor(() => {
        expect(screen.getByTestId('attachment-storage-usage')).toHaveTextContent('4.0 KB of 1.0 GB used')
      })

      // Removal -- invalidates the storage-usage query again, figure falls.
      storageUsage.mockResolvedValueOnce({ used_bytes: 2048, allowance_bytes: 1_073_741_824 })
      del.mockResolvedValue(undefined)

      await user.click(screen.getByTestId('attachment-remove-button'))
      await user.click(screen.getByTestId('attachment-remove-confirm-button'))

      await waitFor(() => expect(del).toHaveBeenCalledTimes(1))
      await waitFor(() => {
        expect(screen.getByTestId('attachment-storage-usage')).toHaveTextContent('2.0 KB of 1.0 GB used')
      })
    })
  })
})
