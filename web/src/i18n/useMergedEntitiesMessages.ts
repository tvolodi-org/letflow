/** useMergedEntitiesMessages -- REQ-553
 *
 *  Returns the bundled entities catalog at once, then layers the tenant's
 *  merged label catalog (GET /api/v1/labels) over it when the reply arrives.
 *  Any failure (network error, error status, a request that never settles)
 *  keeps the bundled catalog: no error screen, no toast.
 *
 *  Plain `useEffect` + `getToken()` on purpose: several screens that render
 *  the provider are tested with react-query mocked wholesale or without an
 *  auth context.
 *
 *  Values stay message strings rendered by `formatMessage` without values, so
 *  they come out as React text nodes. Limit: a future overridable id that has
 *  `{name}` placeholders and is formatted with values is ICU-parsed, and an
 *  override containing a tag would then fall back to the message id.
 */

import { useEffect, useMemo, useState } from 'react'
import { labelsApi } from '@/api/labels'
import { getToken } from '@/api/client'
import { entitiesMessages, resolveUiLocale } from './entitiesMessages'

const OVERRIDABLE_PREFIX = 'entities.'

export function useMergedEntitiesMessages(): Record<string, string> {
  const locale = resolveUiLocale()
  const base = entitiesMessages[locale]
  const [overrides, setOverrides] = useState<Record<string, string> | null>(null)

  useEffect(() => {
    if (!getToken()) return
    let cancelled = false
    labelsApi
      .getMerged(locale)
      .then((reply) => {
        if (cancelled || !reply || reply.locale !== locale || !reply.messages) return
        const accepted: Record<string, string> = {}
        for (const [id, text] of Object.entries(reply.messages)) {
          if (
            typeof text === 'string' &&
            id.startsWith(OVERRIDABLE_PREFIX) &&
            Object.prototype.hasOwnProperty.call(base, id)
          ) {
            accepted[id] = text
          }
        }
        setOverrides(accepted)
      })
      .catch(() => {})
    return () => {
      cancelled = true
    }
  }, [locale, base])

  return useMemo(() => (overrides ? { ...base, ...overrides } : base), [base, overrides])
}
