// @vitest-environment jsdom
/**
 * ISS-0728 — PermissionDenied's recovery link is access-aware for the exam-taker
 * (candidate) fixture. The access state comes from a mocked GET /me/access fixture; the
 * token and session are never read. web/tests/unit/PermissionDenied.test.tsx covers the
 * fixed-copy / no-leak assertions (TC-PD-01..05).
 *
 * Cases:
 *   1. The candidate fixture renders "Go to Exams" linking to /exam.
 *   2. The task-worker fixture still renders "My Tasks" -> /tasks.
 *   3. While access is loading, or failed, the link falls back to "My Tasks" -> /tasks.
 */
import { afterEach, describe, expect, it } from 'vitest'
import { cleanup, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { renderWithAccess } from '@/auth/access/testing'
import { ERROR_STATE, LOADING_STATE } from '@/auth/access/fixtures'
import { PermissionDenied } from '../PermissionDenied'

expect.extend(jestDomMatchers)

afterEach(cleanup)

describe('ISS-0728 — PermissionDenied access-aware recovery link', () => {
  it('the candidate fixture renders "Go to Exams" linking to /exam', () => {
    renderWithAccess(<MemoryRouter><PermissionDenied /></MemoryRouter>, 'candidate')
    expect(screen.getByRole('link', { name: 'Go to Exams' })).toHaveAttribute('href', '/exam')
    expect(screen.queryByRole('link', { name: 'My Tasks' })).not.toBeInTheDocument()
  })

  it('the task-worker fixture still renders "My Tasks" linking to /tasks', () => {
    renderWithAccess(<MemoryRouter><PermissionDenied /></MemoryRouter>, 'taskWorker')
    expect(screen.getByRole('link', { name: 'My Tasks' })).toHaveAttribute('href', '/tasks')
    expect(screen.queryByRole('link', { name: 'Go to Exams' })).not.toBeInTheDocument()
  })

  it.each([
    ['loading', LOADING_STATE],
    ['error', ERROR_STATE],
  ])('while access is %s the link falls back to "My Tasks" linking to /tasks', (_name, state) => {
    renderWithAccess(<MemoryRouter><PermissionDenied /></MemoryRouter>, state)
    expect(screen.getByRole('link', { name: 'My Tasks' })).toHaveAttribute('href', '/tasks')
  })
})
