import { describe, expect, it } from 'vitest'
import { assertLocalTarget } from '../e2e/helpers'

describe('assertLocalTarget (T-2947)', () => {
  it('accepts local hosts', () => {
    for (const u of ['http://localhost:4000', 'http://127.0.0.1:4000', 'http://[::1]:4000']) {
      expect(() => assertLocalTarget(u, undefined, {})).not.toThrow()
    }
  })
  it('refuses a remote backend or web base URL with the message', () => {
    expect(() => assertLocalTarget('https://qa.example.org', undefined, {})).toThrow(/QA is not a target; set E2E_ALLOW_REMOTE=1/)
    expect(() => assertLocalTarget('http://127.0.0.1:4000', 'https://qa.example.org', {})).toThrow(/QA is not a target/)
  })
  it('E2E_ALLOW_REMOTE=1 lifts it; E2E_LOCAL_HOSTS names a CI service host', () => {
    expect(() => assertLocalTarget('https://qa.example.org', undefined, { E2E_ALLOW_REMOTE: '1' })).not.toThrow()
    process.env.E2E_LOCAL_HOSTS = 'backend'
    try {
      expect(() => assertLocalTarget('http://backend:4000', undefined, {})).not.toThrow()
    } finally {
      delete process.env.E2E_LOCAL_HOSTS
    }
  })
})
