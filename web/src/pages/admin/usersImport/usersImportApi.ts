/** usersImportApi -- T-1633 / REQ-791. The two calls of the users import screen; no tenant identifier is sent. */
import { client } from '@/api/client'
import { XLSX_CONTENT_TYPE, type ImportAnswer } from '../import/importModel'

const BASE = '/api/v1/identity/users/import'

export function downloadUsersTemplate(): Promise<{ blob: Blob; contentType: string }> {
  return client.getBlob(`${BASE}-template`)
}

/** A dry run sends `dry_run=true`; the real import is always atomic on the server, so it sends no flag. */
export function runUsersImport(file: Blob, dryRun: boolean): Promise<ImportAnswer> {
  return client.postRaw<ImportAnswer>(dryRun ? `${BASE}?dry_run=true` : BASE, file, XLSX_CONTENT_TYPE)
}
