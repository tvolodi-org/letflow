/** Value the server puts in `field_values` for a field the caller may not read
 *  (`Letflow.Entities.Query.FieldGrants.redact_field_values/2`: key retained, value is
 *  the atom `:__field_redacted__`, sent as this string). A cell holding it renders empty. */
export const FIELD_REDACTED = '__field_redacted__'

export function isRedacted(value: unknown): boolean {
  return value === FIELD_REDACTED
}
