/** OrgScreen — GH 3609 / REQ-669, style S1. The frame of the three org-structure screens (legal companies, sites,
 *  org units): PageHeader, then MasterDetail with the list or tree on the left and the record in the detail panel
 *  on the right (skill rule 2a: viewing and editing one record is never a modal). Owns the page states: loading
 *  skeleton, load error with retry, empty with an action. The panel has a close button and closes on Escape.
 *  Everything is built from the shared components; this file has no colour or spacing of its own. */
import type { KeyboardEvent, ReactNode } from 'react'
import { Plus, X } from 'lucide-react'
import type { UseQueryResult } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Checkbox } from '@/components/ui/Checkbox'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { EmptyState } from '@/components/ui/EmptyState'
import { FormActions } from '@/components/ui/FormSection'
import { MasterDetail } from '@/components/ui/MasterDetail'
import { PageHeader } from '@/components/ui/PageHeader'
import { Skeleton } from '@/components/ui/Skeleton'
import { StatusPill } from '@/components/ui/StatusPill'
import { TreeView, type TreeNode } from '@/components/ui/TreeView'
import { useOrgLocale } from './OrgIntlProvider'

export interface OrgScreenProps {
  title: string
  lede: string
  createLabel: string
  /** False hides every write action (create here; edit, move, retire in the panel). */
  canWrite: boolean
  onCreate: () => void
  queries: UseQueryResult<unknown>[]
  showRetired: boolean
  onShowRetired: (v: boolean) => void
  /** Rows currently listed (the tools row shows the count). */
  count: number
  /** The detail panel (an `OrgDetail`) or null while nothing is open. */
  detail: ReactNode | null
  /** Escape closes the panel; false while a dialog is open (the dialog takes the key). */
  escapeCloses: boolean
  onClosePanel: () => void
  /** Dialogs of the screen. */
  children?: ReactNode
  master: ReactNode
}

/** The master column: skeleton while loading, a banner with Retry on a failed load, the content otherwise. */
function MasterBody(props: { queries: UseQueryResult<unknown>[]; children: ReactNode }) {
  const intl = useIntl()
  const failed = props.queries.find((q) => q.isError)
  if (failed) {
    return (
      <Banner
        tone="danger"
        action={
          <Button
            variant="ghost"
            size="sm"
            onClick={() => props.queries.forEach((q) => void q.refetch())}
            data-testid="org-retry"
          >
            {intl.formatMessage({ id: 'org.common.retry' })}
          </Button>
        }
      >
        {intl.formatMessage({ id: 'org.common.loadError' })}
      </Banner>
    )
  }
  if (props.queries.some((q) => q.isPending)) {
    return (
      <div className="lf-form" aria-busy="true" data-testid="org-skeleton">
        {[0, 1, 2, 3, 4].map((i) => (
          <Skeleton key={i} width={i % 2 === 0 ? '80%' : '60%'} />
        ))}
      </div>
    )
  }
  return <>{props.children}</>
}

export function OrgScreen(props: OrgScreenProps) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const loaded = !props.queries.some((q) => q.isPending || q.isError)

  function onKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    if (e.key === 'Escape' && props.detail !== null && props.escapeCloses && !e.defaultPrevented) {
      e.preventDefault()
      props.onClosePanel()
    }
  }

  // A fragment: the page's grid (`.lf-content` of the shell) spaces the header, the panel row and the toasts.
  return (
    <>
      <PageHeader
        eyebrow={t('org.common.eyebrow')}
        title={props.title}
        lede={props.lede}
        actions={
          props.canWrite ? (
            <Button
              variant="primary"
              size="md"
              icon={<Plus className="lf-icon" aria-hidden="true" />}
              onClick={props.onCreate}
              data-testid="org-create"
            >
              {props.createLabel}
            </Button>
          ) : undefined
        }
      />
      <div onKeyDown={onKeyDown} data-testid="org-screen">
        <MasterDetail
          detailOpen={props.detail !== null}
          onBack={props.onClosePanel}
          tools={
            <div className="lf-btn-row lf-btn-row--between" data-testid="org-retired-row">
              <Checkbox label={t('org.common.showRetired')} checked={props.showRetired} onChange={props.onShowRetired} />
              {loaded && (
                <span className="caption lf-faint" data-testid="org-count">
                  {intl.formatMessage({ id: 'org.common.count' }, { count: props.count })}
                </span>
              )}
            </div>
          }
          master={<MasterBody queries={props.queries}>{props.master}</MasterBody>}
          detail={
            props.detail ?? (
              <div className="lf-card__body">
                <EmptyState
                  data-testid="org-pick"
                  title={t('org.common.pick')}
                  text={t('org.common.pickText')}
                />
              </div>
            )
          }
        />
      </div>
      {props.children}
    </>
  )
}

