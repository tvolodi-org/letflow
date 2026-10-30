/** entities API client — REQ-336
 *
 *  Follows web/src/api/definitions.ts's own shape exactly: a plain object of
 *  named functions wrapping client.get/post/put/delete, typed against
 *  web/src/types/api.ts. Not a new client abstraction.
 *
 *  ⛔ THE REAL ROUTE TABLE (lib/letflow/routers/entities.ex), READ IN FULL
 *  BEFORE CHANGING THIS FILE. There is NO `GET /entities/records/:entity_type`
 *  list route and NO `GET /entities/records/:entity_type/:record_id` single-
 *  record route -- that router's own moduledoc states it explicitly ("No
 *  route reads a record by id, and none lists records"):
 *  `Letflow.Entities.Records` is command-only (create/update/delete), and the
 *  only read path for a record, single or many, is `POST /entities/query`
 *  (Letflow.Entities.Query.Compiler, cursor-paginated via
 *  Letflow.Entities.Query.Cursor). "Get one record to populate an edit form"
 *  is the SAME route as "list records", filtered to one `record_id` -- there
 *  is no cheaper way to fetch a single record today. Do NOT add a
 *  `getRecord`/`listRecords` function here: no such route exists, and a
 *  client that called one would fail at request time, not at build/lint
 *  time, which is exactly the trap this file exists to avoid.
 *
 *  Definition metadata (field list, types, required-ness, enum_values) comes
 *  from `GET /entities/definitions/active/:name` -- `getActiveDefinition`.
 *  Create is `POST /entities/records/:entity_type`, update
 *  `PUT /entities/records/:entity_type/:record_id`, delete
 *  `DELETE /entities/records/:entity_type/:record_id`.
 *
 *  update_record's route table row lists 409 as a real response
 *  (optimistic-concurrency conflict) -- the identical X-Resource-Version
 *  shape client.ts's request() already special-cases for PD-08. This module
 *  adds no new conflict-detection mechanism: `updateRecord`'s `ifMatch`
 *  parameter is threaded through as the `If-Match` header on the PUT call,
 *  and a 409 response propagates as the same `ApiError` (with
 *  `details.xResourceVersion`) client.ts's `request()` already builds --
 *  callers (the edit form) catch it and read `details.xResourceVersion`
 *  exactly as PD-08's existing ConflictResolver does elsewhere.
 */

import { client } from './client'
import type {
  EntityAggregateRequest,
  EntityAggregateResponse,
  EntityDefinition,
  EntityQueryRequest,
  EntityRecord,
  EntityRecordsPage,
} from '@/types/api'

export const entitiesApi = {
  /** `GET /entities/definitions/active/:name` — the only definition-fetch
   *  this pilot needs (an active definition drives both the list columns and
   *  the create/edit form). */
  getActiveDefinition: (entityType: string) =>
    client.get<EntityDefinition>(`/api/v1/entities/definitions/active/${encodeURIComponent(entityType)}`),

  /** `POST /entities/query` — the ONLY record-read route. Used for both
   *  "list records" (no filter) and "fetch one record for editing" (a
   *  filter selecting that one record_id) — see this file's moduledoc-style
   *  comment above. */
  queryRecords: (entityType: string, query: Omit<EntityQueryRequest, 'entity_type'> = {}) =>
    client.post<EntityRecordsPage>('/api/v1/entities/query', { entity_type: entityType, ...query }),

  /** `POST /entities/query/aggregate` (REQ-634): grouped aggregates over the same filters. */
  aggregateRecords: (entityType: string, body: Omit<EntityAggregateRequest, 'entity_type'>) =>
    client.post<EntityAggregateResponse>('/api/v1/entities/query/aggregate', { entity_type: entityType, ...body }),

  /** `POST /entities/records/:entity_type`. */
  createRecord: (entityType: string, fieldValues: Record<string, unknown>) =>
    client.post<EntityRecord>(`/api/v1/entities/records/${encodeURIComponent(entityType)}`, {
      field_values: fieldValues,
    }),

  /** `PUT /entities/records/:entity_type/:record_id`. `ifMatch`, when
   *  supplied, is sent as the `If-Match` header carrying the record's last-
   *  known `entity_def_version`/resource version stamp — the same value a
   *  prior read or a 409's `X-Resource-Version` supplied. Whole-document
   *  replacement semantics (the route's own): send the FULL field_values
   *  map, not a partial patch. */
  updateRecord: (
    entityType: string,
    recordId: string,
    fieldValues: Record<string, unknown>,
    ifMatch?: string,
  ) =>
    client.putWithHeaders<EntityRecord>(
      `/api/v1/entities/records/${encodeURIComponent(entityType)}/${encodeURIComponent(recordId)}`,
      { field_values: fieldValues },
      ifMatch ? { 'If-Match': ifMatch } : {},
    ),

  /** `DELETE /entities/records/:entity_type/:record_id`. Bodyless, per the
   *  route table. */
  deleteRecord: (entityType: string, recordId: string) =>
    client.delete<EntityRecord>(
      `/api/v1/entities/records/${encodeURIComponent(entityType)}/${encodeURIComponent(recordId)}`,
    ),
}
