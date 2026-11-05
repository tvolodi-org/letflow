/** DateField / TimeField / DateTimeField — React port of the platform `lf-date`, `lf-time`, `lf-datetime`
 *  (letflow-design platform/NOTES.md "Date and time"; markup classes come from components.css).
 *  The value is a string only (`YYYY-MM-DD`, `HH:mm`, `YYYY-MM-DDTHH:mm`, `''`); the typed format follows the UI
 *  language (`DD-MM-YYYY` in ru/kk/uz, `YYYY-MM-DD` in en). A text that is not a valid value yet stays in the field and
 *  reports `''`. Errors name the field. Calendar popup: Monday-first month grid, Today / Clear / Close, Escape closes.
 *  Ru and kk texts are machine drafts (as in the design repo). */
import React, { useEffect, useId, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { CalendarDays, ChevronLeft, ChevronRight, Clock } from 'lucide-react'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { usesDayFirstDashes } from '@/i18n/format'
import {
  addDays, addMonths, combineDateTime, formatDateText, maskDate, maskTime, monthGrid, parseDate, parseTime, splitDateTime,
} from './dateTimeModel'

type Lang = 'en' | 'ru' | 'kk'

const TXT: Record<Lang, Record<string, string>> = {
  en: {
    choose: 'Choose date', today: 'Today', clear: 'Clear', close: 'Close', prevMonth: 'Previous month', nextMonth: 'Next month',
    format: 'enter a date as YYYY-MM-DD', exists: 'the date does not exist', timeFormat: 'enter a time as HH:mm',
    timeRange: 'hours are 00 to 23, minutes are 00 to 59', required: 'required', date: 'date', time: 'time',
    tz: 'Time in the tenant time zone (Asia/Almaty)', choosePrefix: '',
  },
  ru: {
    choose: 'Выбрать дату', today: 'Сегодня', clear: 'Очистить', close: 'Закрыть', prevMonth: 'Предыдущий месяц', nextMonth: 'Следующий месяц',
    format: 'введите дату в формате ДД-ММ-ГГГГ', exists: 'такой даты не существует', timeFormat: 'введите время в формате ЧЧ:мм',
    timeRange: 'часы 00–23, минуты 00–59', required: 'обязательно', date: 'дата', time: 'время',
    tz: 'Время в часовом поясе тенанта (Asia/Almaty)', choosePrefix: '',
  },
  kk: {
    choose: 'Күнді таңдау', today: 'Бүгін', clear: 'Тазалау', close: 'Жабу', prevMonth: 'Алдыңғы ай', nextMonth: 'Келесі ай',
    format: 'күнді КК-АА-ЖЖЖЖ пішімінде енгізіңіз', exists: 'мұндай күн жоқ', timeFormat: 'уақытты СС:мм пішімінде енгізіңіз',
    timeRange: 'сағат 00–23, минут 00–59', required: 'міндетті', date: 'күні', time: 'уақыты',
    tz: 'Тенант уақыт белдеуіндегі уақыт (Asia/Almaty)', choosePrefix: '',
  },
}

const MONTHS: Record<Lang, string[]> = {
  en: ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'],
  ru: ['Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь'],
  kk: ['Қаңтар', 'Ақпан', 'Наурыз', 'Сәуір', 'Мамыр', 'Маусым', 'Шілде', 'Тамыз', 'Қыркүйек', 'Қазан', 'Қараша', 'Желтоқсан'],
}
const WEEKDAYS: Record<Lang, string[]> = {
  en: ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'],
  ru: ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'],
  kk: ['Дс', 'Сс', 'Ср', 'Бс', 'Жм', 'Сб', 'Жс'],
}

function useLang(): Lang {
  const l = useUiLocale()
  return l === 'ru' || l === 'kk' ? l : 'en'
}

const todayIso = () => {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

interface Common {
  label: string
  /** Label stays in the accessibility tree only (table cells). */
  hideLabel?: boolean
  optional?: boolean
  /** Server or form error text for the field (already names the field or is shown under it). */
  error?: string
  /** Show format errors at once (a failed Save). */
  showErrors?: boolean
  disabled?: boolean
  readOnly?: boolean
  id?: string
  'data-testid'?: string
}

/** Calendar popup, portalled to the body, fixed under the input (flips above when there is no room). */
function Calendar(props: { anchor: HTMLElement; name: string; value: string; lang: Lang; onPick: (iso: string) => void; onClose: () => void }) {
  const { anchor, name, value, lang, onPick, onClose } = props
  const t = TXT[lang]
  const start = value || todayIso()
  const [view, setView] = useState(start)
  const [focus, setFocus] = useState(start)
  const ref = useRef<HTMLDivElement>(null)
  const [pos, setPos] = useState<{ top: number; left: number }>({ top: 0, left: 0 })
  const [y, m] = view.split('-').map(Number)
  const today = todayIso()

  useEffect(() => {
    const r = anchor.getBoundingClientRect()
    const h = ref.current?.offsetHeight ?? 320
    const w = ref.current?.offsetWidth ?? 300
    const top = r.bottom + h > window.innerHeight && r.top - h > 0 ? r.top - h : r.bottom + 4
    setPos({ top, left: Math.max(8, Math.min(r.left, window.innerWidth - w - 8)) })
    ref.current?.querySelector<HTMLButtonElement>('button[tabindex="0"]')?.focus()
  }, [anchor])

  useEffect(() => {
    const down = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node) && !anchor.contains(e.target as Node)) onClose()
    }
    document.addEventListener('mousedown', down)
    return () => document.removeEventListener('mousedown', down)
  }, [anchor, onClose])

  const moveFocus = (iso: string) => {
    setFocus(iso)
    setView(iso)
    requestAnimationFrame(() => ref.current?.querySelector<HTMLButtonElement>(`button[data-iso="${iso}"]`)?.focus())
  }
  const onKey = (e: React.KeyboardEvent) => {
    const step: Record<string, string> = {
      ArrowLeft: addDays(focus, -1), ArrowRight: addDays(focus, 1), ArrowUp: addDays(focus, -7), ArrowDown: addDays(focus, 7),
      PageUp: addMonths(focus, e.shiftKey ? -12 : -1), PageDown: addMonths(focus, e.shiftKey ? 12 : 1),
    }
    if (e.key === 'Escape') {
      e.preventDefault()
      e.stopPropagation()
      onClose()
    } else if (step[e.key]) {
      e.preventDefault()
      moveFocus(step[e.key])
    }
  }
  const title = `${MONTHS[lang][m - 1]} ${y}`
  return createPortal(
    <div
      ref={ref}
      className="lf-cal"
      role="dialog"
      aria-modal="true"
      aria-label={`${t.choose}: ${name}`}
      style={{ top: pos.top, left: pos.left }}
      onKeyDown={onKey}
      data-testid="lf-cal"
    >
      <div className="lf-cal__head">
        <button type="button" className="lf-cal__nav" aria-label={t.prevMonth} onClick={() => setView(addMonths(view, -1))}>
          <ChevronLeft className="lf-icon" aria-hidden="true" />
        </button>
        <span />
        <div className="lf-cal__title" aria-live="polite">{title}</div>
        <span />
        <button type="button" className="lf-cal__nav" aria-label={t.nextMonth} onClick={() => setView(addMonths(view, 1))}>
          <ChevronRight className="lf-icon" aria-hidden="true" />
        </button>
      </div>
      <table className="lf-cal__grid" role="grid" aria-label={title}>
        <thead>
          <tr>{WEEKDAYS[lang].map((d) => <th key={d} scope="col">{d}</th>)}</tr>
        </thead>
        <tbody>
          {monthGrid(y, m).map((row, i) => (
            <tr key={i}>
              {row.map((c) => (
                <td key={c.iso} role="gridcell" aria-selected={c.iso === value}>
                  <button
                    type="button"
                    data-iso={c.iso}
                    tabIndex={c.iso === focus ? 0 : -1}
                    className={['lf-cal__day', c.inMonth ? '' : 'is-out', c.iso === today ? 'is-today' : '', c.iso === value ? 'is-selected' : ''].filter(Boolean).join(' ')}
                    aria-current={c.iso === today ? 'date' : undefined}
                    onClick={() => onPick(c.iso)}
                  >
                    {Number(c.iso.slice(8))}
                  </button>
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      <div className="lf-cal__foot">
        <button type="button" className="lf-btn lf-btn--ghost" data-cal="clear" onClick={() => onPick('')}>{t.clear}</button>
        <button type="button" className="lf-btn lf-btn--secondary" onClick={() => onPick(today)}>{t.today}</button>
      </div>
    </div>,
    document.body,
  )
}

/** The bare control: text input + calendar button + popup. `name` is used in labels of the popup and in errors. */
function DateControl(props: {
  name: string
  inputId: string
  ariaLabel?: string
  value: string
  onChange: (iso: string) => void
  onProblem: (p: string | null) => void
  describedBy?: string
  invalid?: boolean
  disabled?: boolean
  readOnly?: boolean
  showErrors?: boolean
}) {
  const lang = useLang()
  const t = TXT[lang]
  const [raw, setRaw] = useState(formatDateText(props.value, lang))
  const [open, setOpen] = useState(false)
  const box = useRef<HTMLDivElement>(null)
  const input = useRef<HTMLInputElement>(null)
  const popId = useId()
  // Re-sync when the value (or the language) changes from outside and the text no longer stands for it.
  useEffect(() => {
    const p = parseDate(raw, lang)
    const current = 'iso' in p ? p.iso : ''
    if (current !== props.value) setRaw(formatDateText(props.value, lang))
    else if (props.value !== '' && raw !== formatDateText(props.value, lang)) setRaw(formatDateText(props.value, lang))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.value, lang])

  const apply = (text: string) => {
    setRaw(text)
    const p = parseDate(text, lang)
    if ('iso' in p) {
      props.onProblem(null)
      props.onChange(p.iso)
    } else {
      props.onProblem(text.trim() === '' ? null : p.error === 'exists' ? t.exists : t.format)
      props.onChange('')
    }
  }
  const pick = (iso: string) => {
    apply(iso === '' ? '' : formatDateText(iso, lang))
    setOpen(false)
    input.current?.focus()
  }
  return (
    <div className={['lf-control', 'lf-control--mono', props.readOnly ? 'lf-control--readonly' : ''].filter(Boolean).join(' ')} ref={box} aria-disabled={props.disabled ? 'true' : undefined}>
      <input
        ref={input}
        id={props.inputId}
        type="text"
        inputMode="numeric"
        role="combobox"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={popId}
        aria-label={props.ariaLabel}
        aria-invalid={props.invalid || undefined}
        aria-describedby={props.describedBy}
        autoComplete="off"
        placeholder={usesDayFirstDashes(lang) ? (lang === 'kk' ? 'КК-АА-ЖЖЖЖ' : 'ДД-ММ-ГГГГ') : 'YYYY-MM-DD'}
        value={raw}
        disabled={props.disabled}
        readOnly={props.readOnly}
        onChange={(e) => apply(maskDate(e.target.value, lang))}
        onKeyDown={(e) => {
          if (e.key === 'ArrowDown' && !props.readOnly) {
            e.preventDefault()
            setOpen(true)
          }
        }}
      />
      <button
        type="button"
        className="lf-date__btn"
        tabIndex={-1}
        aria-label={`${t.choose}: ${props.name}`}
        disabled={props.disabled}
        onClick={() => setOpen((o) => !o)}
      >
        <CalendarDays className="lf-icon" aria-hidden="true" />
      </button>
      {open && box.current && (
        <Calendar
          anchor={box.current}
          name={props.name}
          value={'iso' in parseDate(raw, lang) ? (parseDate(raw, lang) as { iso: string }).iso : ''}
          lang={lang}
          onPick={pick}
          onClose={() => {
            setOpen(false)
            input.current?.focus()
          }}
        />
      )}
    </div>
  )
}

function FieldShell(props: Common & { inputId: string; problem: string | null; children: (describedBy: string | undefined, invalid: boolean) => React.ReactNode; className: string }) {
  const lang = useLang()
  const shown = props.error ?? (props.problem ? `${props.label}: ${props.problem}` : undefined)
  const errId = `${props.inputId}-error`
  return (
    <div className={`lf-field ${props.className}${shown ? ' lf-field--error' : ''}`} data-testid={props['data-testid']}>
      <label className={props.hideLabel ? 'lf-label sr-only' : 'lf-label'} htmlFor={props.inputId}>
        {props.label}
        {props.optional && <> <span className="lf-label__opt">{lang === 'ru' ? 'необязательно' : lang === 'kk' ? 'міндетті емес' : 'optional'}</span></>}
      </label>
      {props.children(shown ? errId : undefined, !!shown)}
      {shown && (
        <div id={errId} className="lf-error" aria-live="polite">
          {shown}
        </div>
      )}
    </div>
  )
}

export interface DateFieldProps extends Common {
  value: string
  onChange: (iso: string) => void
}

export function DateField(props: DateFieldProps): React.ReactElement {
  const auto = useId()
  const inputId = props.id ?? auto
  const [problem, setProblem] = useState<string | null>(null)
  return (
    <FieldShell {...props} inputId={inputId} problem={problem} className="lf-date">
      {(describedBy, invalid) => (
        <DateControl
          name={props.label}
          inputId={inputId}
          value={props.value}
          onChange={props.onChange}
          onProblem={setProblem}
          describedBy={describedBy}
          invalid={invalid}
          disabled={props.disabled}
          readOnly={props.readOnly}
        />
      )}
    </FieldShell>
  )
}

function TimeControl(props: {
  inputId: string
  ariaLabel?: string
  value: string
  onChange: (time: string) => void
  onProblem: (p: string | null) => void
  describedBy?: string
  invalid?: boolean
  disabled?: boolean
  readOnly?: boolean
}) {
  const lang = useLang()
  const t = TXT[lang]
  const [raw, setRaw] = useState(props.value)
  useEffect(() => {
    const p = parseTime(raw)
    if (('time' in p ? p.time : '') !== props.value) setRaw(props.value)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.value])
  const apply = (text: string) => {
    setRaw(text)
    const p = parseTime(text)
    if ('time' in p) {
      props.onProblem(null)
      props.onChange(p.time)
    } else {
      props.onProblem(text.trim() === '' ? null : p.error === 'range' ? t.timeRange : t.timeFormat)
      props.onChange('')
    }
  }
  return (
    <div className={['lf-control', 'lf-control--mono', props.readOnly ? 'lf-control--readonly' : ''].filter(Boolean).join(' ')} aria-disabled={props.disabled ? 'true' : undefined}>
      <input
        id={props.inputId}
        type="text"
        inputMode="numeric"
        autoComplete="off"
        aria-label={props.ariaLabel}
        aria-invalid={props.invalid || undefined}
        aria-describedby={props.describedBy}
        placeholder={lang === 'en' ? 'HH:mm' : lang === 'ru' ? 'ЧЧ:мм' : 'СС:мм'}
        value={raw}
        disabled={props.disabled}
        readOnly={props.readOnly}
        onChange={(e) => apply(e.target.value.length < raw.length ? e.target.value : maskTime(e.target.value))}
      />
      <span className="lf-date__btn" aria-hidden="true">
        <Clock className="lf-icon" />
      </span>
    </div>
  )
}

export interface DateTimeFieldProps extends Common {
  /** `YYYY-MM-DDTHH:mm` or `''`. */
  value: string
  onChange: (value: string) => void
}

/** Date + time under one label and one error line. A half-filled pair reports `''`. */
export function DateTimeField(props: DateTimeFieldProps): React.ReactElement {
  const lang = useLang()
  const t = TXT[lang]
  const auto = useId()
  const baseId = props.id ?? auto
  const [parts, setParts] = useState(splitDateTime(props.value))
  const [dateProblem, setDateProblem] = useState<string | null>(null)
  const [timeProblem, setTimeProblem] = useState<string | null>(null)
  useEffect(() => {
    if (combineDateTime(parts.date, parts.time) !== props.value && (props.value !== '' || (parts.date !== '' && parts.time !== ''))) {
      setParts(splitDateTime(props.value))
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.value])
  const set = (next: { date: string; time: string }) => {
    setParts(next)
    props.onChange(combineDateTime(next.date, next.time))
  }
  const problem = dateProblem ?? timeProblem
  const errId = `${baseId}-error`
  const shown = props.error ?? (problem ? `${props.label}: ${problem}` : undefined)
  return (
    <div
      className={`lf-field lf-datetime${shown ? ' lf-field--error' : ''}`}
      role="group"
      aria-labelledby={`${baseId}-label`}
      aria-describedby={shown ? errId : undefined}
      data-testid={props['data-testid']}
    >
      <span id={`${baseId}-label`} className={props.hideLabel ? 'lf-label sr-only' : 'lf-label'}>{props.label}</span>
      <div className="lf-datetime__row">
        <div className="lf-field lf-date lf-date--bare lf-datetime__date">
          <DateControl
            name={props.label}
            inputId={`${baseId}-date`}
            ariaLabel={`${props.label}, ${t.date}`}
            value={parts.date}
            onChange={(date) => set({ ...parts, date })}
            onProblem={setDateProblem}
            describedBy={shown ? errId : undefined}
            invalid={!!shown}
            disabled={props.disabled}
            readOnly={props.readOnly}
          />
        </div>
        <div className="lf-field lf-time lf-time--bare lf-datetime__time">
          <TimeControl
            inputId={`${baseId}-time`}
            ariaLabel={`${props.label}, ${t.time}`}
            value={parts.time}
            onChange={(time) => set({ ...parts, time })}
            onProblem={setTimeProblem}
            describedBy={shown ? errId : undefined}
            invalid={!!shown}
            disabled={props.disabled}
            readOnly={props.readOnly}
          />
        </div>
      </div>
      <div className="lf-hint">{t.tz}</div>
      {shown && (
        <div id={errId} className="lf-error" aria-live="polite">
          {shown}
        </div>
      )}
    </div>
  )
}

/** Bare date control for a table cell (no label chrome): the label is the aria-label. */
export function DateCell(props: { label: string; value: string; onChange: (iso: string) => void; invalid?: boolean; describedBy?: string; id?: string }) {
  const auto = useId()
  const [problem, setProblem] = useState<string | null>(null)
  return (
    <div className="lf-field lf-date lf-date--bare">
      <DateControl
        name={props.label}
        inputId={props.id ?? auto}
        ariaLabel={props.label}
        value={props.value}
        onChange={props.onChange}
        onProblem={setProblem}
        invalid={props.invalid || problem !== null}
        describedBy={props.describedBy}
      />
      {problem && <div className="lf-error" aria-live="polite">{`${props.label}: ${problem}`}</div>}
    </div>
  )
}
