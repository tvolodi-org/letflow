/** saveErrorText — the text of a refused or failed save, by status class (T-1553).
 *  The server's `message`, `code` and `details` never reach the screen (same rule as `taskErrorText`);
 *  only the status class and the Retry-After seconds are used. */
import { fillFeedback, type FeedbackMessages } from '@/components/ui/feedbackMessages'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'

export function saveErrorText(err: unknown, m: FeedbackMessages): string {
  const status =
    err && typeof err === 'object' && typeof (err as { status?: unknown }).status === 'number'
      ? (err as { status: number }).status
      : null
  if (status === 400 || status === 422) return m.saveInvalid
  if (status === 401 || status === 403) return m.saveForbidden
  if (status === 404) return m.saveNotFound
  if (status === 409) return m.saveConflict
  if (status === 429) {
    const wait = getRetryAfterSeconds(err)
    return wait === undefined ? m.saveRateLimitNoWait : fillFeedback(m.saveRateLimit, { n: Math.ceil(wait) })
  }
  return m.saveFailed
}
