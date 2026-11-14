import { useMutation } from '@tanstack/react-query'
import { problemReportsApi } from '@/api/problemReports'

export function useSubmitProblemReport() {
  return useMutation({ mutationFn: problemReportsApi.submit })
}
