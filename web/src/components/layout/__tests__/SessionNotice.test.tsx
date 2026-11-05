// @vitest-environment jsdom
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { SESSION_NOTICE_KEY, SessionNotice } from '../SessionNotice'
expect.extend(jestDomMatchers)

beforeEach(() => sessionStorage.clear())
afterEach(cleanup)

describe('SessionNotice', () => {
  it('SN-01: shows once for the expired flag, clears it, and can be dismissed', async () => {
    sessionStorage.setItem(SESSION_NOTICE_KEY, 'expired')
    render(<SessionNotice />)
    expect(screen.getByTestId('session-notice')).toBeInTheDocument()
    expect(sessionStorage.getItem(SESSION_NOTICE_KEY)).toBeNull()
    await userEvent.click(screen.getByTestId('session-notice-dismiss'))
    expect(screen.queryByTestId('session-notice')).toBeNull()
  })

  it('SN-01b: shows nothing without the flag', () => {
    render(<SessionNotice />)
    expect(screen.queryByTestId('session-notice')).toBeNull()
  })
})
