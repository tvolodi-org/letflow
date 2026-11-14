/** The file name of a Content-Disposition header (`filename*=UTF-8''x` first, then `filename="x"`), else the fallback. */
export function parseFilename(header: string | null | undefined, fallback: string): string {
  if (!header) return fallback
  const star = /filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)/.exec(header)
  if (star?.[1]) {
    try {
      const v = decodeURIComponent(star[1].trim())
      if (v !== '') return v
    } catch {
      /* fall through to the plain name */
    }
  }
  const plain = /filename\s*=\s*"([^"]+)"/.exec(header) ?? /filename\s*=\s*([^;\s]+)/.exec(header)
  return plain?.[1] ? plain[1] : fallback
}
