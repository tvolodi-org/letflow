/** entityWidgetRegistry — REQ-342
 *
 *  Registers the two entity-definition-driven widgets this requirement adds
 *  (`entity-localized-text`, `entity-fk-reference`) into the SAME
 *  `fieldRegistry` map REQ-284/CMP-UI-05 built and REQ-336's `EntityRecordForm`
 *  already routes every field through (`FieldFactory.renderFormField` ->
 *  `fieldRegistry.get(fieldDef.xUiWidget)`). This is a second, independent
 *  registration point, deliberately NOT folded into
 *  `web/src/components/forms/widgets/index.ts`'s `registerBuiltinWidgets()`:
 *  that function's `RENDERERS_BY_NAME` is typed against
 *  `vocabulary.ts`'s `X_UI_WIDGET_NAMES` -- the CLOSED, tenant-facing
 *  `x-ui.widget` vocabulary a form_schema author can put in JSON
 *  (docs/frontend/x-ui-widget-vocabulary.md). These two widget keys are not
 *  part of that document; they are internal routing names this bridge
 *  (`entityFieldToFormField.ts`) assigns itself, from entity-definition
 *  metadata (`:localized_text`, `foreign_keys`) no tenant ever writes as a
 *  literal `x-ui.widget` string. Extending `X_UI_WIDGET_NAMES` to include
 *  them would misrepresent them as tenant-authorable, which they are not.
 *
 *  `registerEntityWidgets()` is idempotent (a `Map.set` on an already-set
 *  key is a no-op replacement) and safe to call from every module that
 *  needs the entity widgets available -- `EntityRecordForm.tsx` calls it as
 *  a side effect at import time, mirroring `main.tsx`'s
 *  `registerBuiltinWidgets()` call for the closed vocabulary.
 */

import { fieldRegistry } from '@/components/forms/fieldRegistry'
import { localizedTextRenderer } from '@/components/forms/widgets/localizedText'
import { entityReferenceSelectRenderer } from '@/components/forms/widgets/searchableSelect'
import { categoryTreeSelectRenderer } from '@/components/forms/widgets/categoryTreeSelect'

export const ENTITY_LOCALIZED_TEXT_WIDGET = 'entity-localized-text'
export const ENTITY_FK_REFERENCE_WIDGET = 'entity-fk-reference'
/** REQ-586 part D: the indented tree picker for `category.parent_id` only. */
export const ENTITY_CATEGORY_TREE_WIDGET = 'entity-category-tree'

let registered = false

export function registerEntityWidgets(): void {
  if (registered) return
  fieldRegistry.set(ENTITY_LOCALIZED_TEXT_WIDGET, localizedTextRenderer)
  fieldRegistry.set(ENTITY_FK_REFERENCE_WIDGET, entityReferenceSelectRenderer)
  fieldRegistry.set(ENTITY_CATEGORY_TREE_WIDGET, categoryTreeSelectRenderer)
  registered = true
}

registerEntityWidgets()
