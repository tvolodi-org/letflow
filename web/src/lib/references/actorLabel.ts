/** actorLabel — T-1378. A user reference (posted by, reversed by, assignee) as text. The platform has no user-name lookup for
 *  an ordinary role, so a user id (uuid) is shown as "You" when it is the signed-in user and "Another user" otherwise;
 *  a value that is not a uuid (a role or group name) is shown as it is. Never the id. */
import { isUuid } from './referenceLabel'

/** The `sub` claim of a JWT, or null. */
export function tokenSubject(token: string | null | undefined): string | null {
  if (!token) return null
  try {
    const parts = token.split('.')
    if (parts.length !== 3) return null
    const sub = (JSON.parse(atob(parts[1])) as { sub?: unknown }).sub
    return typeof sub === 'string' && sub !== '' ? sub : null
  } catch {
    return null
  }
}

export function actorLabel(ref: string | null | undefined, subject: string | null, msg: { you: string; anotherUser: string }): string {
  if (!ref) return ''
  if (!isUuid(ref)) return ref
  return ref === subject ? msg.you : msg.anotherUser
}
