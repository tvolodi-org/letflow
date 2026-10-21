import React from 'react'
import { Link } from 'react-router-dom'
import { useAccess } from '@/auth/access/useAccess'

export function PermissionDenied(): React.ReactElement {
  const { isCandidate } = useAccess()

  return (
    <div style={{ padding: '1.5rem' }}>
      <p style={{ marginBottom: '.75rem' }}>
        You do not have access to this area. Contact your tenant administrator.
      </p>
      {isCandidate ? <Link to="/exam">Go to Exams</Link> : <Link to="/tasks">My Tasks</Link>}
    </div>
  )
}
