/** SolutionPackUpdateLauncherPage — REQ-381 design §4.1
 *
 *  Route: `/solution-packs`. Since no "company's pack screen" exists yet
 *  (design §1/§2 OQ-2), this page IS the minimal form of that screen — not
 *  a full pack inventory, only the entry point REQ-381's own text requires.
 *
 *  Sources `incoming_artefacts`/`target_version` from an admin-pasted pack
 *  document (the same shape `POST /solution-packs/export` already produces
 *  and `POST /solution-packs/install` already consumes), and
 *  `theirs_artefacts` AUTOMATICALLY via `GET /definitions/:id` for every
 *  artefact id the pasted document names (design §2/§4.1) — the admin never
 *  types the tenant's own current content.
 */
import React, { useState } from 'react'
import { Navigate, useNavigate } from 'react-router-dom'
import { P, useAccess, AccessPending } from '@/auth/access'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { JsonEditor } from '@/components/ui/JsonEditor'
import { solutionPacksApi } from '@/api/solutionPacks'
import type { PackArtefactInput } from '@/api/solutionPacks'
import { canonicalizeArtefactContent } from '@/lib/canonicalizeArtefactContent'
import type { JsonValue } from '@/lib/canonicalizeArtefactContent'
import type { SolutionPackReviewLocationState } from './SolutionPackUpdateReviewPage'

interface PackedDefinition {
  definition_id: string
  process_key: string
  name?: string
  version: string
  graph: Record<string, JsonValue>
}

interface ParsedPackDocument {
  pack_id?: string
  version: string
  definitions: PackedDefinition[]
}

/** Client-side pre-check only (design §4.1) — the real `update-review` call
 *  still performs the same validation server-side; this is a fast-fail UX
 *  convenience, never a substitute. */
function parsePackDocument(raw: string): { ok: true; document: ParsedPackDocument } | { ok: false; error: string } {
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return { ok: false, error: 'Not valid JSON.' }
  }
  if (typeof parsed !== 'object' || parsed === null) {
    return { ok: false, error: 'Pack document must be a JSON object.' }
  }
  const obj = parsed as Record<string, unknown>
  if (typeof obj.version !== 'string' || obj.version === '') {
    return { ok: false, error: 'Pack document is missing "version".' }
  }
  if (!Array.isArray(obj.definitions)) {
    return { ok: false, error: 'Pack document is missing "definitions[]".' }
  }
  return {
    ok: true,
    document: {
      pack_id: typeof obj.pack_id === 'string' ? obj.pack_id : undefined,
      version: obj.version,
      definitions: obj.definitions as PackedDefinition[],
    },
  }
}

export default function SolutionPackUpdateLauncherPage(): React.ReactElement {
  const access = useAccess()
  const isAllowed = access.can(P.ModulesManage)
  const navigate = useNavigate()

  const [packId, setPackId] = useState('')
  const [documentText, setDocumentText] = useState('')
  const [documentValid, setDocumentValid] = useState(true)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return <Navigate to="/instances" replace />
  }

  const canSubmit = packId.trim() !== '' && documentText.trim() !== '' && documentValid && !submitting

  const handleSubmit = async (): Promise<void> => {
    setSubmitError(null)
    const parsed = parsePackDocument(documentText)
    if (!parsed.ok) {
      setSubmitError(parsed.error)
      return
    }

    setSubmitting(true)
    try {
      const incomingArtefacts: PackArtefactInput[] = parsed.document.definitions.map((def) => ({
        artefact_type: 'process_definition',
        artefact_id: def.definition_id,
        content: canonicalizeArtefactContent(def.graph),
      }))

      // §2: theirs_artefacts sourced automatically, one GET per artefact id
      // named by the incoming document — a 404 omits that artefact
      // entirely (compute_pack_update_plan/5 treats an absent theirs entry
      // as theirs: nil).
      const theirsResults = await Promise.all(
        parsed.document.definitions.map(async (def) => {
          const result = await solutionPacksApi.fetchTenantArtefactGraph(def.definition_id)
          if (!result) return null
          const artefact: PackArtefactInput = {
            artefact_type: 'process_definition',
            artefact_id: def.definition_id,
            content: canonicalizeArtefactContent(result.graph as Record<string, JsonValue>),
          }
          return artefact
        }),
      )
      const theirsArtefacts: PackArtefactInput[] = theirsResults.filter(
        (a): a is PackArtefactInput => a !== null,
      )

      const state: SolutionPackReviewLocationState = {
        targetVersion: parsed.document.version,
        theirsArtefacts,
        incomingArtefacts,
      }

      navigate(`/solution-packs/${encodeURIComponent(packId.trim())}/update-review`, { state })
    } catch (err) {
      setSubmitError(err instanceof Error ? err.message : 'Failed to prepare the update review.')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <PageLayout title="Solution pack update">
      <div style={{ display: 'flex', flexDirection: 'column', gap: '1.25rem', maxWidth: '720px' }}>
        <div>
          <label htmlFor="solution-pack-id-input" style={{ display: 'block', fontSize: '.85rem', marginBottom: '.25rem', color: 'var(--text-primary)' }}>
            Pack id
          </label>
          <input
            id="solution-pack-id-input"
            data-testid="solution-pack-id-input"
            type="text"
            value={packId}
            disabled={submitting}
            onChange={(e) => setPackId(e.target.value)}
            style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)' }}
          />
        </div>

        <JsonEditor
          label="Offered pack document"
          value={documentText}
          onChange={(value, isValid) => {
            setDocumentText(value)
            setDocumentValid(isValid)
          }}
          height={280}
        />

        {submitError && (
          <div data-testid="solution-pack-launcher-error" role="alert" style={{ padding: '.6rem .8rem', background: 'var(--color-error-light)', color: 'var(--color-error-dark)', borderRadius: '4px', fontSize: '.85rem' }}>
            {submitError}
          </div>
        )}

        <div>
          <Button
            variant="primary"
            size="md"
            data-testid="solution-pack-review-btn"
            disabled={!canSubmit}
            loading={submitting}
            onClick={() => { void handleSubmit() }}
          >
            Review update
          </Button>
        </div>
      </div>
    </PageLayout>
  )
}
