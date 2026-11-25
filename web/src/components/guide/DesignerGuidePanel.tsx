/** DesignerGuidePanel -- T-2805: the designer guide inside the product, as a side panel.
 *
 *  The text is the document `docs/designer-guide.<lang>.md` (en has no suffix), imported as raw text at build time;
 *  nothing of it is written in this component. The document marks each section with `<a id="sec-..."></a>`: the
 *  panel splits at those lines, gives every part that id, and scrolls to the requested one. A link `(#sec-...)`
 *  inside the text scrolls the panel to its section. The markdown goes through react-markdown without raw HTML.
 *  Escape and the close button close it.
 */
import { useEffect, useMemo, useRef, useState } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { Button } from '@/components/ui/Button'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { useGuideStore } from '@/stores/guideStore'
import { definitionsMessages } from '@/pages/definitions/definitionsMessages'

const SOURCES = import.meta.glob('../../../../docs/designer-guide*.md', { query: '?raw', import: 'default' }) as Record<
  string,
  () => Promise<string>
>

function loaderFor(locale: string): (() => Promise<string>) | undefined {
  const suffix = locale === 'en' ? '' : `.${locale}`
  const key = Object.keys(SOURCES).find((k) => k.endsWith(`/designer-guide${suffix}.md`))
  return key ? SOURCES[key] : undefined
}

function findSection(root: HTMLElement | null, id: string): Element | null {
  return Array.from(root?.querySelectorAll('section[id]') ?? []).find((el) => el.id === id) ?? null
}

const ANCHOR = /^<a id="(sec-[a-z0-9-]+)"><\/a>\s*$/

/** Splits the document at its anchor lines: text before the first anchor has id null. */
export function splitSections(md: string): { id: string | null; text: string }[] {
  const out: { id: string | null; lines: string[] }[] = [{ id: null, lines: [] }]
  for (const line of md.split(/\r?\n/)) {
    const m = ANCHOR.exec(line)
    if (m) out.push({ id: m[1], lines: [] })
    else out[out.length - 1].lines.push(line)
  }
  return out.map((s) => ({ id: s.id, text: s.lines.join('\n') })).filter((s) => s.id || s.text.trim())
}

export function DesignerGuidePanel() {
  const open = useGuideStore((s) => s.open)
  const section = useGuideStore((s) => s.section)
  const closeGuide = useGuideStore((s) => s.closeGuide)
  const locale = useUiLocale()
  const dm = definitionsMessages[locale]
  const [md, setMd] = useState<string | null>(null)
  const [failed, setFailed] = useState(false)
  const bodyRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    if (!open) return
    let alive = true
    setMd(null)
    setFailed(false)
    const load = loaderFor(locale)
    if (!load) {
      setFailed(true)
      return
    }
    load().then(
      (t) => alive && setMd(t),
      (err) => {
        console.error('designer guide load failed', err)
        if (alive) setFailed(true)
      },
    )
    return () => {
      alive = false
    }
  }, [open, locale])

  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && closeGuide()
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [open, closeGuide])

  const sections = useMemo(() => (md ? splitSections(md) : []), [md])

  useEffect(() => {
    if (!open || !md) return
    const target = section ? findSection(bodyRef.current, section) : null
    target?.scrollIntoView?.({ block: 'start' })
  }, [open, md, section])

  if (!open) return null

  const goTo = (id: string) => {
    findSection(bodyRef.current, id)?.scrollIntoView?.({ block: 'start' })
  }

  return (
    <aside className="lf-guide-panel" data-testid="designer-guide-panel" aria-label={dm.guideTitle}>
      <div className="lf-guide-panel__head">
        <h2>{dm.guideTitle}</h2>
        <Button variant="secondary" size="sm" data-testid="designer-guide-close" onClick={closeGuide}>
          {dm.guideClose}
        </Button>
      </div>
      <div className="lf-guide-panel__body" ref={bodyRef} data-testid="designer-guide-body">
        {failed && <p data-testid="designer-guide-unavailable">{dm.guideUnavailable}</p>}
        {!failed && !md && <p>…</p>}
        {sections.map((s, i) => (
          <section key={s.id ?? `intro-${i}`} id={s.id ?? undefined} data-testid={s.id ? `guide-${s.id}` : undefined}>
            <ReactMarkdown
              remarkPlugins={[remarkGfm]}
              components={{
                a: ({ href, children }) =>
                  href?.startsWith('#') ? (
                    <a
                      href={href}
                      onClick={(e) => {
                        e.preventDefault()
                        goTo(href.slice(1))
                      }}
                    >
                      {children}
                    </a>
                  ) : (
                    <a href={href} target="_blank" rel="noreferrer noopener">
                      {children}
                    </a>
                  ),
              }}
            >
              {s.text}
            </ReactMarkdown>
          </section>
        ))}
      </div>
    </aside>
  )
}
