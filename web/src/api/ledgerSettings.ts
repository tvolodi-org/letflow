/** REQ-839 — negative balance switch API client (`Letflow.Routers.LedgerSettings`, permission LedgerSettingsManage).
 *  GET /api/v1/ledger-settings lists every switchable ledger registration; PUT switches one. */
import { client } from './client'

/** One registration as returned by the server (`item/1` of the router). */
export interface LedgerSetting {
  /** The registration name (the module's name, for example `stock`). */
  registration: string
  /** False when no row exists: refuse is the default. */
  allow_negative: boolean
  changed_by: string | null
  /** Display name (else username) of `changed_by`; null when never changed or the user is gone. */
  changed_by_name: string | null
  changed_at: string | null
  reason: string | null
}

export interface LedgerSettingsReply {
  items: LedgerSetting[]
}

/** Body of the PUT: exactly these two keys; the reason is required in both directions. */
export interface LedgerSettingBody {
  allow_negative: boolean
  reason: string
}

export const ledgerSettingsApi = {
  list: () => client.get<LedgerSettingsReply>('/api/v1/ledger-settings'),
  put: (registration: string, body: LedgerSettingBody) =>
    client.put<LedgerSetting>(`/api/v1/ledger-settings/${encodeURIComponent(registration)}`, body),
}
