/** platformProblemReports -- T-2007: API client of the owner inbox screen for problem reports.
 *  Field names are copied from `summary/1` and `detail/1` in `lib/letflow/problem_reports/inbox.ex`; no renaming.
 *  Three routes (`:ProblemReportsManage`, platform tenant only, enforced by the server): list, get, decision.
 */
import { client } from './client'

export type InboxStatus = 'received' | 'in_work' | 'answered' | 'fixed' | 'not_done'
export type InboxFilter = 'open' | 'closed' | 'all'
export type DecisionAction = 'answer' | 'ask' | 'reject' | 'develop' | 'fixed'

export interface InboxSummary {
  id: string
  number: string
  class: string
  status: string
  last_action: string | null
  received_at: string | null
  decided_at: string | null
  reporter: { tenant_name: string | null; name: string | null }
  text_preview: string
}

export interface InboxList {
  reports: InboxSummary[]
  next_before: number | null
}

export interface InboxDetail {
  id: string
  number: string
  class: string
  status: string
  last_action: string | null
  received_at: string | null
  decided_at: string | null
  decided_by_user_id: string | null
  reporter: {
    tenant_id: string | null
    tenant_name: string | null
    user_id: string | null
    name: string | null
    roles: string[] | null
    permissions: string[] | null
  }
  text: string
  context: Record<string, unknown> | null
  server_version: string | null
  trace_id: string | null
  reply_text: string | null
  dev_summary: string | null
}

const BASE = '/api/v1/platform-problem-reports'

export const platformProblemReportsApi = {
  list: (params: { status: InboxFilter; before?: number | null }) => {
    const q = new URLSearchParams({ status: params.status })
    if (params.before != null) q.set('before', String(params.before))
    return client.get<InboxList>(`${BASE}?${q.toString()}`)
  },
  get: (id: string) => client.get<InboxDetail>(`${BASE}/${encodeURIComponent(id)}`),
  decide: (id: string, body: { action: DecisionAction; text?: string }) =>
    client.post<InboxDetail>(`${BASE}/${encodeURIComponent(id)}/decision`, body),
}
