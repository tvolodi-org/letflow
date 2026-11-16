/** POST /api/v1/me/problem-reports (T-1948): a signed-in user reports a problem; the server adds the facts. */
import { client } from './client'
import type { ReportBody } from '@/lib/problemReport/payload'

export interface ProblemReportReceipt {
  id: string
  number: string
  received_at: string
}

/** One row of GET /api/v1/me/problem-reports (the caller's own reports, newest first, at most 50). */
export interface MyProblemReport {
  id: string
  number: string
  status: string
  question: boolean
  reply_text: string | null
  text: string
  received_at: string
  decided_at: string | null
}
export interface MyProblemReportList {
  reports: MyProblemReport[]
  has_more: boolean
}

export const problemReportsApi = {
  listMine: (): Promise<MyProblemReportList> => client.get<MyProblemReportList>('/api/v1/me/problem-reports'),
  submit: (body: ReportBody): Promise<ProblemReportReceipt> => client.post<ProblemReportReceipt>('/api/v1/me/problem-reports', body),
}
