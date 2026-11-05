/** ScanField — GH 3761 / REQ-720 criterion 1. Keyboard-scanner input on the count sheet: one text field that keeps
 *  the focus, a current-place picker, and Enter sends {scanned_text, location_id, scan_id} with the text unchanged.
 *  A location code sets the current place; a line answer highlights the line; a retry after a network failure
 *  resends the same body (same scan_id), so a scan is never counted twice. */
import { useEffect, useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { FormSection } from '@/components/ui/FormSection'
import { Select } from '@/components/ui/Select'
import { useToast } from '@/hooks/useToast'
import { usePickerOptions } from '../register/stockPickers'
import { countsApi, type ScanBody } from './counts.api'
import { isNetworkFailure, newScanId, reasonMessageId } from './countsModel'
import { useCountsWrite } from './useCountsWrite'

const NONE: never[] = []

export function ScanField({ orderId, locationIds, onLine }: { orderId: string; locationIds: string[]; onLine: (lineNo: number | null) => void }) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const inputRef = useRef<HTMLInputElement | null>(null)
  const [text, setText] = useState('')
  const [place, setPlace] = useState('')
  // Current-place choices: the roots of the order; places learned from location scans are added (descendants cannot be
  // listed cheaply, the server refuses a place outside the count with location_not_in_count).
  const [learned, setLearned] = useState<string[]>([])
  const [need, setNeed] = useState<'text' | 'place' | null>(null)
  const [info, setInfo] = useState<string | null>(null)
  const [failed, setFailed] = useState<ScanBody | null>(null)
  const all = usePickerOptions('location_node', NONE)
  const options = all.filter((o) => locationIds.includes(o.value) || learned.includes(o.value))
  const write = useCountsWrite((body: ScanBody) => countsApi.scan(orderId, body))

  useEffect(() => {
    inputRef.current?.focus()
  }, [])

  async function send(body: ScanBody) {
    setInfo(null)
    setFailed(null)
    const res = await write.submit(body)
    if (res.ok) {
      const a = res.data
      if (a.kind === 'location') {
        setPlace(a.location_id ?? '')
        if (a.location_id) setLearned((xs) => (xs.includes(a.location_id!) ? xs : [...xs, a.location_id!]))
        onLine(null)
      } else if (a.duplicate === true) {
        setInfo(t('counts.scan.duplicate', { line: a.line_no ?? '' }))
        onLine(a.line_no ?? null)
      } else {
        toast.success(t('counts.scan.counted', { line: a.line_no ?? '', quantity: a.counted_quantity ?? '' }))
        onLine(a.line_no ?? null)
      }
      setText('')
    } else {
      // The error stays in useCountsWrite; a network failure offers a retry of this same body.
      setFailed(body)
    }
    inputRef.current?.focus()
  }

  function onEnter() {
    if (text === '') return setNeed('text')
    if (place === '') return setNeed('place')
    setNeed(null)
    void send({ scanned_text: text, location_id: place, scan_id: newScanId() })
  }

  const err = write.error
  const status = (err as { status?: number } | null)?.status
  const network = err !== null && isNetworkFailure(err)
  const errorText = err === null ? null : status === 404 ? t('counts.scan.unknownCode') : t(reasonMessageId(err))
  const fieldError = need === 'text' ? t('counts.scan.needText') : undefined
  return (
    <FormSection title={t('counts.scan.title')}>
      <div className="lf-form" data-testid="scan-field">
        {errorText !== null && <Banner tone="danger">{errorText}</Banner>}
        {info !== null && <Banner tone="info">{info}</Banner>}
        <Select
          label={t('counts.scan.place')}
          value={place}
          onChange={(v) => {
            setPlace(v)
            setNeed(null)
          }}
          options={options}
          placeholder={t('counts.form.select')}
          error={need === 'place' ? t('counts.scan.needPlace') : undefined}
          data-testid="scan-place"
        />
        <Field label={t('counts.scan.label')} hint={t('counts.scan.hint')} mono error={fieldError}>
          <input
            ref={inputRef}
            autoComplete="off"
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                e.preventDefault()
                onEnter()
              }
            }}
            data-testid="scan-input"
          />
        </Field>
        {network && failed !== null && (
          <Button variant="secondary" size="sm" loading={write.isPending} onClick={() => void send(failed)} data-testid="scan-retry">
            {t('counts.scan.retry')}
          </Button>
        )}
      </div>
    </FormSection>
  )
}
