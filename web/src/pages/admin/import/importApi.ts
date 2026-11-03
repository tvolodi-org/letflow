/** importApi -- GH 3650 / REQ-675. The three calls of the import screen; no tenant identifier is sent. */
import { client } from '@/api/client'
import { XLSX_CONTENT_TYPE, type ImportAnswer } from './importModel'

const RECORDS = '/api/v1/entities/records'

/** Export route with two ANDed filters that match no record: the answer is the header row only. */
export function downloadTemplate(entityType: string): Promise<{ blob: Blob; contentType: string }> {
  return client.postBlob(`${RECORDS}/${encodeURIComponent(entityType)}/export?format=xlsx`, {
    entity_type: entityType,
    filters: [
      { field: 'external_ref_id', op: 'is_null' },
      { field: 'external_ref_id', op: 'is_not_null' },
    ],
  })
}

export function runImport(entityType: string, file: Blob, dryRun: boolean): Promise<ImportAnswer> {
  const query = dryRun ? 'upsert_by=external_ref&dry_run=true' : 'upsert_by=external_ref'
  return client.postRaw<ImportAnswer>(
    `${RECORDS}/${encodeURIComponent(entityType)}/import?${query}`,
    file,
    XLSX_CONTENT_TYPE,
  )
}
