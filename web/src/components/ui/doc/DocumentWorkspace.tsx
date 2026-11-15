/** Count orders share the document grid and preferences with stock and asset documents. All record panels are
 *  direct grid children, including the work/lines slot; no screen owns its own arrangement. */
import type { ReactNode } from 'react'
import { Button } from '../Button'
import { useUiMessages } from '../uiMessages'
import { DocBar, DocCard, DocLayout, DocTabList } from './DocLayout'
import { useLayoutMessages } from '../layout/layoutMessages'

export function DocumentWorkspace(props: {
  screen: string
  listLabel: string
  tools?: ReactNode
  list: ReactNode
  listFooter?: ReactNode
  detail: ReactNode
  empty: ReactNode
  detailOpen: boolean
  docKey?: string
  creating?: boolean
  onClose: () => void
}) {
  return (
    <DocLayout screen={props.screen} detailOpen={props.detailOpen} docState={props.creating ? 'new' : props.detailOpen ? 'existing' : 'none'} docKey={props.docKey} onClose={props.onClose} data-testid="document-workspace">
      <section className="lf-card lf-doc__list" aria-label={props.listLabel}>
        {props.tools && <div className="lf-doc__tools">{props.tools}</div>}
        <div className="lf-doc__scroll">{props.list}</div>
        {props.listFooter}
      </section>
      {props.detailOpen ? (
        props.creating ? <DocumentSingle onClose={props.onClose}>{props.detail}</DocumentSingle> : props.detail
      ) : <section className="lf-doc__blank">{props.empty}</section>}
    </DocLayout>
  )
}

export function DocumentSingle({ children, onClose }: { children: ReactNode; onClose: () => void }) {
  const ui = useUiMessages()
  return <section className="lf-card lf-doc__blank"><Button variant="ghost" size="sm" onClick={onClose}>{ui.back}</Button>{children}</section>
}

export function DocumentRecord(props: {
  title: string
  status?: ReactNode
  actions?: ReactNode
  header: ReactNode
  lines: ReactNode
  onClose: () => void
}) {
  const m = useLayoutMessages()
  const ui = useUiMessages()
  return (
    <>
      <DocBar title={props.title} status={props.status} actions={props.actions} onBack={props.onClose} backLabel={ui.back} />
      <DocTabList labels={{ header: m.documentHeader, lines: m.documentLines }} ariaLabel={props.title} problemLabel={String} />
      <DocCard area="header" title={m.documentHeader}><div className="lf-card__body">{props.header}</div></DocCard>
      <DocCard area="lines" title={m.documentLines}><div className="lf-card__body">{props.lines}</div></DocCard>
    </>
  )
}
