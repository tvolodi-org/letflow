import { Navigate } from 'react-router-dom'
import { useQuery, type UseQueryResult } from '@tanstack/react-query'
import { backupStatus, healthReady, readiness } from '@/api/health'
import { queryKeys } from '@/api/queryKeys'
import { useAccess, AccessPending } from '@/auth/access'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { StatusPill, type StatusTone, type StatusGlyph } from '@/components/ui/StatusPill'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { formatDateTime, formatTime } from '@/i18n/format'
import type { BackupJobLine, BackupStatus, ReadinessResult } from '@/types/api'

// NOTE (ISS-0532, T-1607): liveness comes from the real `GET /health`. Per-part readiness is
// `GET /ready` (database, migrations, secrets key, identity provider), and the platform operator's
// backup line is `GET /api/v1/platform-status/backup`. Each block handles its own load error so a
// failing probe never hides the others.
export function useAdminHealthSnapshot(): UseQueryResult<boolean> {
  return useQuery({
    queryKey: queryKeys.admin.health(),
    queryFn: () => healthReady(),
    refetchInterval: 15_000,
  })
}

export function useAdminReadiness(): UseQueryResult<ReadinessResult> {
  return useQuery({
    queryKey: queryKeys.admin.readiness(),
    queryFn: () => readiness(),
    refetchInterval: 15_000,
  })
}

export function useAdminBackupStatus(): UseQueryResult<BackupStatus> {
  return useQuery({
    queryKey: queryKeys.admin.backupStatus(),
    queryFn: () => backupStatus(),
    refetchInterval: 60_000,
  })
}

