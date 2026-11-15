/** ApprovalRulesPage — T-1989 (four-eyes switch, slice 4; docs/design/four-eyes-switch.md).
 *  Route /admin/approval-rules, permission ApprovalRulesManage. A list of every step that needs a second
 *  person (ListDetail), and in the detail panel the switch with a required reason and a warning when it
 *  goes OFF. Server: GET /api/v1/approval-rules, PUT /api/v1/approval-rules/:definition_name/:node_id.
 *  `initialSelectedKey`, `initialDraft` and `submitOnMount` are HARNESS-ONLY props (the screenshot tool
 *  cannot click); the router never passes them. */
import React, { useCallback, useMemo, useState } from 'react'
import { useIntl } from 'react-intl'
import { PageHeader } from '@/components/ui/PageHeader'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { EmptyState } from '@/components/ui/EmptyState'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { ListDetail, useListSelection } from '@/components/ui/listDetail'
import { useToast } from '@/hooks/useToast'
import { useApprovalRulesList, useSaveApprovalRule } from '@/hooks/useApprovalRules'
import { classifyError } from '@/utils/classifyError'
import type { ApprovalRule } from '@/api/approvalRules'
import type { UiLocale } from '@/i18n/uiLocaleStore'
import { ApprovalRulesIntlProvider } from './ApprovalRulesIntlProvider'
import { ApprovalRuleDetail, type ApprovalRuleDraft } from './ApprovalRuleDetail'
import { RulePill } from './RulePill'
import { processName, ruleKey, saveErrorKey, stepName } from './approvalRulesModel'

export interface ApprovalRulesPageProps {
  locale?: UiLocale
  /** Harness only. */
  initialSelectedKey?: string
  /** Harness only. */
  initialDraft?: ApprovalRuleDraft
  /** Harness only. */
  submitOnMount?: boolean
}

export default function ApprovalRulesPage(props: ApprovalRulesPageProps): React.ReactElement {
  return (
    <ApprovalRulesIntlProvider locale={props.locale}>
      <ApprovalRulesInner {...props} />
    </ApprovalRulesIntlProvider>
  )
}

function ApprovalRulesInner({ initialSelectedKey, initialDraft, submitOnMount }: ApprovalRulesPageProps) {
  const intl = useIntl()
  const locale = intl.locale as UiLocale
  const t = (id: string) => intl.formatMessage({ id })
  const toast = useToast()
  const list = useApprovalRulesList()
  const save = useSaveApprovalRule()
  const sel = useListSelection(initialSelectedKey ?? null)
  const [dirty, setDirty] = useState(false)
  const onDirtyChange = useCallback((d: boolean) => setDirty(d), [])

  const items = useMemo(() => list.data?.items ?? [], [list.data])
  const selected = items.find((r) => ruleKey(r) === sel.selectedId) ?? null

  const errorKey = save.isError ? saveErrorKey(save.error) : null

  const columns: DataTableColumn<ApprovalRule>[] = [
    {
      id: 'process',
      header: t('approvalRules.col.process'),
      render: (r) => (
        <>
          {processName(r.definition_name, locale)}
          <br />
          <span className="mono caption lf-faint">{r.definition_name}</span>
        </>
      ),
    },
    { id: 'step', header: t('approvalRules.col.step'), render: (r) => stepName(r, locale) },
    { id: 'rule', header: t('approvalRules.col.rule'), render: (r) => <RulePill on={r.four_eyes} /> },
  ]

  const select = (id: string) => {
    save.reset()
    sel.select(id)
  }
  const close = () => {
    save.reset()
    sel.close()
  }

  const detail = selected ? (
    <ApprovalRuleDetail
      key={`${ruleKey(selected)}|${selected.four_eyes}|${selected.changed_at ?? ''}`}
      rule={selected}
      locale={locale}
      saving={save.isPending}
      errorKey={errorKey}
      onClose={close}
      onDirtyChange={onDirtyChange}
      initialDraft={initialDraft}
      submitOnMount={submitOnMount}
      onSave={(body) =>
        save.mutate(
          { definitionName: selected.definition_name, nodeId: selected.node_id, body },
          {
            onSuccess: () => {
              sel.saved({ kind: 'edit' })
              toast.success(t('approvalRules.toast.saved'))
            },
          },
        )
      }
    />
  ) : (
    <></>
  )

  return (
    <>
      <PageHeader eyebrow={t('approvalRules.eyebrow')} title={t('approvalRules.title')} lede={t('approvalRules.lede')} />
      <QueryStateBoundary
        state={list.isError ? classifyError(list.error) : 'success'}
        onRetry={() => void list.refetch()}
      >
        <ListDetail
          screen="admin.approval-rules"
          listLabel={t('approvalRules.list.label')}
          listDefault={45}
          defaultSelectId={items[0] ? ruleKey(items[0]) : null}
          onDefaultSelect={sel.select}
          detailOpen={selected !== null}
          onClose={close}
          escapeCloses={!dirty}
          list={
            <DataTable
              density="compact"
              columns={columns}
              data={items}
              isLoading={list.isLoading}
              getRowId={ruleKey}
              selectedId={sel.selectedId}
              onRowClick={(r) => select(ruleKey(r))}
              emptyMessage={t('approvalRules.empty')}
              emptyText={t('approvalRules.emptyText')}
              labels={{ loading: t('approvalRules.loading'), retry: t('approvalRules.retry') }}
            />
          }
          detail={detail}
          empty={
            <div className="lf-card__body">
              <EmptyState title={t('approvalRules.pick')} data-testid="approval-rules-pick" />
            </div>
          }
        />
      </QueryStateBoundary>
    </>
  )
}
