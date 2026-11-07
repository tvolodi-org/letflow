/** DocumentTabs — the tab block of the asset document view. Renders nothing in the `row` layout. */
import { useIntl } from 'react-intl'
import { DocTabList } from '@/components/ui/doc/DocLayout'
import type { DocPane } from '@/components/ui/doc/docLayouts'

export function DocumentTabs({ lineCount, problems }: { lineCount?: number; problems?: Record<DocPane, number> }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  return (
    <DocTabList
      labels={{ header: t('assets.doc.header'), lines: t('assets.doc.lines') }}
      ariaLabel={t('assets.doc.tabs.label')}
      lineCount={lineCount}
      problems={problems}
      problemLabel={(count) => intl.formatMessage({ id: 'assets.doc.tabs.problems' }, { count })}
    />
  )
}
