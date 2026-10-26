import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { client } from '@/api/client'

/** VerifyCertificatePage — public, unauthenticated certificate check at /verify/:handle.
 *  Reads GET /api/public/certificate/:handle (REQ-357, decision 0028) via client.getPublic:
 *  no Authorization header, no auth provider (the shared request() path would attach a token and its 401 handling
 *  triggers a login redirect). INV-5: every non-200 outcome renders one identical
 *  "not valid" result and no error-body content. */

interface CertificateProjection {
  candidate_name: string
  exam_title: string
  score_pct: number
  issued_on: string
  branding_snapshot?: { primary_color?: unknown } | null
}

type State = { kind: 'loading' } | { kind: 'valid'; cert: CertificateProjection } | { kind: 'invalid' }

function isProjection(v: unknown): v is CertificateProjection {
  if (typeof v !== 'object' || v === null) return false
  const o = v as Record<string, unknown>
  return (
    typeof o.candidate_name === 'string' &&
    typeof o.exam_title === 'string' &&
    typeof o.score_pct === 'number' &&
    typeof o.issued_on === 'string'
  )
}

/** Branding is for styling only; accept just a plain hex colour. */
function accentColor(cert: CertificateProjection): string | undefined {
  const c = cert.branding_snapshot?.primary_color
  return typeof c === 'string' && /^#[0-9a-fA-F]{3,8}$/.test(c) ? c : undefined
}

export default function VerifyCertificatePage() {
  const { handle = '' } = useParams<{ handle: string }>()
  const [state, setState] = useState<State>({ kind: 'loading' })

  useEffect(() => {
    let cancelled = false
    setState({ kind: 'loading' })
    const load = async () => {
      try {
        const res = await client.getPublic(`/api/public/certificate/${encodeURIComponent(handle)}`)
        if (res.status !== 200) return { kind: 'invalid' } as State
        const body = res.body
        return isProjection(body) ? ({ kind: 'valid', cert: body } as State) : ({ kind: 'invalid' } as State)
      } catch {
        return { kind: 'invalid' } as State
      }
    }
    void load().then(s => {
      if (!cancelled) setState(s)
    })
    return () => {
      cancelled = true
    }
  }, [handle])

  if (state.kind === 'loading') {
    return (
      <div data-testid="verify-loading" style={{ padding: '2rem', textAlign: 'center' }}>
        Checking certificate…
      </div>
    )
  }
  if (state.kind === 'invalid') {
    return (
      <div data-testid="verify-invalid" style={{ padding: '2rem', textAlign: 'center' }}>
        <h2>Certificate not valid</h2>
        <p>This certificate could not be verified.</p>
      </div>
    )
  }
  const { cert } = state
  return (
    <div
      data-testid="verify-valid"
      style={{ padding: '2rem', textAlign: 'center', borderTop: `4px solid ${accentColor(cert) ?? 'currentColor'}` }}
    >
      <h2>Certificate valid</h2>
      <dl>
        <dt>Candidate</dt>
        <dd data-testid="verify-candidate-name">{cert.candidate_name}</dd>
        <dt>Exam</dt>
        <dd data-testid="verify-exam-title">{cert.exam_title}</dd>
        <dt>Score</dt>
        <dd data-testid="verify-score">{cert.score_pct}%</dd>
        <dt>Issued on</dt>
        <dd data-testid="verify-issued-on">{cert.issued_on}</dd>
      </dl>
    </div>
  )
}