const HEALTH_MESSAGES = {
  en: {
    liveDo: 'The server answers. If users still report problems, open Metrics.',
    downDo: 'The server does not answer. Check that the service is running, then tell the platform operator.',
    readyTitle: 'Readiness by part',
    allReady: 'Every part is ready.',
    notReady: 'Not ready: {parts}.',
    partOk: 'OK',
    partFail: 'Failing',
    readyError: 'Readiness could not be read. The server may be down.',
    part_database: 'Database',
    part_migrations: 'Migrations',
    part_secrets_key: 'Secrets key',
    part_identity: 'Identity provider',
    do_database: 'The database does not answer. Check that PostgreSQL is running and reachable, then tell the platform operator.',
    do_migrations: 'A database migration has not been applied. Run the release migrations, then reload this page.',
    do_secrets_key: 'The secrets master key is missing or has the wrong size. Check LETFLOW_SECRETS_MASTER_KEY in the service environment.',
    do_identity: 'The identity provider does not answer. Check that Keycloak is running and the OIDC base URL is correct.',
    backupTitle: 'Backups',
    backupNotConfigured: 'Backup status is not configured on this server (LETFLOW_BACKUP_STATUS_DIR is not set). Ask infra to check the backup status files.',
    backupError: 'Backup status could not be read.',
    job_dump: 'Last dump',
    job_base: 'Last base backup',
    job_prune: 'Last prune',
    job_restore_test: 'Last restore test',
    state_ok: 'OK',
    state_failed: 'Failed',
    state_stale: 'Too old',
    state_missing: 'No report',
    state_unreadable: 'Unreadable',
    backupDo: 'A backup job is not healthy. See docs/runbooks/backup-restore.md and tell the platform operator.',
    backupAge: 'at {when}',
  },
  ru: {
    liveDo: 'Сервер отвечает. Если пользователи всё же жалуются на проблемы, откройте «Метрики».',
    downDo: 'Сервер не отвечает. Проверьте, что сервис запущен, затем сообщите оператору платформы.',
    readyTitle: 'Готовность по частям',
    allReady: 'Все части готовы.',
    notReady: 'Не готово: {parts}.',
    partOk: 'Работает',
    partFail: 'Сбой',
    readyError: 'Не удалось прочитать готовность. Возможно, сервер не работает.',
    part_database: 'База данных',
    part_migrations: 'Миграции',
    part_secrets_key: 'Ключ секретов',
    part_identity: 'Провайдер идентификации',
    do_database: 'База данных не отвечает. Проверьте, что PostgreSQL запущен и доступен, затем сообщите оператору платформы.',
    do_migrations: 'Не применена миграция базы данных. Выполните миграции релиза и перезагрузите страницу.',
    do_secrets_key: 'Главный ключ секретов отсутствует или имеет неверный размер. Проверьте LETFLOW_SECRETS_MASTER_KEY в окружении сервиса.',
    do_identity: 'Провайдер идентификации не отвечает. Проверьте, что Keycloak запущен и адрес OIDC указан верно.',
    backupTitle: 'Резервные копии',
    backupNotConfigured: 'Статус резервных копий на этом сервере не настроен (LETFLOW_BACKUP_STATUS_DIR не задана). Попросите инфраструктуру проверить файлы статуса.',
    backupError: 'Не удалось прочитать статус резервных копий.',
    job_dump: 'Последний дамп',
    job_base: 'Последняя базовая копия',
    job_prune: 'Последняя очистка',
    job_restore_test: 'Последняя проверка восстановления',
    state_ok: 'Норма',
    state_failed: 'Сбой',
    state_stale: 'Устарело',
    state_missing: 'Нет отчёта',
    state_unreadable: 'Не читается',
    backupDo: 'Задача резервного копирования не в порядке. См. docs/runbooks/backup-restore.md и сообщите оператору платформы.',
    backupAge: 'в {when}',
  },
  kk: {
    liveDo: 'Сервер жауап беріп тұр. Пайдаланушылар әлі де мәселе туралы айтса, «Метрикалар» бетін ашыңыз.',
    downDo: 'Сервер жауап бермейді. Қызметтің іске қосылғанын тексеріңіз, содан кейін платформа операторына хабарлаңыз.',
    readyTitle: 'Бөліктер бойынша дайындық',
    allReady: 'Барлық бөлік дайын.',
    notReady: 'Дайын емес: {parts}.',
    partOk: 'Жұмыс істейді',
    partFail: 'Ақау',
    readyError: 'Дайындықты оқу мүмкін болмады. Сервер істемей тұрған болуы мүмкін.',
    part_database: 'Деректер қоры',
    part_migrations: 'Миграциялар',
    part_secrets_key: 'Құпиялар кілті',
    part_identity: 'Сәйкестендіру провайдері',
    do_database: 'Деректер қоры жауап бермейді. PostgreSQL іске қосылғанын және қолжетімді екенін тексеріңіз, содан кейін платформа операторына хабарлаңыз.',
    do_migrations: 'Деректер қорының миграциясы қолданылмаған. Релиз миграцияларын орындап, бетті қайта жүктеңіз.',
    do_secrets_key: 'Құпиялардың басты кілті жоқ немесе көлемі дұрыс емес. Қызмет ортасындағы LETFLOW_SECRETS_MASTER_KEY мәнін тексеріңіз.',
    do_identity: 'Сәйкестендіру провайдері жауап бермейді. Keycloak іске қосылғанын және OIDC мекенжайы дұрыс екенін тексеріңіз.',
    backupTitle: 'Сақтық көшірмелер',
    backupNotConfigured: 'Бұл серверде сақтық көшірме күйі бапталмаған (LETFLOW_BACKUP_STATUS_DIR орнатылмаған). Инфрақұрылымнан күй файлдарын тексеруді сұраңыз.',
    backupError: 'Сақтық көшірме күйін оқу мүмкін болмады.',
    job_dump: 'Соңғы дамп',
    job_base: 'Соңғы базалық көшірме',
    job_prune: 'Соңғы тазалау',
    job_restore_test: 'Соңғы қалпына келтіру тексерісі',
    state_ok: 'Қалыпты',
    state_failed: 'Ақау',
    state_stale: 'Ескірген',
    state_missing: 'Есеп жоқ',
    state_unreadable: 'Оқылмайды',
    backupDo: 'Сақтық көшірме тапсырмасы дұрыс емес. docs/runbooks/backup-restore.md құжатын қараңыз да, платформа операторына хабарлаңыз.',
    backupAge: '{when}',
  },
} as const

type Msgs = (typeof HEALTH_MESSAGES)[keyof typeof HEALTH_MESSAGES]

const JOB_STATE_PILL: Record<BackupJobLine['state'], { tone: StatusTone; glyph: StatusGlyph }> = {
  ok: { tone: 'success', glyph: 'dot' },
  failed: { tone: 'danger', glyph: 'triangle' },
  stale: { tone: 'warning', glyph: 'half' },
  missing: { tone: 'neutral', glyph: 'dash' },
  unreadable: { tone: 'warning', glyph: 'ring' },
}

