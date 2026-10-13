/** OnboardingProgressPage — ONB-UI-03
 *
 * Polls GET /api/v1/onboarding/:onboardingId at a fixed interval.
 * Uses a manual setInterval in useEffect (NOT TanStack Query refetchInterval)
 * so that the interval can be cleared and navigation triggered on success.
 *
 * The backend is synchronous (ISS-1030): a record that exists is final, there
 * is no pending/failed state. Any successful response is therefore terminal.
 * The register page no longer navigates here; this page only serves old
 * links (see the follow-up to remove it).
 *
 * Polling rules:
 * - Skip tick if document.hidden (Page Visibility API)
 * - successful response (the record): clearInterval, navigate to result screen
 * - 3 consecutive transient errors: clearInterval, show error banner + Retry button
 * - cleanup: clearInterval unconditionally on unmount
 */

import { useEffect, useRef, useState } from 'react'
import { Navigate, useNavigate, useParams, useLocation } from 'react-router-dom'
import { useAuth } from '@/auth/AuthContext'
import { Button } from '@/components/ui/Button'
import {
  getOnboarding,
  type OnboardingFormValues,
  type OnboardingRecord,
} from '@/api/onboarding'

const DEFAULT_POLL_MS = 10_000

export default function OnboardingProgressPage() {
  const { session } = useAuth()
  const { onboardingId } = useParams<{ onboardingId: string }>()
  const navigate = useNavigate()
  const location = useLocation()

  const locationState = location.state as {
    formValues?: OnboardingFormValues
    hostname?: string
  } | null

  const pollMs = Number(import.meta.env.VITE_POLL_INTERVAL_MS ?? DEFAULT_POLL_MS)

  const [errorBanner, setErrorBanner] = useState(false)
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const transientErrorCount = useRef(0)
  // Track latest navigate/state in refs to avoid stale closure
  const navigateRef = useRef(navigate)
  navigateRef.current = navigate
  const formValuesRef = useRef(locationState?.formValues)
  formValuesRef.current = locationState?.formValues
  const hostnameRef = useRef(locationState?.hostname ?? '')
  hostnameRef.current = locationState?.hostname ?? ''

  function startPolling() {
    if (!onboardingId) return

    function clearPoll() {
      if (intervalRef.current !== null) {
        clearInterval(intervalRef.current)
        intervalRef.current = null
      }
    }

    async function tick() {
      if (document.hidden) return

      try {
        const record: OnboardingRecord = await getOnboarding(onboardingId!)
        transientErrorCount.current = 0

        clearPoll()
        const hn = hostnameRef.current
        navigateRef.current(
          `/admin/onboarding/${onboardingId}/result${hn ? `?hostname=${encodeURIComponent(hn)}` : ''}`,
          {
            state: {
              record,
              formValues: formValuesRef.current,
            },
          },
        )
      } catch {
        transientErrorCount.current += 1
        if (transientErrorCount.current >= 3) {
          clearPoll()
          setErrorBanner(true)
        }
      }
    }

    setErrorBanner(false)
    transientErrorCount.current = 0
    intervalRef.current = setInterval(() => { void tick() }, pollMs)
  }

  useEffect(() => {
    startPolling()
    return () => {
      if (intervalRef.current !== null) {
        clearInterval(intervalRef.current)
        intervalRef.current = null
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [onboardingId])

  // Role guard — after all hooks
  if (!session?.roles.includes('PLATFORM_ADMIN')) {
    return <Navigate to="/instances" replace />
  }

  function handleRetry() {
    startPolling()
  }

  return (
    <div style={{ padding: '2rem', maxWidth: '520px' }}>
      <h2 style={{ margin: '0 0 1.5rem 0' }}>Onboarding in Progress</h2>

      {!errorBanner && (
        <>
          <div
            role="status"
            aria-label="Onboarding in progress"
            style={{ display: 'flex', alignItems: 'center', gap: '1rem', marginBottom: '1.5rem' }}
          >
            <Spinner />
            <span style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>
              Setting up tenant — this may take a moment…
            </span>
          </div>
          <p style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-xs)' }}>
            Onboarding ID: <code>{onboardingId}</code>
          </p>
        </>
      )}

      {errorBanner && (
        <div
          role="alert"
          style={{
            padding: '.85rem 1rem',
            borderRadius: 'var(--radius-sm)',
            border: '1px solid var(--color-error-border)',
            background: 'var(--color-error-tint)',
            color: 'var(--color-error-dark)',
            fontSize: 'var(--text-sm)',
            marginBottom: '1.25rem',
          }}
        >
          <p style={{ margin: '0 0 .75rem 0' }}>
            Unable to check onboarding status. The service may be temporarily unavailable.
          </p>
          <Button variant="primary" size="sm" onClick={handleRetry}>
            Retry
          </Button>
        </div>
      )}
    </div>
  )
}

function Spinner() {
  return (
    <svg
      width="24"
      height="24"
      viewBox="0 0 24 24"
      style={{ animation: 'spin 1s linear infinite' }}
      aria-hidden="true"
    >
      <style>{`@keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }`}</style>
      <circle
        cx="12"
        cy="12"
        r="10"
        fill="none"
        style={{ stroke: 'var(--border-default)' }}
        strokeWidth="3"
      />
      <path
        d="M12 2 A10 10 0 0 1 22 12"
        fill="none"
        style={{ stroke: 'var(--interactive-primary)' }}
        strokeWidth="3"
        strokeLinecap="round"
      />
    </svg>
  )
}
