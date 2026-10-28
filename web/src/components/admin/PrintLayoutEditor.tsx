/** PrintLayoutEditor — REQ-614: type_key, locale and a JSON layout editor with a live preview.
 *
 *  Parsing is local; an invalid layout never reaches the network. Save always
 *  means "save as new draft": the parent decides what the call does.
 */
import React, { useMemo, useRef, useState } from 'react'
import { Button } from '@/components/ui/Button'
import { PRINT_OVERRIDE_LOCALES, type PrintOverrideLocale, type PrintOverrideSaveBody } from '@/api/documentPrintOverrides'
import { PrintLayoutPreview } from './PrintLayoutPreview'

export interface PrintLayoutEditorProps {
  initial?: { type_key: string; locale: string; layoutText: string }
  onSave: (body: PrintOverrideSaveBody) => void
  saving?: boolean
  errorLines?: string[]
}

type Parsed = { ok: true; value: Record<string, unknown> } | { ok: false; message: string }

function parseLayout(text: string): Parsed {
  let value: unknown
  try {
    value = JSON.parse(text)
  } catch {
    // The parser message can echo input, so a fixed text is shown instead.
    return { ok: false, message: 'Layout is not valid JSON' }
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return { ok: false, message: 'Layout must be a JSON object' }
  }
  return { ok: true, value: value as Record<string, unknown> }
}

export function PrintLayoutEditor(props: PrintLayoutEditorProps): React.ReactElement {
  const { initial, onSave, saving = false, errorLines = [] } = props
  const [typeKey, setTypeKey] = useState(initial?.type_key ?? '')
  const [locale, setLocale] = useState<PrintOverrideLocale>(
    PRINT_OVERRIDE_LOCALES.find((l) => l === initial?.locale) ?? 'default',
  )
  const [text, setText] = useState(initial?.layoutText ?? '{\n  "layout_schema_version": 1,\n  "blocks": []\n}')
  const [typeKeyError, setTypeKeyError] = useState(false)

  const parsed = useMemo(() => parseLayout(text), [text])
  const lastValid = useRef<unknown>(null)
  if (parsed.ok) lastValid.current = parsed.value

  const handleSave = () => {
    if (!parsed.ok) return
    if (typeKey.trim() === '') {
      setTypeKeyError(true)
      return
    }
    setTypeKeyError(false)
    onSave({ type_key: typeKey.trim(), locale, layout: parsed.value })
  }

  return (
    <div data-testid="print-editor" style={{ display: 'flex', gap: '1.5rem', flexWrap: 'wrap' }}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: '.5rem', flex: '1 1 24rem' }}>
        <label>
          Type key{' '}
          <input data-testid="editor-type-key" value={typeKey} onChange={(e) => setTypeKey(e.target.value)} />
        </label>
        {typeKeyError && <div role="alert">Type key is required</div>}
        <label>
          Locale{' '}
          <select
            data-testid="editor-locale"
            value={locale}
            onChange={(e) => setLocale(e.target.value as PrintOverrideLocale)}
          >
            {PRINT_OVERRIDE_LOCALES.map((l) => (
              <option key={l} value={l}>
                {l}
              </option>
            ))}
          </select>
        </label>
        <label>
          Layout (JSON)
          <textarea
            data-testid="editor-layout"
            aria-label="Layout JSON"
            rows={16}
            spellCheck={false}
            style={{ width: '100%', fontFamily: 'var(--font-mono)' }}
            value={text}
            onChange={(e) => setText(e.target.value)}
          />
        </label>
        {!parsed.ok && <div role="alert" data-testid="editor-json-error">{parsed.message}</div>}
        {errorLines.length > 0 && (
          <div role="alert" data-testid="editor-server-errors">
            {errorLines.map((line, i) => (
              <div key={i}>{line}</div>
            ))}
          </div>
        )}
        <div>
          <Button variant="primary" size="md" data-testid="editor-save" loading={saving} onClick={handleSave}>
            Save as new draft
          </Button>
        </div>
      </div>
      <div style={{ flex: '1 1 24rem' }}>
        <PrintLayoutPreview layout={lastValid.current} />
      </div>
    </div>
  )
}
