/** ApprovalRuleDetail — T-1989. The detail panel of one approval step: facts, and the switch form
 *  (switch, warning when going OFF, required reason, Save / Cancel). No modal (design-system rule 2a).
 *  The page keys this component by rule + stored value, so a refetch resets the draft. */
import { Fragment, useEffect, useState } from 'react'
import { useIntl } from 'react-intl'
import { X } from 'lucide-react'
import type { ApprovalRule } from '@/api/approvalRules'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Switch } from '@/components/ui/Checkbox'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { Field } from '@/components/ui/Field'
import { formatDateTime } from '@/i18n/format'
import type { UiLocale } from '@/i18n/uiLocaleStore'
import { processName, stepName } from './approvalRulesModel'
import { RulePill } from './RulePill'

export interface ApprovalRuleDraft {
  fourEyes: boolean
  reason: string
}

interface Props {
  rule: ApprovalRule
  locale: UiLocale
  saving: boolean
  /** Message id of the failed save, or null. `invalid_reason` shows under the field, the rest as a banner. */
  errorKey: string | null
  onSave: (body: { four_eyes: boolean; reason: string }) => void
  onClose: () => void
  onDirtyChange: (dirty: boolean) => void
  /** Harness only: start with this draft (the screenshot tool cannot click). */
  initialDraft?: ApprovalRuleDraft
  /** Harness only: submit the initial draft once, one frame after mount. */
  submitOnMount?: boolean
}

export function ApprovalRuleDetail({
  rule,
  locale,
  saving,
  errorKey,
  onSave,
  onClose,
  onDirtyChange,
  initialDraft,
  submitOnMount,
}: Props) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const [fourEyes, setFourEyes] = useState(initialDraft?.fourEyes ?? rule.four_eyes)
  const [reason, setReason] = useState(initialDraft?.reason ?? '')

  const dirty = fourEyes !== rule.four_eyes
  const trimmed = reason.trim()
  // The server refuses to switch OFF a step that left the active definitions (not_a_four_eyes_step).
  const locked = !rule.in_active_definition && rule.four_eyes
  const reasonError = errorKey === 'approvalRules.error.invalid_reason' ? t(errorKey) : null
  const bannerError = errorKey !== null && reasonError === null ? t(errorKey) : null

  useEffect(() => {
    onDirtyChange(dirty)
  }, [dirty, onDirtyChange])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])

  const submit = () => {
    if (!dirty || trimmed === '' || saving) return
    onSave({ four_eyes: fourEyes, reason: trimmed })
  }

  useEffect(() => {
    if (!submitOnMount) return
    const frame = requestAnimationFrame(() => {
      if (initialDraft && initialDraft.fourEyes !== rule.four_eyes && initialDraft.reason.trim() !== '') {
        onSave({ four_eyes: initialDraft.fourEyes, reason: initialDraft.reason.trim() })
      }
    })
    return () => cancelAnimationFrame(frame)
    // Once on mount: the harness draft is fixed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const dash = '—'
  let lastChange: string
  if (rule.changed_at == null) {
    lastChange = t('approvalRules.change.never')
  } else {
    const who = rule.changed_by_name ?? t('approvalRules.change.unknownUser')
    lastChange = t('approvalRules.change.by', { name: who, when: formatDateTime(rule.changed_at) })
  }

  return (
    <>
      <DetailHeader
        title={processName(rule.definition_name, locale)}
        path={stepName(rule, locale)}
        status={<RulePill on={rule.four_eyes} />}
        actions={
          <Button
            variant="ghost"
            size="sm"
            iconOnly
            label={t('approvalRules.close')}
            icon={<X className="lf-icon" aria-hidden="true" />}
            onClick={onClose}
          />
        }
      />
      <div className="lf-card__body lf-form">
        {!rule.in_active_definition && (
          <Banner tone="info">
            <span data-testid="approval-rule-orphan">{t('approvalRules.orphan')}</span>
          </Banner>
        )}
        <dl className="lf-dl" data-testid="approval-rule-facts">
          <dt>{t('approvalRules.detail.process')}</dt>
          <dd>
            {processName(rule.definition_name, locale)} <span className="mono">{rule.definition_name}</span>
          </dd>
          <dt>{t('approvalRules.detail.step')}</dt>
          <dd>
            {stepName(rule, locale)} <span className="mono">{rule.node_id}</span>
          </dd>
          <dt>{t('approvalRules.detail.rule')}</dt>
          <dd>{t(rule.four_eyes ? 'approvalRules.rule.on' : 'approvalRules.rule.off')}</dd>
          <dt>{t('approvalRules.detail.lastChange')}</dt>
          <dd data-testid="approval-rule-last-change">{lastChange}</dd>
          {rule.reason != null && rule.reason !== '' && (
            <Fragment>
              <dt>{t('approvalRules.reason.label')}</dt>
              <dd data-testid="approval-rule-last-reason">{rule.reason}</dd>
            </Fragment>
          )}
          {rule.reason == null && rule.changed_at != null && (
            <Fragment>
              <dt>{t('approvalRules.reason.label')}</dt>
              <dd>{dash}</dd>
            </Fragment>
          )}
        </dl>

        <form
          className="lf-form"
          onSubmit={(e) => {
            e.preventDefault()
            submit()
          }}
          data-testid="approval-rule-form"
        >
          <Switch
            data-testid="approval-rule-switch"
            label={t('approvalRules.switch.label')}
            checked={fourEyes}
            disabled={locked || saving}
            onChange={setFourEyes}
          />
          {locked && <p className="caption lf-faint">{t('approvalRules.switch.locked')}</p>}
          {dirty && !fourEyes && (
            <Banner tone="warning" title={t('approvalRules.warn.title')}>
              <span data-testid="approval-rule-warning">{t('approvalRules.warn.text')}</span>
            </Banner>
          )}
          {dirty && (
            <Field
              label={t('approvalRules.reason.label')}
              hint={trimmed === '' ? t('approvalRules.reason.required') : t('approvalRules.reason.hint')}
              error={reasonError ?? undefined}
            >
              <textarea
                data-testid="approval-rule-reason"
                rows={3}
                maxLength={500}
                value={reason}
                onChange={(e) => setReason(e.target.value)}
              />
            </Field>
          )}
          {bannerError !== null && (
            <div data-testid="approval-rule-save-error">
              <Banner tone="danger">{bannerError}</Banner>
            </div>
          )}
          {dirty && (
            <div className="lf-btn-row">
              <Button variant="primary" type="submit" disabled={trimmed === ''} loading={saving} data-testid="approval-rule-save">
                {t('approvalRules.save')}
              </Button>
              <Button
                variant="secondary"
                type="button"
                data-testid="approval-rule-cancel"
                onClick={() => {
                  setFourEyes(rule.four_eyes)
                  setReason('')
                }}
              >
                {t('approvalRules.cancel')}
              </Button>
            </div>
          )}
        </form>
      </div>
    </>
  )
}
