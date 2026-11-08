/** Display names of the assets module's process definitions, by the stable definition key (the wire shape
 *  carries only the key). Same pattern as `auth/access/roleLabels.ts`. A name not in the catalog (a tenant's own
 *  definition) is already a human name and is shown unchanged. */
import { getUiLocale, type UiLocale } from '@/i18n/uiLocaleStore'

export const DEFINITION_LABELS: Record<string, Record<UiLocale, string>> = {
  assets_change: { en: 'Change of asset data', ru: 'Изменение данных актива', kk: 'Актив деректерін өзгерту' },
  assets_kind_change: { en: 'Change of asset kind', ru: 'Смена вида актива', kk: 'Актив түрін ауыстыру' },
  assets_writeoff: { en: 'Asset write-off', ru: 'Списание актива', kk: 'Активті есептен шығару' },
  assets_handover: { en: 'Asset handover', ru: 'Передача актива', kk: 'Активті тапсыру' },
  assets_reversal: { en: 'Reversal of an asset document', ru: 'Сторнирование документа по активам', kk: 'Актив құжатын сторнолау' },
}

export function definitionLabel(name: string, locale: UiLocale = getUiLocale()): string {
  return Object.hasOwn(DEFINITION_LABELS, name) ? DEFINITION_LABELS[name][locale] : name
}
