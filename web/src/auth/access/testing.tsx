/** Render helper for unit tests: renders `ui` under a fixed access state (a fixture name or a state). */

import { render, type RenderOptions } from '@testing-library/react'
import type { ReactElement } from 'react'
import { AccessStateProvider } from './AccessContext'
import { accessState, type AccessFixtureName } from './fixtures'
import type { AccessState } from './types'

export function renderWithAccess(
  ui: ReactElement,
  access: AccessFixtureName | AccessState = 'platformAdmin',
  options?: Omit<RenderOptions, 'wrapper'>,
) {
  const state = typeof access === 'string' ? accessState(access) : access
  return render(<AccessStateProvider state={state}>{ui}</AccessStateProvider>, options)
}