function ReadinessBlock({ hm, query }: { hm: Msgs; query: UseQueryResult<ReadinessResult> }) {
  const label = (part: string) => hm[`part_${part}` as keyof Msgs] as string
  const todo = (part: string) => hm[`do_${part}` as keyof Msgs] as string
  const result = query.data
  const failing = result ? result.parts.filter((p) => !p.ok) : []
  return (
    <section data-testid="readiness-block" aria-labelledby="readiness-title" className="lf-health__block">
      <h3 id="readiness-title" className="lf-health__title">{hm.readyTitle}</h3>
      {query.isLoading && <p data-testid="readiness-loading" className="lf-health__do">…</p>}
      {query.isError && <p data-testid="readiness-error" role="alert" className="lf-health__do">{hm.readyError}</p>}
      {result && (
        <>
          <p data-testid="readiness-summary" className="lf-health__do">
            {failing.length === 0 ? hm.allReady : hm.notReady.replace('{parts}', failing.map((p) => label(p.part)).join(', '))}
          </p>
          <ul className="lf-health__list">
            {result.parts.map((p) => (
              <li key={p.part} data-testid={`readiness-${p.part}`} data-ok={p.ok ? 'true' : 'false'} className="lf-health__row">
                <span className="lf-health__name">{label(p.part)}</span>
                <StatusPill tone={p.ok ? 'success' : 'danger'} glyph={p.ok ? 'dot' : 'triangle'}>
                  {p.ok ? hm.partOk : hm.partFail}
                </StatusPill>
                {!p.ok && <span className="lf-health__do">{todo(p.part)}</span>}
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  )
}

function BackupBlock({ hm, query }: { hm: Msgs; query: UseQueryResult<BackupStatus> }) {
  const data = query.data
  const unhealthy = data?.jobs.some((j) => j.state === 'failed' || j.state === 'stale') ?? false
  return (
    <section data-testid="backup-block" aria-labelledby="backup-title" className="lf-health__block">
      <h3 id="backup-title" className="lf-health__title">{hm.backupTitle}</h3>
      {query.isLoading && <p data-testid="backup-loading" className="lf-health__do">…</p>}
      {query.isError && <p data-testid="backup-error" role="alert" className="lf-health__do">{hm.backupError}</p>}
      {data && !data.configured && (
        <p data-testid="backup-not-configured" role="status" className="lf-health__do">{hm.backupNotConfigured}</p>
      )}
      {data && data.configured && (
        <>
          <ul className="lf-health__list">
            {data.jobs.map((j) => {
              const pill = JOB_STATE_PILL[j.state]
              return (
                <li key={j.job} data-testid={`backup-${j.job}`} data-state={j.state} className="lf-health__row">
                  <span className="lf-health__name">{hm[`job_${j.job}` as keyof Msgs] as string}</span>
                  <StatusPill tone={pill.tone} glyph={pill.glyph}>{hm[`state_${j.state}` as keyof Msgs] as string}</StatusPill>
                  {j.ts && (
                    <span className="lf-health__when">{hm.backupAge.replace('{when}', formatDateTime(j.ts))}</span>
                  )}
                </li>
              )
            })}
          </ul>
          {unhealthy && <p data-testid="backup-action" className="lf-health__do">{hm.backupDo}</p>}
        </>
      )}
    </section>
  )
}

export default function HealthDashboardPage() {
  const access = useAccess()
  const hm = HEALTH_MESSAGES[useUiLocale()]
  const isAllowed = access.canManageTenants
  const readinessQuery = useAdminReadiness()
  const backupQuery = useAdminBackupStatus()
  const { data: isLive, isLoading, isFetching, isError, error, dataUpdatedAt, refetch } = useAdminHealthSnapshot()

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return <Navigate to="/instances" replace />
  }

  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'
  const livenessLabel = isLive ? 'LIVE' : 'UNREACHABLE'
  const livenessColor = isLive ? 'var(--color-success-dark)' : 'var(--color-error-dark)'

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '1rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Health</h2>
        {dataUpdatedAt > 0 && (
          <span style={{ fontSize: 'var(--text-xs)', color: 'var(--text-secondary)' }}>
            Updated {formatTime(dataUpdatedAt)}
          </span>
        )}
        {isFetching && <span style={{ fontSize: 'var(--text-xs)', color: 'var(--color-info-dark)' }}>Refreshing…</span>}
        <span style={{ marginLeft: 'auto' }}>
          <Button variant="secondary" size="sm" onClick={() => { void refetch() }}>
            Refresh now
          </Button>
        </span>
      </div>

      <QueryStateBoundary state={rendererState} onRetry={() => { void refetch() }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1.25rem' }}>
          <span
            data-testid="liveness-badge"
            style={{ fontWeight: 700, fontSize: 'var(--text-lg)', color: livenessColor }}
          >
            {livenessLabel}
          </span>
          <span style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>Backend liveness (GET /health)</span>
        </div>

        <p data-testid="liveness-action" className="lf-health__do">
          {isLive ? hm.liveDo : hm.downDo}
        </p>

        <ReadinessBlock hm={hm} query={readinessQuery} />
        <BackupBlock hm={hm} query={backupQuery} />
      </QueryStateBoundary>
    </div>
  )
}
