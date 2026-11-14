/** Client-side masking of a problem report (T-1950). The same six rules, in the same order, as the server's
 *  `Letflow.ProblemReports.Capture.mask/1` (lib/letflow/problem_reports/capture.ex); the 17 literal pairs of
 *  `test/letflow/problem_reports/capture_test.exs` (`@pairs`) are copied into `__tests__/redact.test.ts`.
 *  The server masks again, so this is the first line: the preview shows what is stored. */

const BEARER = /\bBearer\s+[A-Za-z0-9._~+/=-]+/gi
const JWT = /\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/g
const SK = /\bsk-[A-Za-z0-9_-]{16,}/g
const ASSIGN = /\b(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S+/gi
const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g
const PHONE = /(?<![0-9A-Za-z+])\+?[0-9](?:[ ()-]{1,2}[0-9]|[0-9])*(?![0-9A-Za-z])/g
const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

function maskPhone(candidate: string): string {
  const digits = (candidate.match(/[0-9]/g) ?? []).length
  if (candidate.startsWith('+') && digits >= 10) return '[phone]'
  if (digits === 11 && (candidate[0] === '7' || candidate[0] === '8')) return '[phone]'
  return candidate
}

export function maskText(s: string): string {
  return s
    .replace(BEARER, 'Bearer [REDACTED]')
    .replace(JWT, '[REDACTED]')
    .replace(SK, '[REDACTED]')
    .replace(ASSIGN, '$1=[REDACTED]')
    .replace(EMAIL, '[email]')
    .replace(PHONE, (candidate) => maskPhone(candidate))
}

/** Drops `?query` and `#hash`; a segment that is a UUID, holds 3 or more digits or is longer than 40 characters becomes `:id`. */
export function normalizePath(path: string): string {
  const base = path.split(/[?#]/, 1)[0] ?? ''
  return base
    .split('/')
    .map((segment) => {
      if (segment === '') return segment
      if (UUID.test(segment)) return ':id'
      if (segment.length > 40) return ':id'
      if ((segment.match(/[0-9]/g) ?? []).length >= 3) return ':id'
      return segment
    })
    .join('/')
}

/** An action name (a data-testid): UUIDs and runs of 3+ digits become `:id`, then masked and cut to 80 characters. */
export function normalizeName(name: string): string {
  const noIds = name
    .replace(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g, ':id')
    .replace(/[0-9]{3,}/g, ':id')
  return maskText(noIds).slice(0, 80)
}

/** A one-line field never carries a line break or control character. */
export function oneLine(s: string): string {
  // eslint-disable-next-line no-control-regex -- the control range is the point of this function
  return s.replace(/[\x00-\x1f\x7f]+/g, ' ').replace(/[\u2028\u2029\u0085]/g, ' ')
}

