/** T-1989 — four-eyes switch API client (`Letflow.Routers.ApprovalRules`, permission ApprovalRulesManage).
 *  GET /api/v1/approval-rules lists every step that needs a second person; PUT switches one step. */
import { client } from './client'

/** One step as returned by the server (`item/1` of the router). */
export interface ApprovalRule {
  definition_name: string
  node_id: string
  /** Null for the shipped packs: their approve node has no label. */
  node_label: string | null
  four_eyes: boolean
  /** False for a stored setting whose step is no longer in an active process version. */
  in_active_definition: boolean
  changed_by: string | null
  /** Display name (else username) of `changed_by`; null when never changed or the user is gone. */
  changed_by_name: string | null
  changed_at: string | null
  reason: string | null
}

export interface ApprovalRulesReply {
  items: ApprovalRule[]
}

/** Body of the PUT: the reason is required in both directions. */
export interface ApprovalRuleBody {
  four_eyes: boolean
  reason: string
}

export const approvalRulesApi = {
  list: () => client.get<ApprovalRulesReply>('/api/v1/approval-rules'),
  /** Both path segments are encoded: a definition name may contain `/`. */
  put: (definitionName: string, nodeId: string, body: ApprovalRuleBody) =>
    client.put<ApprovalRule>(
      `/api/v1/approval-rules/${encodeURIComponent(definitionName)}/${encodeURIComponent(nodeId)}`,
      body,
    ),
}
