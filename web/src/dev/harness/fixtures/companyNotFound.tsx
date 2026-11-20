/** Harness fixture of the "Company not found" page (T-2350). */
import { CompanyNotFound } from '@/auth/CompanyNotFound'
import type { HarnessScreen } from '../types'

export const companyNotFoundScreens: HarnessScreen[] = [
  { name: 'company-not-found', routes: [], render: () => <CompanyNotFound /> },
]
