/** Harness twins of the two document screens with the header New menu open (T-1953): a shot cannot click, so the
 *  render is wrapped in ClickButton, which presses the trigger once the screen has rendered. */
import type { HarnessScreen } from '../types'
import { assetsDocumentsScreens, ClickButton } from './assetsDocuments'
import { stockDocumentsScreens } from './stockDocuments'

const NEW_LABELS = ['New document', 'Новый документ', 'Жаңа құжат']

function opened(source: HarnessScreen | undefined, name: string): HarnessScreen[] {
  return source ? [{ ...source, name, render: (ctx) => <ClickButton labels={NEW_LABELS}>{source.render(ctx)}</ClickButton> }] : []
}

export const pageHeaderNewMenuScreens: HarnessScreen[] = [
  ...opened(assetsDocumentsScreens.find((s) => s.name === 'asset-documents'), 'asset-documents-new-open'),
  ...opened(stockDocumentsScreens.find((s) => s.name === 'stock-documents'), 'stock-documents-new-open'),
]
