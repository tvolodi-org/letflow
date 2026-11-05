/** actorLabel — T-1378. A user reference (posted by, reversed by, assignee) as text. The platform has no user-name lookup for
 *  an ordinary role, so a user id (uuid) is shown as "You" when it is the signed-in user (`subject` = tenant user id from `useAccess().userId`) and "Another user" otherwise;
 *  a value that is not a uuid (a role or group name) is shown as it is. Never the id. */
import { isUuid } from './referenceLabel'

export function actorLabel(ref: string | null | undefined, subject: string | null, msg: { you: string; anotherUser: string }): string {
  if (!ref) return ''
  if (!isUuid(ref)) return ref
  return ref === subject ? msg.you : msg.anotherUser
}
