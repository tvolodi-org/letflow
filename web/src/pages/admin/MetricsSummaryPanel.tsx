import { useRef } from 'react'
import type { PrometheusMetricFamily } from '@/api/metrics'
import {
  buildSummary,
  topErrorRoutes,
  type Figure,
  type FigureId,
  type FigureStatus,
  type Reading,
} from '@/api/metricsSummary'
import { useUiLocale } from '@/i18n/uiLocaleStore'

export const SUMMARY_MESSAGES = {
  en: {
    heading: 'Support summary',
    allFigures: 'All figures (for developers)',
    measuring: 'Measuring…',
    statusOk: 'OK',
    statusWarn: 'Check',
    statusRed: 'Problem',
    statusUnknown: 'No data',
    notMeasured: 'Not measured yet',
    perMinute: 'per minute',
    sinceStart: 'of calls slower than 1 s since the service started',
    minutesOld: 'min since last run',
    requests: 'Requests per minute',
    errors: 'Errors per minute',
    errorRoutes: 'Routes with errors',
    errorRoutesDo: 'Send these route names with the report.',
    slowDb: 'Slow database work',
    slowAppend: 'Event-store write speed',
    refresh: 'Background refresh',
    errorsDo: 'The server is failing some requests. Note the time and the routes listed below, and report them to the platform operator.',
    slowDbDo: 'Database queries are slow. Ask users to avoid large imports and exports for a while; if it stays red, report it.',
    slowAppendDo: 'Saving documents is slow. Do not retry repeatedly; report it if it stays red.',
    refreshDo: 'The background job that counts running processes has stopped. Restart the service or call the platform operator.',
    pool: 'Database connection use',
    jobs: 'Queue and background jobs',
    modules: 'Module versions per tenant',
    upgrade: 'Last upgrade result',
    notShownDo: 'Not shown yet. If users report slowness, ask the platform operator to check the database connections directly.',
  },
  ru: {
    heading: 'Сводка для поддержки',
    allFigures: 'Все показатели (для разработчиков)',
    measuring: 'Измеряется…',
    statusOk: 'Норма',
    statusWarn: 'Проверить',
    statusRed: 'Проблема',
    statusUnknown: 'Нет данных',
    notMeasured: 'Пока не измеряется',
    perMinute: 'в минуту',
    sinceStart: 'вызовов медленнее 1 с с момента запуска сервиса',
    minutesOld: 'мин с последнего запуска',
    requests: 'Запросов в минуту',
    errors: 'Ошибок в минуту',
    errorRoutes: 'Маршруты с ошибками',
    errorRoutesDo: 'Передайте эти названия маршрутов вместе с обращением.',
    slowDb: 'Медленная работа базы данных',
    slowAppend: 'Скорость записи в хранилище событий',
    refresh: 'Фоновое обновление',
    errorsDo: 'Сервер не обрабатывает часть запросов. Запишите время и маршруты из списка ниже и сообщите оператору платформы.',
    slowDbDo: 'Запросы к базе данных медленные. Попросите пользователей на время не запускать большие импорты и экспорты; если показатель остаётся красным, сообщите об этом.',
    slowAppendDo: 'Сохранение документов идёт медленно. Не повторяйте попытки подряд; если показатель остаётся красным, сообщите об этом.',
    refreshDo: 'Фоновая задача, считающая работающие процессы, остановилась. Перезапустите сервис или позвоните оператору платформы.',
    pool: 'Использование подключений к базе',
    jobs: 'Очередь и фоновые задачи',
    modules: 'Версии модулей по арендаторам',
    upgrade: 'Результат последнего обновления',
    notShownDo: 'Пока не показывается. Если пользователи жалуются на медленную работу, попросите оператора платформы проверить подключения к базе напрямую.',
  },
  kk: {
    heading: 'Қолдау қызметіне арналған қорытынды',
    allFigures: 'Барлық көрсеткіштер (әзірлеушілерге)',
    measuring: 'Өлшенуде…',
    statusOk: 'Қалыпты',
    statusWarn: 'Тексеру керек',
    statusRed: 'Мәселе',
    statusUnknown: 'Дерек жоқ',
    notMeasured: 'Әзірге өлшенбейді',
    perMinute: 'минутына',
    sinceStart: 'қызмет іске қосылғалы 1 с-тан баяу шақырулар үлесі',
    minutesOld: 'мин соңғы іске қосудан бері',
    requests: 'Минутына сұраулар',
    errors: 'Минутына қателер',
    errorRoutes: 'Қателері бар маршруттар',
    errorRoutesDo: 'Осы маршрут атауларын хабарламаға қосып жіберіңіз.',
    slowDb: 'Деректер базасының баяу жұмысы',
    slowAppend: 'Оқиғалар қоймасына жазу жылдамдығы',
    refresh: 'Фондық жаңарту',
    errorsDo: 'Сервер кейбір сұрауларды өңдей алмай жатыр. Уақытты және төмендегі маршруттарды жазып алып, платформа операторына хабарлаңыз.',
    slowDbDo: 'Деректер базасына сұраулар баяу. Пайдаланушылардан біраз уақыт үлкен импорт пен экспортты тоқтатуды сұраңыз; көрсеткіш қызыл болып қалса, хабарлаңыз.',
    slowAppendDo: 'Құжаттарды сақтау баяу. Қайталай бермеңіз; көрсеткіш қызыл болып қалса, хабарлаңыз.',
    refreshDo: 'Жұмыс істеп тұрған процестерді санайтын фондық тапсырма тоқтады. Қызметті қайта іске қосыңыз немесе платформа операторына қоңырау шалыңыз.',
    pool: 'Деректер базасына қосылымдарды пайдалану',
    jobs: 'Кезек және фондық тапсырмалар',
    modules: 'Арендаторлар бойынша модуль нұсқалары',
    upgrade: 'Соңғы жаңартудың нәтижесі',
    notShownDo: 'Әзірге көрсетілмейді. Пайдаланушылар баяулығына шағымданса, платформа операторынан дерекқор қосылымдарын тікелей тексеруді сұраңыз.',
  },
} as const

