-- GH #2683 / REQ-512: read-only report of authoring edits made while an exam had a live session.
--
-- Interim control until REQ-511 (exam authoring audit) and REQ-510 land. Generic record writes
-- leave an events row (actor, time, idempotency key, full field_values) and nothing else, so this
-- statement reads those events per tenant and lists the edits that touched an exam while a
-- candidate session on it was live.
--
-- An edit is LISTED in one of two sections:
--   live_session_edit  the edit is attributed to an exam, and at the edit a session for that
--                      exam was in_progress or grading_pending and had started (started_at at or
--                      before the edit time). An attributed edit to an idle exam is not listed.
--   unattributed       the edit cannot be tied to an exam: a pool type (question, answer_option,
--                      question_tag, tag, category), or no earlier event gives the record's exam
--                      key (exam_section, exam_question_rule, exam_manual_question,
--                      exam_question_rule_tag). The exam_id is NULL in this section.
--
-- Attribution (as of the edit, by events global_seq):
--   exam                              exam id = record id
--   exam_section, exam_question_rule  exam id = field exam_id of the record's CREATED/UPDATED event
--   exam_manual_question,
--   exam_question_rule_tag            rule id = field rule_id; exam id = the exam_id the rule had
--                                     at the edit (its latest CREATED/UPDATED before the edit)
--   DELETED events carry no field values, so their key is the latest earlier CREATED/UPDATED of the
--   same record (its field values). No earlier event: unattributed.
--
-- Session rule: the session's latest session event before the edit must not be a delete, must name
-- the exam, must have status in_progress or grading_pending, and must have started_at at or before
-- the edit time. expires_at is not part of the rule: an in_progress session past its expiry still
-- counts until it is finalized (submitted or auto_submitted). A session whose events all come after
-- the edit is not live.
--
-- Output: one row per listed edit, ordered by tenant, time and event order. Columns:
--   tenant_id, section, exam_id, entity_type, record_id, actor_id, occurred_at, event_type
-- Ids, type names and times only. No field value, payload, idempotency key, session status or
-- user id is output.
--
-- Known limits (an interim control, not a complete audit):
--   * Reads only the live events table. events_archive is not read: an edit or session event moved
--     by retention is not seen, and a delete whose earlier CREATED/UPDATED event was archived is
--     reported as unattributed.
--   * Scans every tenant's events filtered by entity type, and the session check reads each
--     session's earlier events for each attributed edit. No QA timing has been measured: run it on
--     QA before using it at scale.
--   * occurred_at is the transaction start time (events.created_at). Order inside one transaction
--     uses global_seq, which is assigned at insert.
--   * A session record deleted and re-created under the same id is judged by its latest event.
--
-- Read-only by construction: one SELECT, no DDL, no DML, no function, temp table or view.
-- Schema names come from public.tenant_schemas.schema_name and are quoted with %I (never input).
-- Each tenant's rows come from query_to_xml over an inner query; the inner query must not contain
-- a % character other than its format placeholders.
--
-- Syntax checked by the ExUnit test test/letflow/modules/exam/exam_edit_live_session_report_test.exs,
-- which runs this file against fixture tenants. Run against a QA database with:
--   psql "$DATABASE_URL" -f docs/runbooks/gh2683-exam-edit-live-session-report.sql

SELECT
  (xpath('/row/tenant_id/text()', r.node))[1]::text AS tenant_id,
  (xpath('/row/section/text()', r.node))[1]::text AS section,
  (xpath('/row/exam_id/text()', r.node))[1]::text AS exam_id,
  (xpath('/row/entity_type/text()', r.node))[1]::text AS entity_type,
  (xpath('/row/record_id/text()', r.node))[1]::text AS record_id,
  (xpath('/row/actor_id/text()', r.node))[1]::text AS actor_id,
  ((xpath('/row/occurred_at/text()', r.node))[1]::text::timestamp AT TIME ZONE 'UTC') AS occurred_at,
  (xpath('/row/event_type/text()', r.node))[1]::text AS event_type
