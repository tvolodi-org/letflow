/** linkedEmployee — T-1528. The employee (org_employee) linked to a user account, found in a picker's options.
 *  Pure: used by document forms to propose the signed-in user as the material responsible. Never throws. */
export interface EmployeeOption {
  value: string
  fields?: Record<string, unknown>
}

/** The `value` of the first option whose `user_id` equals `userId` (case-insensitive); null when none or no user. */
export function linkedEmployeeId(userId: string | null | undefined, employees: readonly EmployeeOption[]): string | null {
  if (typeof userId !== 'string' || userId === '') return null
  const wanted = userId.toLowerCase()
  for (const e of employees) {
    const u = e.fields?.['user_id']
    if (typeof u === 'string' && u !== '' && u.toLowerCase() === wanted) return e.value
  }
  return null
}
