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
import { StatusPill, type StatusGlyph, type StatusTone } from '@/components/ui/StatusPill'

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
    poolOf: 'slots in use',
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
    poolDo: 'Many database connections are busy. Ask users to avoid large imports and exports for a while; if it stays red, report it to the platform operator.',
    jobsDo: 'There is no job queue to read yet, and scheduled sweeps do not record when they last ran. Until they do, if a scheduled job did not run, ask the platform operator.',
    modulesDo: 'Module versions are stored per tenant and are not part of the platform metrics. A separate page that reads the tenant\'s own modules is needed. Until then ask the platform operator.',
    upgradeDo: 'The result of the last module upgrade is kept in the tenant\'s module journal, which this page cannot read yet. Until then ask the platform operator.',
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
    poolOf: 'занято слотов',
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
    poolDo: 'Занято много подключений к базе. Попросите пользователей на время не запускать большие импорты и экспорты; если показатель остаётся красным, сообщите оператору платформы.',
    jobsDo: 'Очереди задач для чтения пока нет, а плановые проверки не записывают время последнего запуска. Пока так, если плановая задача не сработала, обратитесь к оператору платформы.',
    modulesDo: 'Версии модулей хранятся отдельно для каждого арендатора и не входят в общие показатели платформы. Нужна отдельная страница, читающая модули самого арендатора. Пока её нет, обратитесь к оператору платформы.',
    upgradeDo: 'Результат последнего обновления модуля хранится в журнале модулей арендатора, который эта страница пока не умеет читать. Пока так, обратитесь к оператору платформы.',
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
    poolOf: 'слот пайдаланылуда',
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
    poolDo: 'Деректер базасына көп қосылым бос емес. Пайдаланушылардан біраз уақыт үлкен импорт пен экспортты тоқтатуды сұраңыз; көрсеткіш қызыл болып қалса, платформа операторына хабарлаңыз.',
    jobsDo: 'Тапсырмалар кезегін оқуға әзірге болмайды, ал жоспарлы тексерулер соңғы іске қосылу уақытын жазбайды. Содан кейін жоспарлы тапсырма орындалмаса, платформа операторына хабарласыңыз.',
    modulesDo: 'Модуль нұсқалары әр арендатор бойынша бөлек сақталады және платформаның жалпы көрсеткіштеріне кірмейді. Арендатордың өз модульдерін оқитын бөлек бет қажет. Ол болғанша платформа операторына хабарласыңыз.',
    upgradeDo: 'Модульдің соңғы жаңартуының нәтижесі арендатордың модуль журналында сақталады, бұл бет оны әзірге оқи алмайды. Ол болғанша платформа операторына хабарласыңыз.',
  },
}

type Messages = Record<keyof (typeof SUMMARY_MESSAGES)['en'], string>

const UNMEASURED: { key: keyof Messages; doKey: keyof Messages }[] = [
  { key: 'jobs', doKey: 'jobsDo' },
  { key: 'modules', doKey: 'modulesDo' },
  { key: 'upgrade', doKey: 'upgradeDo' },
]

const TITLE_KEY: Record<FigureId, keyof Messages> = {
  requests: 'requests',
  errors: 'errors',
  slowDb: 'slowDb',
  slowAppend: 'slowAppend',
  refresh: 'refresh',
  pool: 'pool',
}
const ACTION_KEY: Partial<Record<FigureId, keyof Messages>> = {
  errors: 'errorsDo',
  slowDb: 'slowDbDo',
  slowAppend: 'slowAppendDo',
  refresh: 'refreshDo',
  pool: 'poolDo',
}
const STATUS_PILL: Record<FigureStatus, { tone: StatusTone; glyph: StatusGlyph }> = {
  ok: { tone: 'success', glyph: 'dot' },
  warn: { tone: 'warning', glyph: 'half' },
  red: { tone: 'danger', glyph: 'triangle' },
  unknown: { tone: 'neutral', glyph: 'dash' },
}

function statusWord(m: Messages, s: FigureStatus): string {
  return s === 'ok' ? m.statusOk : s === 'warn' ? m.statusWarn : s === 'red' ? m.statusRed : m.statusUnknown
}

function valueText(m: Messages, f: Figure): string {
  if (f.value === null) return f.id === 'requests' || f.id === 'errors' ? m.measuring : '—'
  if (f.id === 'requests' || f.id === 'errors') return `${Math.round(f.value * 10) / 10} ${m.perMinute}`
  if (f.id === 'pool') return f.pool ? `${f.pool.inUse} / ${f.pool.cap} ${m.poolOf}` : '—'
  if (f.id === 'refresh') return `${Math.floor(f.value / 60)} ${m.minutesOld}`
  return `${Math.round(f.value * 1000) / 10}% ${m.sinceStart}`
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
    <section aria-labelledby="support-summary-heading" data-testid="support-summary" className="lf-msum">
      <h3 id="support-summary-heading" className="lf-card__title lf-msum__title">{m.heading}</h3>
      <div className="lf-msum__grid">
        {figures.map((f) => {
          const action = ACTION_KEY[f.id]
          const pill = STATUS_PILL[f.status]
          return (
            <div key={f.id} data-testid={`figure-${f.id}`} className="lf-msum__card">
              <div className="lf-msum__label">{m[TITLE_KEY[f.id]]}</div>
              <div className="lf-msum__value">{valueText(m, f)}</div>
              <div data-testid={`figure-${f.id}-status`}>
                <StatusPill tone={pill.tone} glyph={pill.glyph}>{statusWord(m, f.status)}</StatusPill>
              </div>
              {action && (f.status === 'warn' || f.status === 'red') && <p className="lf-msum__do">{m[action]}</p>}
            </div>
          )
        })}
        {UNMEASURED.map(({ key, doKey }) => (
          <div key={key} data-testid="figure-unmeasured" className="lf-msum__card">
            <div className="lf-msum__label">{m[key]}</div>
            <div>
              <StatusPill tone="neutral" glyph="dash">{m.notMeasured}</StatusPill>
            </div>
            <p className="lf-msum__do">{m[doKey]}</p>
          </div>
        ))}
      </div>
      {routes.length > 0 && (
        <div data-testid="error-routes" className="lf-msum__card lf-msum__card--routes">
          <strong>{m.errorRoutes}</strong>
          <ul className="lf-msum__routes">
            {routes.map((r) => (
              <li key={r.route}>{r.route} ({r.errors})</li>
            ))}
          </ul>
          <p className="lf-msum__do">{m.errorRoutesDo}</p>
        </div>
      )}
      <h3 className="lf-card__title lf-msum__title lf-msum__title--all">{m.allFigures}</h3>
    </section>
  )
}
