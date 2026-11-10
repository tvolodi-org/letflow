/** Mock state of the users import tests; apart from the kit so a vi.mock factory can import it without the page. */
import { vi } from 'vitest'

export const clientMock = { postRaw: vi.fn(), getBlob: vi.fn() }
