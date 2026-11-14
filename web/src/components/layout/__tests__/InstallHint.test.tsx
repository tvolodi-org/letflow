// @vitest-environment jsdom
/** O-003 / checklist 19: the install how-to sits on the main screen, can be marked read, and opens again. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { InstallHint } from '../InstallHint'
import { installHintMessages } from '../installHintMessages'
expect.extend(jestDomMatchers)

beforeEach(() => window.localStorage.clear())
afterEach(() => {
  cleanup()
  useUiLocaleStore.getState().setLocaleTransient(null)
})

describe('InstallHint', () => {
  it('H1 unread: how-to open with iPhone and Android steps', () => {
    render(<InstallHint userKey="u1" />)
    expect(screen.getByTestId('install-hint')).toBeInTheDocument()
    expect(screen.getByText(/Add to Home Screen/)).toBeInTheDocument()
    expect(screen.getByText(/Install app/)).toBeInTheDocument()
    expect(screen.queryByTestId('install-hint-open')).toBeNull()
  })

  it('H2 "I have read it" hides it, remembers per user, entry stays and opens it again', async () => {
    const user = userEvent.setup()
    const { unmount } = render(<InstallHint userKey="u1" />)
    await user.click(screen.getByTestId('install-hint-read'))
    expect(screen.queryByTestId('install-hint')).toBeNull()
    expect(screen.getByTestId('install-hint-open')).toBeInTheDocument()
    unmount()
    // remembered after a reload, only for the same user
    render(<InstallHint userKey="u1" />)
    expect(screen.queryByTestId('install-hint')).toBeNull()
    await user.click(screen.getByTestId('install-hint-open'))
    expect(screen.getByTestId('install-hint')).toBeInTheDocument()
    await user.click(screen.getByTestId('install-hint-read'))
    expect(screen.getByTestId('install-hint-open')).toBeInTheDocument()
    cleanup()
    render(<InstallHint userKey="u2" />)
    expect(screen.getByTestId('install-hint')).toBeInTheDocument()
  })

  it.each(['ru', 'kk'] as const)('H3 %s texts exist and differ from English', (loc) => {
    expect(installHintMessages[loc].title).not.toBe(installHintMessages.en.title)
    expect(installHintMessages[loc].read).not.toBe(installHintMessages.en.read)
    expect(installHintMessages[loc].iphoneSteps).toHaveLength(installHintMessages.en.iphoneSteps.length)
    expect(installHintMessages[loc].androidSteps).toHaveLength(installHintMessages.en.androidSteps.length)
  })
})
