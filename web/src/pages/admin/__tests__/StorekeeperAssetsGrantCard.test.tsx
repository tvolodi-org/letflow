// @vitest-environment jsdom
/** T-1570 (D-097) W1: the "Storekeeper: assets" card — states and the full-list save. */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, fireEvent, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import React from 'react'
expect.extend(jestDomMatchers)

const get = vi.fn()
const put = vi.fn()
vi.mock('@/api/roleGrants', () => ({ roleGrantsApi: { get: () => get(), putStorekeeper: (l: unknown) => put(l) } }))
vi.mock('@/api/useTenantScopedQueryKeys', () => ({
  useTenantScopedQueryKeys: () => ({ admin: { roleGrants: () => ['role-grants'] } }),
}))

import StorekeeperAssetsGrantCard from '../StorekeeperAssetsGrantCard'

function renderCard() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <StorekeeperAssetsGrantCard />
    </QueryClientProvider>,
  )
}

const body = (storekeeper: string[]) => ({ storekeeper, grantable: { storekeeper: ['AssetsRead', 'AssetsPost'] } })

describe('StorekeeperAssetsGrantCard', () => {
  beforeEach(() => {
    get.mockReset()
    put.mockReset()
  })
  afterEach(cleanup)

  it('shows the stored grants and saves the FULL list', async () => {
    get.mockResolvedValue(body(['AssetsRead']))
    put.mockResolvedValue(body(['AssetsRead', 'AssetsPost']))
    renderCard()
    const read = await screen.findByTestId('grant-read')
    const post = screen.getByTestId('grant-post')
    expect(read).toBeChecked()
    expect(post).not.toBeChecked()
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled()

    fireEvent.click(post)
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(put).toHaveBeenCalledWith(['AssetsRead', 'AssetsPost']))
    expect(await screen.findByText('Saved.')).toBeInTheDocument()
  })

  it('off means an empty list', async () => {
    get.mockResolvedValue(body(['AssetsRead', 'AssetsPost']))
    put.mockResolvedValue(body([]))
    renderCard()
    fireEvent.click(await screen.findByTestId('grant-read'))
    fireEvent.click(screen.getByTestId('grant-post'))
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(put).toHaveBeenCalledWith([]))
  })

  it('a load error shows a banner with retry; a 404 says the module is missing', async () => {
    get.mockRejectedValueOnce(new Error('boom'))
    renderCard()
    expect(await screen.findByText('Could not load the storekeeper access.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument()
    cleanup()
    get.mockRejectedValueOnce(Object.assign(new Error('nf'), { status: 404 }))
    renderCard()
    expect(await screen.findByText('The asset module is not installed in this company.')).toBeInTheDocument()
  })

  it('a save error is shown and the draft stays', async () => {
    get.mockResolvedValue(body([]))
    put.mockRejectedValue(new Error('x'))
    renderCard()
    fireEvent.click(await screen.findByTestId('grant-read'))
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    expect(await screen.findByText('Could not save. Nothing was changed.')).toBeInTheDocument()
    expect(screen.getByTestId('grant-read')).toBeChecked()
  })
})