FROM (
  SELECT
    ts.tenant_id,
    query_to_xml(format($q$
WITH ev AS (
  SELECT e.global_seq, e.created_at, e.event_type, e.actor_id,
         COALESCE(sp.payload, e.payload) AS body
  FROM %1$I.events e
  LEFT JOIN %1$I.event_payload_store sp
    ON sp.event_id = e.event_id AND sp.event_created_at = e.created_at
  WHERE e.event_type IN ('ENTITY_RECORD_CREATED', 'ENTITY_RECORD_UPDATED', 'ENTITY_RECORD_DELETED')
), rec AS (
  SELECT ev.global_seq, ev.created_at, ev.event_type, ev.actor_id,
         ev.body->>'entity_type' AS entity_type,
         ev.body->>'record_id' AS record_id,
         ev.body->'field_values' AS fv
  FROM ev
  WHERE ev.body->>'entity_type' IN ('exam', 'exam_section', 'exam_question_rule',
    'exam_manual_question', 'exam_question_rule_tag', 'question', 'answer_option',
    'question_tag', 'tag', 'category', 'session')
), edit AS (
  SELECT r.global_seq, r.created_at, r.event_type, r.actor_id, r.entity_type, r.record_id,
         CASE WHEN r.event_type = 'ENTITY_RECORD_DELETED' THEN (
           SELECT c.fv FROM rec c
           WHERE c.entity_type = r.entity_type AND c.record_id = r.record_id
             AND c.event_type <> 'ENTITY_RECORD_DELETED' AND c.global_seq < r.global_seq
           ORDER BY c.global_seq DESC LIMIT 1
         ) ELSE r.fv END AS carrier_fv
  FROM rec r
  WHERE r.entity_type IN ('exam', 'exam_section', 'exam_question_rule',
    'exam_manual_question', 'exam_question_rule_tag', 'question', 'answer_option',
    'question_tag', 'tag', 'category')
), attr AS (
  SELECT ed.*,
    CASE
      WHEN ed.entity_type = 'exam' THEN ed.record_id
      WHEN ed.entity_type IN ('exam_section', 'exam_question_rule') THEN ed.carrier_fv->>'exam_id'
      WHEN ed.entity_type IN ('exam_manual_question', 'exam_question_rule_tag') THEN (
        SELECT rr.fv->>'exam_id' FROM rec rr
        WHERE rr.entity_type = 'exam_question_rule' AND rr.record_id = ed.carrier_fv->>'rule_id'
          AND rr.event_type <> 'ENTITY_RECORD_DELETED' AND rr.global_seq < ed.global_seq
        ORDER BY rr.global_seq DESC LIMIT 1
      )
    END AS exam_id
  FROM edit ed
), flagged AS (
  SELECT a.*,
    CASE
      WHEN a.exam_id IS NULL THEN 'unattributed'
      WHEN EXISTS (
        SELECT 1 FROM (
          SELECT DISTINCT ON (s.record_id) s.record_id, s.event_type, s.fv
          FROM rec s
          WHERE s.entity_type = 'session' AND s.global_seq < a.global_seq
          ORDER BY s.record_id, s.global_seq DESC
        ) last
        WHERE last.event_type <> 'ENTITY_RECORD_DELETED'
          AND last.fv->>'exam_id' = a.exam_id
          AND last.fv->>'status' IN ('in_progress', 'grading_pending')
          AND CASE WHEN last.fv->>'started_at' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
                   THEN (last.fv->>'started_at')::timestamptz <= (a.created_at AT TIME ZONE 'UTC')
              END
      ) THEN 'live_session_edit'
    END AS section
  FROM attr a
)
SELECT
  %2$L::text AS tenant_id,
  f.section,
  f.exam_id,
  f.entity_type,
  f.record_id,
  f.actor_id::text AS actor_id,
  f.created_at::text AS occurred_at,
  f.event_type,
  f.global_seq::text AS global_seq
FROM flagged f
WHERE f.section IS NOT NULL
$q$, ts.schema_name, ts.tenant_id), false, false, '') AS doc
  FROM public.tenant_schemas ts
  WHERE ts.migrations_applied_at IS NOT NULL
    AND to_regclass(format('%I.events', ts.schema_name)) IS NOT NULL
) t
CROSS JOIN LATERAL unnest(xpath('/table/row', t.doc)) AS r(node)
ORDER BY tenant_id, occurred_at, (xpath('/row/global_seq/text()', r.node))[1]::text::bigint;