/** The empty list: text and, with write permission, the create action. */
export function OrgEmpty(props: { canWrite: boolean; createLabel: string; onCreate: () => void }) {
  const intl = useIntl()
  return (
    <EmptyState
      data-testid="org-empty"
      title={intl.formatMessage({ id: 'org.common.empty' })}
      text={intl.formatMessage({ id: 'org.common.emptyText' })}
      action={
        props.canWrite ? (
          <Button variant="primary" size="md" onClick={props.onCreate} data-testid="org-empty-create">
            {props.createLabel}
          </Button>
        ) : undefined
      }
    />
  )
}

/** The record panel: header (path, title, status, actions, close) and the form as its body. */
export function OrgDetail(props: {
  title: string
  path?: string
  status?: ReactNode
  actions?: ReactNode
  onClose: () => void
  children: ReactNode
}) {
  const intl = useIntl()
  return (
    <div data-testid="org-detail">
      <DetailHeader
        title={props.title}
        path={props.path}
        status={props.status}
        actions={
          <>
            {props.actions}
            <Button
              variant="ghost"
              size="sm"
              iconOnly
              label={intl.formatMessage({ id: 'org.common.close' })}
              icon={<X className="lf-icon" aria-hidden="true" />}
              onClick={props.onClose}
              data-testid="org-close"
            />
          </>
        }
      />
      <div className="lf-card__body">{props.children}</div>
    </div>
  )
}

/** The list or tree of the master column. `nodes` may be nested (units) or flat (companies, sites). */
export function OrgTree(props: {
  label: string
  nodes: TreeNode[]
  selectedId: string | null
  showRetired: boolean
  expandedIds: ReadonlyArray<string>
  onSelect: (id: string) => void
  onToggle: (id: string) => void
}) {
  const intl = useIntl()
  return (
    <TreeView
      aria-label={props.label}
      nodes={props.nodes}
      selectedId={props.selectedId}
      expandedIds={props.expandedIds}
      showRetired={props.showRetired}
      onSelect={props.onSelect}
      onToggle={props.onToggle}
      labels={{
        expand: intl.formatMessage({ id: 'org.common.expand' }),
        collapse: intl.formatMessage({ id: 'org.common.collapse' }),
        retired: intl.formatMessage({ id: 'org.common.retired' }),
        loading: intl.formatMessage({ id: 'org.common.loading' }),
      }}
    />
  )
}

/** The form of the panel: fields as children, then Save and Cancel with the unsaved-changes hint.
 *  A retired record is shown read-only (`readOnly`): no Save. */
export function OrgForm(props: {
  label: string
  error?: ReactNode
  readOnly?: boolean
  dirty: boolean
  saving: boolean
  onSubmit: () => void
  onCancel: () => void
  children: ReactNode
}) {
  const intl = useIntl()
  const locale = useOrgLocale()
  return (
    <form
      className="lf-form"
      aria-label={props.label}
      onSubmit={(e) => {
        e.preventDefault()
        if (!props.readOnly) props.onSubmit()
      }}
    >
      {props.error}
      {props.children}
      {!props.readOnly && (
        <FormActions
          locale={locale}
          dirty={props.dirty}
          saving={props.saving}
          primary={
            <Button variant="primary" size="md" type="submit" disabled={props.saving} data-testid="org-save">
              {intl.formatMessage({ id: 'org.common.save' })}
            </Button>
          }
          secondary={
            <Button variant="ghost" size="md" onClick={props.onCancel} data-testid="org-cancel">
              {intl.formatMessage({ id: 'org.common.cancel' })}
            </Button>
          }
        />
      )}
    </form>
  )
}

/** Active / Retired as a StatusPill (a word and a glyph, never colour alone). */
export function OrgStatus({ active }: { active: boolean }) {
  const intl = useIntl()
  return active ? (
    <StatusPill tone="success" glyph="dot">
      {intl.formatMessage({ id: 'org.common.active' })}
    </StatusPill>
  ) : (
    <StatusPill tone="neutral" glyph="dash">
      {intl.formatMessage({ id: 'org.common.retired' })}
    </StatusPill>
  )
}
