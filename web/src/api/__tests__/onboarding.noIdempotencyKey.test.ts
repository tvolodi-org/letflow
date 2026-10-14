/**
 * ISS-1091 / GH 2437 -- the onboarding create call sends no Idempotency-Key.
 *
 * The backend never read the header (a resubmit of a created slug answers 409 and creates nothing), so
 * sending one promised a replay that did not exist. submitOnboarding now takes only the form values and
 * posts through client.post, with no extra headers.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const post = vi.fn()
const postWithHeaders = vi.fn()

vi.mock('../client', () => ({
  client: {
    post: (...args: unknown[]) => post(...args),
    postWithHeaders: (...args: unknown[]) => postWithHeaders(...args),
  },
}))

import { submitOnboarding } from '../onboarding'

beforeEach(() => {
  post.mockReset()
  postWithHeaders.mockReset()
})

describe('submitOnboarding (ISS-1091)', () => {
  it('posts the body through client.post with no headers argument and never uses postWithHeaders', async () => {
    post.mockResolvedValue({ id: 'ob-1' })

    await submitOnboarding({ slug: 'newco', display_name: 'Newco', hostname: 'newco.example.com' })

    expect(postWithHeaders).not.toHaveBeenCalled()
    expect(post).toHaveBeenCalledTimes(1)
    const call = post.mock.calls[0]!
    expect(call).toHaveLength(2)
    expect(call[0]).toBe('/api/v1/onboarding')
    expect(call[1]).toEqual({ slug: 'newco', display_name: 'Newco', hostname: 'newco.example.com' })
  })

  it('takes exactly one argument: the key parameter is gone', () => {
    expect(submitOnboarding.length).toBe(1)
  })
})
