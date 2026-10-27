/** entityFieldToFormField — REQ-336, extended by REQ-342
 *
 *  Bridges `Letflow.Entities.Definition.field_def()` (as returned by
 *  `GET /entities/definitions/active/:name`, `EntityFieldDef` in
 *  web/src/types/api.ts) into `TaskFormField` (web/src/types/forms.ts) --
 *  the SAME type `DynamicFormRenderer`/`FieldFactory.renderFormField`
 *  already consume for form_schema-driven task forms. This is the one
 *  translation point; nothing downstream of it is a parallel widget system.
 *  `renderFormField` is called directly with the result, so a `tag.name`
 *  field (`type: "string", required: true`, no `enum_values`) takes the
 *  IDENTICAL `fieldType === 'string' && !fieldDef.widget && !fieldDef.enum`
 *  branch a form_schema `:string` field would.
 *
 *  REQ-342 -- `:localized_text` and foreign-key fields.
 *  `:localized_text` had NO existing form_schema/fieldRegistry.ts coverage
 *  before this requirement (confirmed by grep -- no `localized` hit anywhere
 *  under web/src/components/forms/ prior to this change): this bridge
 *  previously degraded it to a plain `'string'` field, deliberately, exactly
 *  so a future entity type carrying one would not crash before a real widget
 *  existed (see the prior revision of this comment, preserved in git
 *  history). That widget is `ENTITY_LOCALIZED_TEXT_WIDGET`
 *  (web/src/components/entities/entityWidgetRegistry.ts), routed to via
 *  `xUiWidget` exactly as REQ-284's other registry widgets are; `locales`
 *  is copied through verbatim so the widget renders the field's own locale
 *  set rather than a hard-coded one.
 *
 *  A foreign-key field (a plain `:string`/`:integer` field named in the
 *  definition document's OWN `foreign_keys` list, e.g. `question.category_id`
 *  -> `fk_question_category_id` -> `references_entity: "category"`) is not
 *  distinguishable from `EntityFieldDef` alone -- `foreign_keys` lives on
 *  the definition document, one level up. Callers (`EntityRecordForm`) that
 *  have the definition in hand pass the matching `EntityFkDef` as this
 *  function's second argument; when present, it routes the field to
 *  `ENTITY_FK_REFERENCE_WIDGET` with `referencesEntity` set, taking priority
 *  over the field's own `type`-driven mapping (a `references_entity`-carrying
 *  field always renders as a reference lookup, never as a plain text/number
 *  input).
 */

import type { EntityFieldDef, EntityFkDef } from '@/types/api'
import type { TaskFormField } from '@/types/forms'
import {
  ENTITY_CATEGORY_TREE_WIDGET,
  ENTITY_FK_REFERENCE_WIDGET,
  ENTITY_LOCALIZED_TEXT_WIDGET,
} from '@/components/entities/entityWidgetRegistry'

/** `EntityFieldType` -> `TaskFormField['type']`. `:decimal`/`:integer` both
 *  map to `'number'` (TaskFormField has no separate decimal type);
 *  `:datetime` maps to `'date'` (TaskFormField has no `'datetime'` member --
 *  the closest existing builtin renders an `<input type="date">`, same
 *  degrade a form_schema field with no finer-grained widget would take).
 *  `:enum` maps to `'select'` (renders through FieldFactory's
 *  `fieldType === 'select' && fieldDef.enum` branch). `:localized_text` maps
 *  to `'object'` -- its wire value IS a `{"kk":...,"ru":...,"en":...}`
 *  object (REQ-301), rendered exclusively through the
 *  `ENTITY_LOCALIZED_TEXT_WIDGET` registry entry this function sets below,
 *  which the registry lookup in FieldFactory reaches before the builtin
 *  type-keyed switch ever inspects `type: 'object'`. `:json` remains out of
 *  scope (no entity field in the nine remaining BilimBaga types declares
 *  one) and degrades to `'string'` rather than throwing. */
function mapFieldType(type: EntityFieldDef['type']): TaskFormField['type'] {
  switch (type) {
    case 'string':
      return 'string'
    case 'integer':
    case 'decimal':
      return 'number'
    case 'boolean':
      return 'boolean'
    case 'date':
    case 'datetime':
      return 'date'
    case 'enum':
      return 'select'
    case 'localized_text':
      return 'object'
    case 'json':
    default:
      return 'string'
  }
}

/** `title` — `TaskFormField.title`/`FieldFactory`'s label text is required
 *  to come from a react-intl message catalog per this requirement's i18n
 *  rule, so this bridge deliberately leaves `title` undefined rather than
 *  humanising the field's raw `name` into an English label; the composing
 *  component supplies `title` itself, from `entitiesMessages`, after this
 *  mapping runs. */
export function entityFieldToFormField(
  field: EntityFieldDef,
  fkDef?: EntityFkDef,
  context?: { entityType?: string; editingRecordId?: string },
): TaskFormField {
  const base: TaskFormField = {
    name: field.name,
    type: mapFieldType(field.type),
    required: Boolean(field.required),
    enum: field.type === 'enum' ? field.enum_values : undefined,
  }

  // A `foreign_keys` match takes priority over the field's own `type`: a
  // fk-bearing field always renders as a reference lookup, regardless of
  // whether its underlying column type is `:string` (every fk field in the
  // nine remaining BilimBaga entity types) or otherwise.
  // REQ-586 part D: only category.parent_id gets the tree picker;
  // question.parent_id (and every other fk) stays a reference lookup.
  if (fkDef && context?.entityType === 'category' && field.name === 'parent_id') {
    return {
      ...base,
      xUiWidget: ENTITY_CATEGORY_TREE_WIDGET,
      referencesEntity: fkDef.references_entity,
      editingRecordId: context.editingRecordId,
    }
  }

  if (fkDef) {
    return { ...base, xUiWidget: ENTITY_FK_REFERENCE_WIDGET, referencesEntity: fkDef.references_entity }
  }

  if (field.type === 'localized_text') {
    return { ...base, xUiWidget: ENTITY_LOCALIZED_TEXT_WIDGET, locales: field.locales }
  }

  return base
}
