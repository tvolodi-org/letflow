import { client } from './client'

/** REQ-553 -- reply of GET /api/v1/labels (REQ-551): the tenant's override or
 *  the platform default for every overridable "entities." id. */
export interface LabelsReply {
  locale: string
  messages: Record<string, string>
}

export const labelsApi = {
  getMerged: (locale: string) => client.get<LabelsReply>('/api/v1/labels', { locale }),
}
