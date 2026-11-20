import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('@/api/client', () => ({
  client: { post: vi.fn(async () => ({ id: 't1', status: 'pending' })) },
}))

import { client } from '@/api/client'
import { tasksApi } from '@/api/tasks'

beforeEach(() => vi.clearAllMocks())

describe('tasksApi.reassign', () => {
  it('posts {user_id}, the key the server route requires (not assignee_ref)', async () => {
    await tasksApi.reassign('t1', 'u-42')
    expect(client.post).toHaveBeenCalledWith('/api/v1/tasks/t1/reassign', { user_id: 'u-42' })
    const body = vi.mocked(client.post).mock.calls[0][1] as Record<string, unknown>
    expect(Object.keys(body)).toEqual(['user_id'])
  })
})
