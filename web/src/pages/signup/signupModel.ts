/** signupModel -- T-2748: pure rules of the sign-up form (shape checks only; the server decides everything). */
export const SLUG_SHAPE = /^[a-z0-9](?:[a-z0-9-]{1,28})[a-z0-9]$/
const EMAIL_SHAPE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

export function isSlugShape(slug: string): boolean {
  return SLUG_SHAPE.test(slug) && !slug.includes('--') && !slug.startsWith('t-')
}

export function isEmailShape(email: string): boolean {
  return email.length <= 254 && EMAIL_SHAPE.test(email)
}

/** Strength rule: 12..128 characters with a letter and a digit. */
export function isStrongPassword(password: string): boolean {
  return password.length >= 12 && password.length <= 128 && /\p{L}/u.test(password) && /\d/.test(password)
}

/** A suggestion for the slug field from the company name (Latin letters and digits only; may be too short). */
export function suggestSlug(company: string): string {
  return company
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 30)
    .replace(/-+$/g, '')
}