type Messages = (typeof SUMMARY_MESSAGES)['en']

const UNMEASURED: { key: keyof Messages }[] = [{ key: 'pool' }, { key: 'jobs' }, { key: 'modules' }, { key: 'upgrade' }]

const TITLE_KEY: Record<FigureId, keyof Messages> = {
  requests: 'requests',
  errors: 'errors',
  slowDb: 'slowDb',
  slowAppend: 'slowAppend',
  refresh: 'refresh',
}
const ACTION_KEY: Partial<Record<FigureId, keyof Messages>> = {
  errors: 'errorsDo',
  slowDb: 'slowDbDo',
  slowAppend: 'slowAppendDo',
  refresh: 'refreshDo',
}
const STATUS_COLOR: Record<FigureStatus, string> = {
  ok: 'var(--color-success-dark)',
  warn: 'var(--color-warning-dark)',
  red: 'var(--color-error-dark)',
  unknown: 'var(--text-secondary)',
}

function statusWord(m: Messages, s: FigureStatus): string {
  return s === 'ok' ? m.statusOk : s === 'warn' ? m.statusWarn : s === 'red' ? m.statusRed : m.statusUnknown
}

function valueText(m: Messages, f: Figure): string {
  if (f.value === null) return f.id === 'requests' || f.id === 'errors' ? m.measuring : '—'
  if (f.id === 'requests' || f.id === 'errors') return `${Math.round(f.value * 10) / 10} ${m.perMinute}`
  if (f.id === 'refresh') return `${Math.floor(f.value / 60)} ${m.minutesOld}`
  return `${Math.round(f.value * 1000) / 10}% ${m.sinceStart}`
}

const CARD: React.CSSProperties = {
  padding: '.75rem .9rem',
  border: '1px solid var(--border-default)',
  borderRadius: 'var(--radius-sm)',
  background: 'var(--surface-card)',
  minWidth: 0,
}

export function MetricsSummaryPanel({ families, dataUpdatedAt }: { families: PrometheusMetricFamily[]; dataUpdatedAt: number }) {
  const m = SUMMARY_MESSAGES[useUiLocale()]
  // Keep the previous poll so a rate can be computed from two data timestamps; the rates depend on the
  // timestamps of the data, never on render time, so a re-render does not zero them.
  const curRef = useRef<Reading | null>(null)
  const prevRef = useRef<Reading | null>(null)
  const atSeconds = dataUpdatedAt / 1000
  if (!curRef.current || curRef.current.atSeconds !== atSeconds) {
    prevRef.current = curRef.current
    curRef.current = { families, atSeconds }
  }
  const figures = buildSummary(prevRef.current, curRef.current, Date.now() / 1000)
  const routes = topErrorRoutes(families)

  return (
    <section aria-labelledby="support-summary-heading" data-testid="support-summary" style={{ marginBottom: '1.5rem' }}>
      <h3 id="support-summary-heading" style={{ margin: '0 0 .75rem' }}>{m.heading}</h3>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(16rem, 1fr))', gap: '.75rem' }}>
        {figures.map((f) => {
          const action = ACTION_KEY[f.id]
          return (
            <div key={f.id} data-testid={`figure-${f.id}`} style={CARD}>
              <div style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>{m[TITLE_KEY[f.id]]}</div>
              <div style={{ fontFamily: 'var(--font-mono)', fontWeight: 600, margin: '.2rem 0' }}>{valueText(m, f)}</div>
              <div data-testid={`figure-${f.id}-status`} style={{ color: STATUS_COLOR[f.status], fontWeight: 700, fontSize: 'var(--text-sm)' }}>
                {statusWord(m, f.status)}
              </div>
              {action && (f.status === 'warn' || f.status === 'red') && (
                <p style={{ margin: '.4rem 0 0', fontSize: 'var(--text-sm)' }}>{m[action]}</p>
              )}
            </div>
          )
        })}
        {UNMEASURED.map(({ key }) => (
          <div key={key} data-testid="figure-unmeasured" style={CARD}>
            <div style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>{m[key]}</div>
            <div style={{ fontWeight: 700, fontSize: 'var(--text-sm)', color: 'var(--text-secondary)', margin: '.2rem 0' }}>{m.notMeasured}</div>
            <p style={{ margin: '.4rem 0 0', fontSize: 'var(--text-sm)' }}>{m.notShownDo}</p>
          </div>
        ))}
      </div>
      {routes.length > 0 && (
        <div data-testid="error-routes" style={{ ...CARD, marginTop: '.75rem' }}>
          <strong>{m.errorRoutes}</strong>
          <ul style={{ margin: '.3rem 0', paddingLeft: '1.2rem' }}>
            {routes.map((r) => (
              <li key={r.route} style={{ fontFamily: 'var(--font-mono)', overflowWrap: 'anywhere' }}>{r.route} ({r.errors})</li>
            ))}
          </ul>
          <p style={{ margin: 0, fontSize: 'var(--text-sm)' }}>{m.errorRoutesDo}</p>
        </div>
      )}
      <h3 style={{ margin: '1.5rem 0 0' }}>{m.allFigures}</h3>
    </section>
  )
}
