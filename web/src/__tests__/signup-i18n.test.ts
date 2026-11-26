/** T-2748 -- the sign-up catalog has every id in en, ru and kk, and the screens use only ids that exist. */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { ENTITIES_UI_LOCALES } from '@/i18n/entitiesMessages'
import { signupMessages } from '@/i18n/signupMessages'
import { SlugStatusIds } from './signupSlugIds'

const read = (rel: string) => readFileSync(join(__dirname, '..', rel), 'utf8')

describe('signup catalog', () => {
  it('has the same non-empty ids in every locale', () => {
    const [first, ...rest] = ENTITIES_UI_LOCALES.map(l => Object.keys(signupMessages[l]).sort())
    for (const other of rest) expect(other).toEqual(first)
    for (const l of ENTITIES_UI_LOCALES) for (const [id, text] of Object.entries(signupMessages[l])) expect(text.trim(), `${l}:${id}`).not.toBe('')
  })

  it('every literal id the pages use exists, and every dynamic family is complete', () => {
    for (const [file, prefix] of [
      ['pages/signup/SignupPage.tsx', 'signup.'],
      ['pages/signup/SignupResultPage.tsx', 'signup.result.'],
    ] as const) {
      for (const m of read(file).matchAll(/\bt\('([a-zA-Z.]+)'/g)) expect(signupMessages.en, prefix + m[1]).toHaveProperty(prefix + m[1])
    }
    for (const s of SlugStatusIds) expect(signupMessages.en).toHaveProperty(`signup.slug.${s}`)
    for (const r of ['demo_cap_reached', 'unavailable', 'rate_limited', 'slug_taken', 'internal'])
      expect(signupMessages.en).toHaveProperty(`signup.result.fail.${r}`)
  })
})
