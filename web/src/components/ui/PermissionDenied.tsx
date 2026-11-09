import React from 'react'
import { Link } from 'react-router-dom'
import { useAccess } from '@/auth/access/useAccess'
import { useFeedbackMessages } from './feedbackMessages'

export function PermissionDenied(): React.ReactElement {
  const { isCandidate } = useAccess()
  const m = useFeedbackMessages()

  return (
    <div style={{ padding: '1.5rem' }} data-testid="permission-denied">
      <p style={{ marginBottom: '.75rem' }}>{m.permissionDenied}</p>
      {isCandidate ? <Link to="/exam">{m.goToExams}</Link> : <Link to="/tasks">{m.myTasks}</Link>}
    </div>
  )
}
