/** Form rendering types for dynamic schema-driven forms (Stage F4) */

export interface TaskFormField {
  name: string
  type: 'string' | 'number' | 'boolean' | 'date' | 'select' | 'object' | 'array'
  title?: string
  description?: string
  required: boolean

  // Type-specific metadata
  enum?: string[] | number[]
  minLength?: number
  maxLength?: number
  pattern?: string
  minimum?: number
  maximum?: number
  multipleOf?: number
  format?: 'date' | 'date-time' | 'time' | 'email' | 'uri'

  // Nested structures
  properties?: Record<string, TaskFormField>
  items?: TaskFormField
  additionalProperties?: boolean

  // UI hints
  placeholder?: string
  widget?: 'textarea' | 'code-editor' | 'rich-text'

  /**
   * REQ-284 — the closed `x-ui.widget` vocabulary name (see
   * docs/frontend/x-ui-widget-vocabulary.md). Left as a bare `string` (not a
   * union of the five documented names) so an unrecognised tenant-supplied
   * value round-trips to FieldFactory instead of being coerced/dropped by a
   * type cast — that is what makes the degrade-to-builtin-type behaviour
   * (AC4) observable at all. `undefined` means "no override; render per
   * design-system.md §7.6."
   */
  xUiWidget?: string

  /**
   * REQ-284 — companion `x-ui.mask` value, consumed only by the
   * `masked-input` widget (one of `'phone-us' | 'postal-us' | 'currency-usd'`
   * per the vocabulary document). Left as a bare `string` for the same
   * round-tripping reason as `xUiWidget`; ignored by every other widget.
   */
  xUiMask?: string

  /** REQ-293 — x-ui.visible_when, the raw CEL-syntax condition string, or undefined. */
  visibleWhen?: string

  /** REQ-293 — x-ui.computed, the raw CEL-syntax expression string, or undefined. */
  computed?: string

  /** REQ-293 — x-ui.cross_field_validation, both sub-keys present together or
   * absent together (matches the server's own %{"expression"=>_, "message"=>_}
   * pairing — never one without the other). */
  crossFieldValidation?: { expression: string; message: string }

  /**
   * REQ-342 — the locale set an entity `:localized_text` field declares
   * (`Letflow.Entities.Definition`'s field_def `locales`, e.g.
   * `["kk","ru","en"]`). Consumed only by the `entity-localized-text`
   * registry widget; `undefined` for every other field type.
   */
  locales?: string[]

  /**
   * REQ-342 — set only when this field is one side of an
   * `EntityFkDef` (`definition.foreign_keys`): the entity type name the
   * field's value refers to (`references_entity`). Consumed only by the
   * `entity-fk-reference` registry widget, which resolves it against the
   * referenced entity's own active definition/records — this bridge does
   * not itself know what a human-readable label for that entity looks
   * like.
   */
  referencesEntity?: string

  /**
   * REQ-586 part D — set only when an existing record is being edited:
   * its own `record_id`. Consumed only by the `entity-category-tree`
   * widget, which leaves this record and its descendants out of the
   * parent choices.
   */
  editingRecordId?: string
}

export interface ValidationError {
  field: string // dot-path: "firstName", "address.street", "items.0.name"
  message: string
}

export interface DynamicFormValue {
  [key: string]: string | number | boolean | Date | DynamicFormValue | DynamicFormValue[] | null
}
