/**
 * ISS-0655 regression test.
 *
 * REQ-326 authored ten entity definitions under
 * priv/packs/bilimbaga/entity_definitions/, but
 * BILIMBAGA_ENTITY_TYPES (this config's admin-screen wiring list) once
 * carried only nine -- `tag` was silently dropped when REQ-343 generalized
 * REQ-336's `TagListPage.tsx` pilot into the entity-agnostic
 * `EntityCrudPage`, leaving `/admin/bilimbaga/tag` 404ing with no admin
 * screen despite `tag` being a real, write-accepting pack entity type.
 *
 * This test reads the real pack directory on disk (not a hard-coded
 * mirror of it) and asserts every ADMIN-MANAGEABLE entity type there has a
 * corresponding BILIMBAGA_ENTITY_TYPES entry, so the two lists cannot
 * silently diverge again. "Admin-manageable" excludes pack entity types that
 * have no admin-authoring path, for either of two distinct reasons: (a)
 * runtime-state types (session and its four session_* satellites), written
 * by the exam-session engine at runtime, not authored through an admin CRUD
 * screen -- there is deliberately no admin screen for any of them; and (b)
 * other pack entity types that are declarative, system-written records with
 * no admin-authoring path by their own requirement's explicit scope
 * decision rather than by architectural necessity -- currently just
 * `certificate` (REQ-355): per certificate.json's own description this is a
 * "declarative record shape with no execution semantics of its own," issued
 * by `Letflow.Exam.Certificate`'s idempotent issue-on-first-request logic
 * triggered by a candidate's own action (not the session engine), and
 * lib/letflow/exam/certificate.ex's moduledoc states plainly that an admin
 * bypass/route "is future work for whichever requirement" picks it up --
 * i.e. deferred, not ruled out. Neither type family is expected to appear
 * in BILIMBAGA_ENTITY_TYPES.
 */
import { describe, it, expect } from 'vitest'
import { readdirSync } from 'node:fs'
import path from 'node:path'
import { BILIMBAGA_ENTITY_TYPES, isBilimBagaEntityType } from '@/config/bilimbagaEntities'

// web/src/config/__tests__ -> web/src/config -> web/src -> web -> repo root
const PACK_DIR = path.resolve(__dirname, '../../../../priv/modules/exam/entity_definitions')

// Entity types with no admin-authoring path, for two distinct reasons:
// (a) runtime-state types written by lib/letflow/exam/session.ex's engine as
// a session progresses (session and its four session_* satellites); and
// (b) certificate (REQ-355) -- a declarative, system-written record (see
// certificate.json's description) issued by lib/letflow/exam/certificate.ex
// on a candidate's own request, not the session engine, but with its own
// admin-authoring route deliberately deferred rather than architecturally
// impossible (see that module's moduledoc, guard-order note 1). Both
// families are deliberately excluded from admin-manageable coverage.
const NO_ADMIN_AUTHORING_ENTITY_TYPES = new Set([
  'session',
  'session_answer',
  'session_event',
  'session_question',
  'session_question_score',
  'certificate',
  // (c) exam_assignment (REQ-582 part A): definition and managed type only;
  // its admin screen arrives with a later part of that requirement.
  'exam_assignment',
])

function realPackEntityTypes(): string[] {
  return readdirSync(PACK_DIR)
    .filter((f) => f.endsWith('.json'))
    .map((f) => f.replace(/\.json$/, ''))
}

describe('ISS-0655 — BILIMBAGA_ENTITY_TYPES covers every admin-manageable pack entity type', () => {
  it('the pack directory has not silently changed shape (sanity check on this test itself)', () => {
    const allTypes = realPackEntityTypes()
    expect(allTypes.length).toBeGreaterThanOrEqual(10)
    // Every runtime-state type this test excludes must actually exist in
    // the pack, so NO_ADMIN_AUTHORING_ENTITY_TYPES stays honest if the pack's
    // shape changes.
    for (const excludedType of NO_ADMIN_AUTHORING_ENTITY_TYPES) {
      expect(allTypes).toContain(excludedType)
    }
  })

  it('every admin-manageable pack entity type has a BILIMBAGA_ENTITY_TYPES entry', () => {
    const adminManageableTypes = realPackEntityTypes().filter(
      (t) => !NO_ADMIN_AUTHORING_ENTITY_TYPES.has(t),
    )
    const wiredTypes = new Set(BILIMBAGA_ENTITY_TYPES.map((e) => e.entityType))

    const missing = adminManageableTypes.filter((t) => !wiredTypes.has(t))
    expect(missing).toEqual([])
  })

  it('BILIMBAGA_ENTITY_TYPES declares no runtime-state type and no type absent from the pack', () => {
    const realTypes = new Set(realPackEntityTypes())
    for (const { entityType } of BILIMBAGA_ENTITY_TYPES) {
      expect(NO_ADMIN_AUTHORING_ENTITY_TYPES.has(entityType)).toBe(false)
      expect(realTypes.has(entityType)).toBe(true)
    }
  })

  it('isBilimBagaEntityType recognizes tag (regression for ISS-0655)', () => {
    expect(isBilimBagaEntityType('tag')).toBe(true)
  })
})
