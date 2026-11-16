/** T-2020: the plain print items live inside the one Print menu (portaled to <body>). Opens the menu when it is closed
 *  and returns the item with this test id. */
import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

export async function menuItem(testId: string): Promise<HTMLElement> {
  const trigger = await screen.findByTestId('official-form-menu')
  if (trigger.getAttribute('aria-expanded') !== 'true') await userEvent.click(trigger)
  return screen.findByTestId(testId)
}
