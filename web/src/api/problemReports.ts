/** POST /api/v1/me/problem-reports (T-1948): a signed-in user reports a problem; the server adds the facts. */
import { client } from './client'
import type { ReportBody } from '@/lib/problemReport/payload'

export interface ProblemReportReceipt {
  id: string
  number: string
  received_at: string
}

export const problemReportsApi = {
  submit: (body: ReportBody): Promise<ProblemReportReceipt> => client.post<ProblemReportReceipt>('/api/v1/me/problem-reports', body),
}
