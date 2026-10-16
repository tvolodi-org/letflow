defmodule Letflow.Routers.Instances do
  @moduledoc """
  Process-instance sub-router, mounted at `/instances` by
  `Letflow.Plugs.ApiPipeline`.

  REQ-078 added the explicit pin-rebind endpoint (PIN-05). REQ-079 adds the
  three write routes below (create/cancel/reconstruct). REQ-080 (read routes,
  `GET`) still co-owns this file; REQ-079 does not touch the `match _`
  catch-all and modifies no existing route.

  | Handler     | Method/path                        | Delegate                                                              | Permission | Response |
  |-------------|-------------------------------------|-------------------------------------------------------------------------|------------|----------|
  | rebind      | `POST /instances/:id/rebind-pins`  | `Letflow.Engine.PinRebind.rebind_pins/3`                                | none in REQ-078 (REQ-131) | 200, `{instance_id, changes, rebound_at}`; 422 `max_length` if the `idempotency-key` header is over 162 bytes, 422 `format` if it is not valid UTF-8 or contains NUL (GH #2550) |
  | create      | `POST /instances`                  | `Letflow.Engine.create/2`                                               | `InstancesStart` | 201, `{instance_id, status, created_at}`; 422 `max_length` if the `idempotency-key` header is over 199 bytes, 422 `format` if it is not valid UTF-8 or contains NUL (GH #2550) |
  | cancel      | `POST /instances/:id/cancel`       | `Letflow.Engine.cancel_instance/3`                                      | `InstancesCancel` | 200, `{instance_id, status}`; 409 if already `COMPLETED` or already `CANCELLED`; 422 `max_length` if the `idempotency-key` header is over 162 bytes, 422 `format` if it is not valid UTF-8 or contains NUL (GH #2550) |
  | reconstruct | `POST /instances/:id/reconstruct`  | `Letflow.Engine.Reconstruction.reconstruct_instance/2` (`write_back: true`, not caller-controllable) | none (REQ-079 — same precedent as rebind, a future policy decision) | 200, `{instance_id, status, tokens: [{node_id, branch_id}], variables}` |
  | advance-timer | `POST /instances/:id/advance-timer` | `Letflow.Scheduler.resolve_advance_target/3` (new) then `Letflow.Scheduler.fire_timer/2` (existing, unchanged) | `InstancesAdvanceTimer` (ISS-0389 — a real permission, fully wired, not the rebind-pins/reconstruct ad-hoc pattern) | 200, `{instance_id, timer_id, node_id, timer_status}`; 400 ambiguous pending timers (`code: ambiguous_pending_timers`); 404 no matching pending timer |

  ## Route ordering — `rebind-pins`/`cancel`/`reconstruct` MUST precede any future `POST /instances/:id`

  PROVENANCE (historical, not current decision authority):
  `Plug.Router` matches in
  declaration order, so a `post "/:id"` declared **above** these three would
  swallow all of them (`src/main.zig:848` documents the same ordering
  constraint: "must precede plain /:id"). `/:id/cancel` and `/:id/reconstruct` are literal path
  suffixes distinct from `/:id/rebind-pins` and from each other, so they do
  not compete with one another regardless of relative order — but no bare
  `POST "/:id"` may be declared above any of the three. **REQ-080: `GET` and
  `POST` are independent dispatch tables in `Plug.Router`, so this constraint
  does not extend to REQ-080's read routes.**

  ## `POST /instances` — definition_id vs definition_name

  `definition_id`/`definition_name` mutual exclusivity is enforced by
  `Letflow.Engine.create/2` itself (`:missing_definition_reference` /
  `:both_definition_id_and_name`), not by `@create_schema` —
  `Letflow.Api.Validation.FieldConstraint` has no cross-field vocabulary, the
  same reasoning `normalise_entries/1` below already gives for per-element
  checks it can't express. `definition_name` is a Letflow addition over R-Co
  (REQ-045) exposed here because `Letflow.Engine.create/2` already accepts
  it — restricting this route to `definition_id` only would regress an
  already-shipped capability. `create_attrs/2` drops a `nil`-valued
  `definition_id`/`definition_name`/`correlation_key` rather than passing an
  explicit-`null` key through, so an explicit JSON `null` and an absent key
  are indistinguishable to `Engine.create/2`'s own XOR check either way.

  ## Cancelling a terminal instance is 409, not 404 or 500

  Both already-`COMPLETED` and already-`CANCELLED` map to 409, with a
  per-status detail string (AC6) — a considered choice, not an inconsistency
  with `render_rebind/2`'s constant-detail precedent (that precedent is about
  not leaking *internal* detail, not about collapsing two equally-valid
  terminal states into one message). An `:error`-status instance is **not**
  terminal (`Letflow.EventStore.InstanceProjection.terminal?/1` only returns
  `true` for `:completed`/`:cancelled`) — cancelling one succeeds (200), same
  as an `:active` instance.

  ## Reconstruct always write-backs, and has no route-local permission check

  PROVENANCE (historical, not current decision authority):
  `write_back: true` is hardcoded, not a request option — there is no
  caller-facing flag to make it optional. No `endpoint_policy_key/2` clause
  exists for this route (R-Co's `authorization.zig` has no entry for it
  either, confirmed by grep, zero hits) — same precedent as rebind-pins: authenticated +
  tenant-scoped only, not permission-gated. A future permission requirement
  is a REQ-131-class policy decision, not this requirement's to invent.

  ## No separate `Letflow.Routers.PinRebind`

  `Plug.Router.forward/2` is prefix-exclusive, so a separate sub-router could
  not be mounted at `/instances`; giving pin rebind its own sub-router would
  have forced an invented URL. It is an instances route and it lives on the
  instances router.

  ## Idempotency-key convention — the FIRST in this codebase (REQ-079/080 must adopt it)

  PROVENANCE (historical, not current decision authority):
  `Letflow.Engine.PinRebind.rebind_attrs()` **requires** `:idempotency_key`.
  R-Co's request body has none (`pin_rebind.zig:26-30`), so the route must
  source one, and no other Letflow router reads an idempotency header —
  `grep -rn "Idempotency-Key\|idempotency_key" lib/letflow/api/ lib/letflow/routers/`
  returned zero hits before REQ-078.

  **The convention: read the `idempotency-key` request header through
  `Letflow.Idempotency.from_header/4`; if present and non-empty, refuse it with
  a 422 `format` if it is not valid UTF-8 or contains a NUL byte (checked first,
  before any database access), a 422 `max_length` over 199 bytes (162 on
  cancel/rebind), otherwise store it namespaced by route, actor and, for
  cancel/rebind, instance (GH #2550); if absent or empty, generate
  `Ecto.UUID.generate/0`.** A key is never truncated.

  This is the first HTTP-layer idempotency convention in this codebase.
  **REQ-079 and REQ-080 must adopt this same convention rather than inventing
  a second one.** If a different shape is wanted, change it here and change
  every adopter in the same commit — two disagreeing conventions for the same
  header is the failure mode this sentence exists to prevent.

  ## INV-5 — cross-tenant is 404, and it is the same 404

  An instance belonging to another tenant is invisible in the caller's
  prefix-scoped schema, so `rebind_pins/3` returns
  `{:error, :instance_not_found}` — the **same call, same code path and same
  response bytes** as a genuinely absent instance.
  `Letflow.Api.Response.not_found/1` takes no detail, so there is no slot
  through which the two could differ. No handler may add a cross-tenant
  existence check to produce a nicer message.

  ## Response shape

  `changes` maps `rebind_result().changed` element-wise into hand-built
  four-key maps (INV-2), with `kind` rendered via `Atom.to_string/1`.
  `rebound_at` has **no R-Co counterpart** — it is a Letflow addition, carried
  because `rebind_result()` already returns it and it is useful to a caller
  correlating the rebind with the `INSTANCE_PINS_REBOUND` event.

  The request's `kind` values are passed through as **raw strings**;
  `rebind_attrs()` explicitly permits `String.t()`, so no atom conversion
  happens in this route and therefore no attacker-controlled atom is ever
  created.

  ## Deliberate non-port

  **503 `PoolExhausted`** — Ecto/DBConnection surfaces pool exhaustion as a
  raised `DBConnection.ConnectionError`, not an error tuple, so a 503 clause
  would be a branch nothing can reach.

  ## Authorization gap — REQ-131 closes it

  PROVENANCE (historical, not current decision authority):
  This route does not call `Letflow.Api.Authorization.evaluate_access/2`.
  `endpoint_policy_key/2` has no clause for
  `POST /instances/:id/rebind-pins` — there is no existing policy clause to
  extend (R-Co's `authorization.zig` has no entry for it either), and
  deciding what permission a pin rebind requires is a policy
  question belonging to
  **REQ-130/REQ-131**. Inventing a route-local permission check here was
  explicitly ruled out. The route was originally authenticated and
  tenant-scoped only; it is now gated by the `:InstancesCancel` permission via
  `authz_post` (see the route definition).

  ## Ordering guarantee

  Honours the contract stated in `Letflow.Routers.Tenants`'s moduledoc section
  **"Ordering guarantee (design §6.1)"**: no `Repo` call of any kind happens
  before the scoped prefix has been resolved. Structural here — **this module
  performs no `Repo` call at all**; every read, lock and append is inside
  `Letflow.Engine.PinRebind.rebind_pins/3`, whose `opts` argument *is* the
  prefix.

  ## REQ-212 — instance-attachment routes

  Design: `lib/letflow/design/req212-instance-attachments-routes.md`. Four
  routes atop REQ-211's shipped `Letflow.Repository.Attachments` context
  module: `POST`/`GET /instances/:id/attachments` and
  `GET`/`DELETE /instances/:id/attachments/:attachment_id`.

  **No existing `web/` SPA consumer and no R-Co route contract exist for this
  surface** — this requirement DEFINES the response shapes below rather than
  matching an existing one, the same way REQ-176/181's core modules became
  REQ-178/182's routes' binding contract.

  **Content-vs-metadata distinction (AC8) — the two `GET` routes return
  fundamentally different bodies:**

    * `GET /instances/:id/attachments` returns **JSON metadata** —
      `{"items": [...], "next_cursor": ...}`, each item shaped like the
      `POST` response below.
    * `GET /instances/:id/attachments/:attachment_id` returns the **raw
      uploaded file bytes**, byte-for-byte, as the response body — never a
      JSON document under any 2xx status. `Content-Type` is the attachment's
      stored `content_type`; `Content-Disposition` carries the stored
      `file_name`.

  A caller wanting one attachment's metadata as JSON uses the list route
  (client-side filtering by id) or already has it from the upload response —
  `Letflow.Repository.Attachments.get/2` (REQ-211) is metadata-only by
  design and has no single-item route of its own here.

  `content_hash` is **never** surfaced in any response body, JSON or
  otherwise — no acceptance criterion or known future consumer needs it, and
  omitting it entirely is safer than risking it being misused as an opaque
  download token.

  ### Response shapes (binding, design §3)

  `POST .../attachments` (201) and each item of `GET .../attachments`
  (200, inside `"items"`) share one shape — see `attachment_json/1`:

  ```json
  {
    "id": "...", "instance_id": "...", "file_name": "...",
    "content_type": "...", "byte_size": 123, "uploaded_by": "...",
    "description": "...", "created_at": "..."
  }
  ```

  `DELETE .../attachments/:attachment_id` returns 204 No Content — this
  codebase's first hard-delete route; 204 (not 200-with-body, unlike
  `Letflow.Routers.Dlq`'s retry/discard, which return a genuinely *changed*
  resource) because a delete has no new state to show, matching
  `Letflow.Api.Response.no_content/1`'s own precedent. A considered
  divergence from DLQ's own 200 convention, flagged for REVIEWER.

  ### Multipart upload mechanism (design §2) — two-ceiling synchronization hazard

  `Letflow.Plugs.ApiPipeline`'s shared `Plug.Parsers` declaration was
  extended (`parsers: [:json, {:multipart, length: 26_214_400}]`) rather
  than raising its shared root `length:` — the `:multipart` parser gets its
  own 25 MiB per-parser override (`Plug.Parsers.init/1`'s documented
  `{parser, opts}` tuple form merges `opts` over the root, per-parser
  winning), so every OTHER JSON route on every OTHER sub-router keeps its
  existing 2 MB ceiling unchanged. **This 25 MiB value
  (`26_214_400`) MUST stay numerically identical to
  `Letflow.Repository.Attachments.@max_upload_bytes`** — REQ-211's own
  upload-size ceiling and the authoritative check; `Plug.Parsers`'s ceiling
  is a stronger, earlier DoS defense (rejects an oversized multipart body
  before it is fully buffered) layered on top of, not instead of, `upload/2`'s
  own check. Both numbers must change together — flagged for REVIEWER.

  The upload route reads a required `file` multipart part
  (`%Plug.Upload{}` — `path`/`filename`/`content_type`) and an optional
  `description` text part. `content_type` is sourced from the multipart
  part's own declared `Content-Type`, never re-derived or sniffed (REQ-211's
  own INV-a: `content_type` is caller-supplied metadata, never a validated
  fact).

  ### Two distinct 404 checks (design §5.1, AC5/AC6, INV-5)

  Every one of the four routes relies on **(a) cross-tenant scoping** —
  structural, via `conn.assigns.scoped_opts`'s `:prefix`
  (`Letflow.Api.Context.scoped_repo_opts/1`'s output, resolved before this
  router's code runs) — an attachment or instance belonging to another
  tenant simply does not exist in the caller's own Postgres schema, so
  `Letflow.Repository.Attachments.get/2`/`list/2` already resolve that to
  `{:error, :not_found}`/an empty list.

  The two `:attachment_id` routes (byte-content `GET` and `DELETE`)
  additionally perform **(b) an explicit, in-handler cross-instance check**:
  `Attachments.get/2` takes no `instance_id` parameter, so it cannot itself
  verify a fetched attachment belongs to the `:id` named in the path — this
  router compares `attachment.instance_id == path_instance_id` after every
  `get/2` call on those two routes and treats a mismatch identically to
  `{:error, :not_found}`. **This is a distinct code path from (a) and must
  never be skipped because (a) already passed** — an attachment that is
  real and tenant-correct but belongs to a different instance must still
  404, not leak.

  Both checks fold to the same `Response.not_found/1` call — no
  distinguishing detail, matching this router's own existing INV-5
  precedent for every other route above.

  ### Byte-retrieval mechanism (design §4, corrected for INV-RT-1)

  The byte-content `GET` route calls `Letflow.Repository.Attachments.
  get_content/2`, which performs **two** sequential lookups internally, both
  inside the same tenant prefix: `get/2`'s own metadata query, then a
  second, separate `Repo.get(Letflow.Repository.Artifact,
  attachment.content_hash, prefix: prefix)` reading its `content` column
  (the `bytea` field REQ-211's design §2A added) for the actual bytes.
  **This design's own §4 originally specified that second `Repo.get` call
  as this route layer's own job** — corrected during Step 2a: this
  codebase's project-wide `INV-RT-1` invariant
  (`test/letflow/routers/req078_supporting_routes_test.exs`'s `T-19` test)
  forbids any `Repo.*` call from `lib/letflow/routers/` at all, the same
  conflict REQ-191/192 already hit and resolved by adding the needed read
  to the context module rather than the router
  (`Letflow.ServiceCatalog.list_all/1`) — `get_content/2` is that same
  relocation applied here, not a change to the retrieval mechanism itself.
  The metadata routes (`POST`, list `GET`, `DELETE`) never touch
  `repository_artifacts` at all. A `{:error, :content_missing}` result from
  `get_content/2` is a structural-invariant violation (the FK guarantees a
  matching row) — mapped to `Response.internal_error/1`, never a 404, since
  a 404 here would incorrectly suggest the attachment itself doesn't exist.

  ### Authorization (design §6)

  `AttachmentsManage` (upload, delete) and `AttachmentsRead` (list,
  download) — see `Letflow.Api.Authorization`'s own moduledoc section for
  why these are genuinely new permissions, not pre-ported like
  `DlqOperate`/`WebhooksManage`, and why AC4 requires the two-permission
  split kept rather than collapsed into one. Role mapping (a judgment call,
  flagged for REVIEWER, design §6.5): `PLATFORM_ADMIN` holds both
  (catch-all); `PROCESS_OPERATOR` holds both; `PROCESS_DESIGNER` and
  `TASK_WORKER` hold `AttachmentsRead` only; `AGENT_RUNNER` holds neither.
  `TENANT_ADMIN` holds both (every tenant-scope permission); the read-only
  `TENANT_AUDITOR` (REQ-448) holds `AttachmentsRead` only. Issuing a signed
  link (`POST .../link`) persists state, so since REQ-448 it is keyed
  `AttachmentLinksIssue`, held by exactly `PLATFORM_ADMIN`, `PROCESS_DESIGNER`,
  `PROCESS_OPERATOR`, `TASK_WORKER` and `TENANT_ADMIN`; `GET .../link-content`
  stays `AttachmentsRead`.

  ### Not validated by this route layer (design §5.1, §9 OQ-1)

  Instance existence itself is not checked before `upload/2`/`list/2` — no
  acceptance criterion asks for it, and REQ-211's own OQ-1 left it
  unresolved. A caller can upload/list against a syntactically-valid UUID
  that names no real instance; `upload/2` creates the row anyway and
  `list/2` returns an empty page. Deferred, not silently decided.

  ### Route ordering

  The four new routes are declared immediately after `/:id/pins` and before
  the bare `authz_get "/:id"` — all four are literal path suffixes under
  `/:id/`, so they do not collide with the bare `/:id` route's matching, but
  must be declared above it so `/:id/attachments...` isn't swallowed as a
  literal `:id` value (same ordering discipline this moduledoc's own
  "Route ordering" section above already states for `/:id/history` etc.).
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Context
  alias Letflow.Api.Error
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Audit
  alias Letflow.Engine
  alias Letflow.Engine.PinRebind
  alias Letflow.Engine.PinResolver
  alias Letflow.Engine.Reconstruction
  alias Letflow.Idempotency
  alias Letflow.Instances
  alias Letflow.Repository.Artifact
  alias Letflow.Repository.Attachment
  alias Letflow.Repository.Attachments
  alias Letflow.Repository.AttachmentLinks
  alias Letflow.Scheduler

  # PROVENANCE (historical, not current decision authority):
  # Letflow.Engine.PinResolver.kind() rendered as the three strings R-Co's
  # parsePinKind accepts (pin_rebind.zig:165-170).
  @pin_kinds ["catalog_entry", "variable_schema", "module"]

  # MUST precede any future `post "/:id"` -- see this module's moduledoc.
  #
  # REQ-131: no endpoint_policy_key/2 clause exists for this route (see
  # "Authorization gap" below) -- :InstancesCancel is a route-declared
  # policy key, reusing the same permission POST /:id/cancel already
  # requires (both mutate an in-flight instance's execution state), NOT
  # derived from Authorization.endpoint_policy_key/2. Named on the
  # enforcement test's explicit allowlist (design §4) -- flagged for
  # REVIEWER as a judgment call, not silently decided.
  authz_post "/:id/rebind-pins", :InstancesCancel do
    handle_rebind_pins(conn, conn.params["id"])
  end

  authz_post "/:id/cancel", :InstancesCancel do
    handle_cancel(conn, conn.params["id"])
  end

  # REQ-131: same judgment call as /:id/rebind-pins above -- see that
  # route's comment and the enforcement test's allowlist.
  authz_post "/:id/reconstruct", :InstancesCancel do
    handle_reconstruct(conn, conn.params["id"])
  end

  # ISS-0389 -- force-fire a pending TIMER node. MUST precede the bare
  # `authz_post "/"` below -- same ordering hazard class as the other
  # `/:id/...` suffixes above (moduledoc "Route ordering").
  authz_post "/:id/advance-timer", :InstancesAdvanceTimer do
    handle_advance_timer(conn, conn.params["id"])
  end

  authz_post "/", :InstancesStart do
    handle_create(conn)
  end

  # REQ-080 read routes. MUST precede `get "/:id"` below -- same hazard
  # class Letflow.Routers.Tasks's `/inbox`-before-`/:id` note documents;
  # `Plug.Router` first-match-wins would otherwise have `/:id` swallow each
  # of these with `id` bound to the literal suffix.
  authz_get "/:id/history", :InstancesRead do
    handle_history(conn, conn.params["id"])
  end

  authz_get "/:id/timeline", :InstancesRead do
    handle_timeline(conn, conn.params["id"])
  end

  authz_get "/:id/pins", :InstancesRead do
    handle_get_pins(conn, conn.params["id"])
  end

  # REQ-212 -- instance-attachment routes. MUST precede the bare `authz_get
  # "/:id"`/`authz_post "/"` below -- same ordering hazard class as
  # /:id/history etc. above (see moduledoc's "Route ordering" section).
  authz_post "/:id/attachments", :AttachmentsManage do
    handle_upload_attachment(conn, conn.params["id"])
  end

  authz_get "/:id/attachments", :AttachmentsRead do
    handle_list_attachments(conn, conn.params["id"])
  end

  authz_get "/:id/attachments/:attachment_id", :AttachmentsRead do
    handle_get_attachment_content(conn, conn.params["id"], conn.params["attachment_id"])
  end

  authz_delete "/:id/attachments/:attachment_id", :AttachmentsManage do
    handle_delete_attachment(conn, conn.params["id"], conn.params["attachment_id"])
  end

  # REQ-386 -- signed, time-limited attachment links. Same ordering hazard
  # class as the REQ-212 routes above: both have one more literal path
  # segment than the bare /:id/attachments/:attachment_id route so there is
  # no segment-count collision either way, but they are declared here,
  # grouped with the other attachment routes and above the bare
  # `authz_get "/:id"` below, matching this router's own "longer, more
  # specific suffixes first" convention (design §3.3).
  authz_post "/:id/attachments/:attachment_id/link", :AttachmentLinksIssue do
    handle_issue_attachment_link(conn, conn.params["id"], conn.params["attachment_id"])
  end

  authz_get "/:id/attachments/:attachment_id/link-content", :AttachmentsRead do
    handle_get_attachment_link_content(conn, conn.params["id"], conn.params["attachment_id"])
  end

  # REQ-392 design §1.2 -- tenant-wide storage-usage figure. No `:id` path
  # segment at all, but MUST still precede the bare `authz_get "/:id"` below
  # -- `/:id` matches any single path segment, including the literal string
  # "storage-usage", so declaration order still decides which route wins
  # (same ordering hazard class as /:id/rebind-pins etc. above; see
  # moduledoc's "Route ordering" section).
  authz_get "/storage-usage", :AttachmentsRead do
    handle_storage_usage(conn)
  end

  authz_get "/:id", :InstancesRead do
    handle_get_by_id(conn, conn.params["id"])
  end

  authz_get "/", :InstancesRead do
    handle_list(conn)
  end

  authz_unmatched(:ordinary)

  # ── POST /instances/:id/rebind-pins (design §10) ──────────────────────────

  @rebind_schema [
    %FieldConstraint{
      name: "reason",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 1024
    },
    %FieldConstraint{
      name: "entries",
      required: true,
      type: :array,
      min_items: 1
    }
  ]

  defp handle_rebind_pins(conn, raw_id) do
    with {:ok, body} <- object_body(conn),
         {:ok, instance_id} <- cast_instance_id(raw_id),
         {:ok, attrs} <- validate_body(body),
         {:ok, entries} <- normalise_entries(Map.get(attrs, "entries")),
         {:ok, opts} <- scoped_repo_opts(conn),
         {:ok, actor_id} <- actor_id(conn),
         {:ok, idempotency_key} <-
           Idempotency.from_header(conn, :inst_rebind, actor_id, instance_id) do
      rebind_attrs = %{
        entries: entries,
        reason: Map.get(attrs, "reason"),
        actor_id: actor_id,
        idempotency_key: idempotency_key
      }

      render_rebind(conn, PinRebind.rebind_pins(instance_id, rebind_attrs, opts))
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:error, :invalid_input} ->
        Response.unprocessable(conn, "request body failed validation")

      {:error, :missing_scope_or_actor} ->
        Response.internal_error(conn)

      {:error, :idempotency_key_too_long} ->
        idempotency_key_too_long(conn)

      {:error, :idempotency_key_invalid} ->
        idempotency_key_invalid(conn)
    end
  end

  defp render_rebind(conn, {:ok, result}), do: Response.ok(conn, rebind_result_map(result))

  defp render_rebind(conn, {:error, :instance_not_found}), do: Response.not_found(conn)

  # `_status` is deliberately NOT echoed: the constant detail keeps the body
  # stable across statuses.
  defp render_rebind(conn, {:error, {:instance_not_rebindable, _status}}),
    do: Response.conflict(conn, "instance is in a terminal state and cannot be rebound")

  # GH #2590 / REQ-501 R3 (decision 0054 D6 property 4): a module-owned, handler-calling
  # definition's sub-process pin cannot be rebound. Constant detail: neither `ref` nor the
  # module is echoed.
  defp render_rebind(conn, {:error, {:rebind_refused_owned_definition, _kind, _ref}}),
    do: Response.conflict(conn, "instance's definition is module-owned and cannot be rebound")

  defp render_rebind(conn, {:error, {:concurrent_modification, _instance_id}}),
    do: Response.conflict(conn, "instance is locked by another transaction")

  # Neither `kind` nor `ref` is echoed. Both are caller-supplied so echoing
  # would be safe, but a constant detail matches Letflow.Routers.Tenants's
  # established constant-detail style.
  defp render_rebind(conn, {:error, {:unknown_pin_ref, _kind, _ref}}),
    do:
      Response.unprocessable(
        conn,
        "a requested entry is not present in the instance's current effective pin set"
      )

  defp render_rebind(conn, {:error, :invalid_instance_id}),
    do: Response.unprocessable(conn, "instance_id is not a valid UUID")

  defp render_rebind(conn, {:error, reason})
       when reason in [:invalid_reason, :empty_entries],
       do: Response.unprocessable(conn, "request body failed validation")

  defp render_rebind(conn, {:error, {:malformed_entry, _index, _reason}}),
    do: Response.unprocessable(conn, "request body failed validation")

  # All route-construction bugs, not caller errors: INV-4's no-detail 500.
  # {:event_append_failed, _}, %Ecto.Changeset{} and any other term land here
  # too. No 503 branch -- see the moduledoc.
  defp render_rebind(conn, {:error, _internal}), do: Response.internal_error(conn)

  # ── POST /instances (design §"Routes"/create) ─────────────────────────────

  @create_schema [
    %FieldConstraint{name: "definition_id", required: false, type: :uuid},
    %FieldConstraint{
      name: "definition_name",
      required: false,
      type: :string,
      reject_empty_string: true
    },
    %FieldConstraint{name: "correlation_key", required: false, type: :string},
    %FieldConstraint{name: "initial_variables", required: true, type: :object}
  ]

  defp handle_create(conn) do
    opts = conn.assigns.scoped_opts
    actor_id = conn.assigns.auth_context.user_id

    with {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@create_schema, body),
         {:ok, idempotency_key} <- Idempotency.from_header(conn, :inst_start, actor_id, nil) do
      create_attrs = create_attrs(attrs, actor_id, idempotency_key)
      render_create(conn, Engine.create(create_attrs, opts))
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:error, :idempotency_key_too_long} ->
        idempotency_key_too_long(conn)

      {:error, :idempotency_key_invalid} ->
        idempotency_key_invalid(conn)
    end
  end

  # Only includes keys the request actually sent (never a nil-valued key),
  # so a caller who supplied neither/both of definition_id/definition_name
  # still reaches Engine.create/2's own XOR check rather than being masked
  # by a nil key -- see this module's moduledoc.
  defp create_attrs(attrs, actor_id, idempotency_key) do
    %{
      initial_variables: Map.fetch!(attrs, "initial_variables"),
      actor_id: actor_id,
      idempotency_key: idempotency_key
    }
    |> maybe_put(:definition_id, Map.get(attrs, "definition_id"))
    |> maybe_put(:definition_name, Map.get(attrs, "definition_name"))
    |> maybe_put(:correlation_key, Map.get(attrs, "correlation_key"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp render_create(conn, {:ok, result}) do
    Response.created(conn, %{
      "instance_id" => result.instance_id,
      "status" => status_string(result.status),
      "created_at" => DateTime.to_iso8601(result.started_at)
    })
  end

  defp render_create(conn, {:error, reason})
       when reason in [:missing_definition_reference, :both_definition_id_and_name],
       do:
         Response.unprocessable(
           conn,
           "exactly one of definition_id or definition_name is required"
         )

  # :tenant_id_not_accepted and :invalid_initial_variables are unreachable via
  # this route (create_attrs/2 never produces a :tenant_id key; @create_schema
  # gates initial_variables' type before Engine.create/2 ever runs) -- mapped
  # anyway for completeness/defence-in-depth, same style as the moduledoc's
  # other unreachable-but-mapped rows.
  defp render_create(conn, {:error, reason})
       when reason in [:tenant_id_not_accepted, :invalid_initial_variables],
       do: Response.unprocessable(conn, "request body failed validation")

  defp render_create(conn, {:error, :definition_not_found}), do: Response.not_found(conn)

  defp render_create(conn, {:error, :definition_not_active}),
    do: Response.conflict(conn, "only an ACTIVE definition can be started")

  defp render_create(conn, {:error, :duplicate_correlation_key}),
    do:
      Response.conflict(
        conn,
        "an active instance with this correlation key already exists"
      )

  defp render_create(conn, {:error, {tag, _detail}})
       when tag in [
              :unresolved_catalog_ref,
              :unresolved_module_ref,
              :unresolved_pin_override,
              :variable_schema_violation
            ],
       do: Response.unprocessable(conn, "request body failed validation")

  # {:snapshot_failed, _}, {:graph_structure_invalid, _}, {:activation_failed,
  # _}, {:event_append_failed, _}, {:parent_pin_lookup_failed, _},
  # %Ecto.Changeset{}, :invalid_schema_name, and any other term: INV-4's
  # no-detail 500. No 503 branch -- see the moduledoc.
  defp render_create(conn, {:error, _internal}), do: Response.internal_error(conn)

  # ── POST /instances/:id/cancel (design §"Routes"/cancel) ──────────────────

  defp handle_cancel(conn, raw_id) do
    opts = conn.assigns.scoped_opts
    actor_id = conn.assigns.auth_context.user_id

    with {:ok, instance_id} <- cast_instance_id(raw_id),
         {:ok, idempotency_key} <-
           Idempotency.from_header(conn, :inst_cancel, actor_id, instance_id) do
      cancel_attrs = %{actor_id: actor_id, idempotency_key: idempotency_key}
      render_cancel(conn, Engine.cancel_instance(instance_id, cancel_attrs, opts))
    else
      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")

      {:error, :idempotency_key_too_long} ->
        idempotency_key_too_long(conn)

      {:error, :idempotency_key_invalid} ->
        idempotency_key_invalid(conn)
    end
  end

  defp render_cancel(conn, {:ok, result}) do
    Response.ok(conn, %{"instance_id" => result.instance_id, "status" => "CANCELLED"})
  end

  defp render_cancel(conn, {:error, :invalid_instance_id}),
    do: Response.unprocessable(conn, "instance_id is not a valid UUID")

  defp render_cancel(conn, {:error, :instance_not_found}), do: Response.not_found(conn)

  # Distinct detail strings per terminal status (AC6) -- both states are
  # equally caller-meaningful, unlike render_rebind/2's constant-detail
  # precedent, which is about not leaking *internal* detail.
  defp render_cancel(conn, {:error, {:instance_already_terminal, :completed}}),
    do: Response.conflict(conn, "instance is already completed and cannot be cancelled")

  defp render_cancel(conn, {:error, {:instance_already_terminal, :cancelled}}),
    do: Response.conflict(conn, "instance is already cancelled")

  # {:event_append_failed, _}, %Ecto.Changeset{}, :missing_actor_id,
  # :missing_idempotency_key, :invalid_schema_name, and any other term:
  # INV-4's no-detail 500. The last three are route-unreachable (actor_id and
  # idempotency_key are always sourced by this handler, never absent; the
  # schema name is resolved from the authenticated tenant_id, never
  # caller-supplied) -- see the moduledoc.
  defp render_cancel(conn, {:error, _internal}), do: Response.internal_error(conn)

  # ── POST /instances/:id/reconstruct (design §"Routes"/reconstruct) ────────
  #
  # No endpoint_policy_key/2 clause exists for this route -- see the
  # moduledoc. Authenticated + tenant-scoped only, matching REQ-078's
  # rebind-pins precedent.
  defp handle_reconstruct(conn, raw_id) do
    case scoped_repo_opts(conn) do
      {:ok, opts} ->
        case cast_instance_id(raw_id) do
          {:ok, instance_id} ->
            render_reconstruct(
              conn,
              Reconstruction.reconstruct_instance(
                instance_id,
                Keyword.put(opts, :write_back, true)
              )
            )

          {:error, :invalid_instance_id} ->
            Response.unprocessable(conn, "instance_id is not a valid UUID")
        end

      {:error, :missing_scope_or_actor} ->
        Response.internal_error(conn)
    end
  end

  defp render_reconstruct(conn, {:ok, result}) do
    state = result.instance_state

    Response.ok(conn, %{
      "instance_id" => result.instance_id,
      "status" => status_string(state.status),
      "tokens" => Enum.map(state.tokens, &token_map/1),
      "variables" => Response.public_variables(state.variables)
    })
  end

  defp render_reconstruct(conn, {:error, :invalid_instance_id}),
    do: Response.unprocessable(conn, "instance_id is not a valid UUID")

  defp render_reconstruct(conn, {:error, :instance_not_found}), do: Response.not_found(conn)

  defp render_reconstruct(conn, {:error, {:lock_contention, _instance_id}}),
    do: Response.conflict(conn, "instance is locked by another transaction")

  # {:replay_failed, _}, :invalid_schema_name, and any other term: INV-4's
  # no-detail 500. No 503 branch -- see the moduledoc.
  defp render_reconstruct(conn, {:error, _internal}), do: Response.internal_error(conn)

  defp token_map(token), do: %{"node_id" => token.node_id, "branch_id" => token.branch_id}

  # ── POST /instances/:id/advance-timer (ISS-0389 design §1-4) ──────────────
  #
  # Force-fires a pending TIMER node ahead of its own `fire_at`. Resolves
  # "which timer" via `Scheduler.resolve_advance_target/3` (the router never
  # issues a direct repo call itself, INV-RT-1), then delegates the actual
  # fire to the existing `Scheduler.fire_timer/2` unchanged.
  defp handle_advance_timer(conn, raw_id) do
    opts = conn.assigns.scoped_opts
    tenant_schema = Keyword.fetch!(opts, :prefix)

    with {:ok, body} <- object_body(conn),
         {:ok, instance_id} <- cast_instance_id(raw_id),
         {:ok, timer_id} <- cast_optional_timer_id(Map.get(body, "timer_id")),
         {:ok, timer} <- Scheduler.resolve_advance_target(instance_id, timer_id, tenant_schema) do
      render_advance_timer(
        conn,
        instance_id,
        timer,
        Scheduler.fire_timer(timer.id, tenant_schema)
      )
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")

      {:error, :invalid_timer_id} ->
        Response.unprocessable(conn, "timer_id is not a valid UUID")

      {:error, :no_pending_timer} ->
        Response.not_found(conn)

      {:error, :ambiguous_pending_timers} ->
        Response.send_problem(conn, ambiguous_pending_timers_problem())
    end
  end

  # REQ-494 design §5: the generic bad-request problem plus a machine-readable
  # `code` extension, so a client can tell this 400 apart (an instance with a
  # HUMAN_TASK reminder and escalation always has two pending timers).
  # `type`/`title` stay the generic bad-request ones.
  @spec ambiguous_pending_timers_problem() :: Error.t()
  defp ambiguous_pending_timers_problem do
    %Error{
      Error.bad_request("instance has more than one pending timer; specify timer_id")
      | extensions: %{"code" => "ambiguous_pending_timers"}
    }
  end

  defp render_advance_timer(conn, instance_id, timer, {:ok, fire_result})
       when fire_result in [:fired, :already_final] do
    Response.ok(conn, %{
      "instance_id" => instance_id,
      "timer_id" => timer.id,
      "node_id" => timer.node_id,
      "timer_status" => Atom.to_string(fire_result)
    })
  end

  # INV-4 no-detail 500 -- matches render_cancel/2, render_reconstruct/2's
  # own precedent for internal/unexpected fire_timer/2 failures.
  defp render_advance_timer(conn, _instance_id, _timer, {:error, _reason}),
    do: Response.internal_error(conn)

  defp cast_optional_timer_id(nil), do: {:ok, nil}

  defp cast_optional_timer_id(raw_timer_id) when is_binary(raw_timer_id) do
    case Ecto.UUID.cast(raw_timer_id) do
      {:ok, timer_id} -> {:ok, timer_id}
      :error -> {:error, :invalid_timer_id}
    end
  end

  defp cast_optional_timer_id(_not_a_string), do: {:error, :invalid_timer_id}

  # ── GET /instances/:id (design §"Router"/get_by_id) ────────────────────

  defp handle_get_by_id(conn, raw_id) do
    opts = conn.assigns.scoped_opts

    case cast_instance_id(raw_id) do
      {:ok, id} ->
        render_get_by_id(conn, Instances.get_by_id(id, opts))

      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")
    end
  end

  defp render_get_by_id(conn, {:ok, projection}), do: Response.ok(conn, instance_map(projection))
  defp render_get_by_id(conn, {:error, :not_found}), do: Response.not_found(conn)

  defp render_get_by_id(conn, {:error, :invalid_id}),
    do: Response.unprocessable(conn, "instance_id is not a valid UUID")

  defp instance_map(projection) do
    %{
      "instance_id" => projection.instance_id,
      "definition_id" => projection.definition_id,
      "correlation_key" => projection.correlation_key,
      "status" => status_string(projection.status),
      "variables" => Response.public_variables(projection.variables),
      "started_at" => DateTime.to_iso8601(projection.started_at),
      "completed_at" => optional_iso8601(projection.completed_at),
      "cancelled_at" => optional_iso8601(projection.cancelled_at),
      "error_detail" => projection.error_detail
    }
  end

  defp optional_iso8601(nil), do: nil
  defp optional_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # ── GET /instances (design §"Router"/list) ──────────────────────────────

  defp handle_list(conn) do
    opts = conn.assigns.scoped_opts
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size),
         {:ok, started_after} <- parse_optional_timestamp(Map.get(query, "started_after")),
         {:ok, started_before} <- parse_optional_timestamp(Map.get(query, "started_before")) do
      params = %{
        status: Map.get(query, "status"),
        definition_id: Map.get(query, "definition_id"),
        correlation_key: Map.get(query, "correlation_key"),
        started_after: started_after,
        started_before: started_before,
        cursor: Map.get(query, "cursor"),
        page_size: page_size
      }

      Instances.list(params, opts) |> render_page_result(conn, &list_item_map/1)
    else
      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")

      {:error, :invalid_timestamp} ->
        Response.unprocessable(
          conn,
          "started_after/started_before must be valid ISO 8601 timestamps"
        )
    end
  end

  defp list_item_map(projection) do
    %{
      "instance_id" => projection.instance_id,
      "definition_id" => projection.definition_id,
      "correlation_key" => projection.correlation_key,
      "status" => status_string(projection.status),
      "started_at" => DateTime.to_iso8601(projection.started_at)
    }
  end

  # ── GET /instances/:id/history (design §"Router"/history) ──────────────

  defp handle_history(conn, raw_id) do
    opts = conn.assigns.scoped_opts
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, id} <- cast_instance_id(raw_id),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size),
         {:ok, from} <- parse_optional_timestamp(Map.get(query, "from")),
         {:ok, to} <- parse_optional_timestamp(Map.get(query, "to")) do
      params = %{
        event_type: Map.get(query, "event_type"),
        from: from,
        to: to,
        cursor: Map.get(query, "cursor"),
        page_size: page_size
      }

      result = Instances.history(id, params, opts)

      names =
        case result do
          {:ok, %{items: items}} -> Instances.actor_display_names(items, opts)
          _error -> %{}
        end

      render_page_result(result, conn, &history_item_map(&1, names))
    else
      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")

      {:error, :invalid_timestamp} ->
        Response.unprocessable(conn, "from/to must be valid ISO 8601 timestamps")
    end
  end

  # CO-1 (GH #2587 PR B3): the payload is shaped by `Response.public_event_payload/2`, never
  # emitted verbatim, so engine-written `_sys` values and record ids cannot reach a client.
  defp history_item_map(event, display_names) do
    %{
      "event_id" => event.event_id,
      "actor_id" => event.actor_id,
      "actor_display_name" => Map.get(display_names, event.actor_id),
      "event_type" => event.event_type,
      "sequence_number" => event.sequence_number,
      "created_at" => DateTime.to_iso8601(event.created_at),
      "payload" => Response.public_event_payload(event.event_type, event.payload)
    }
  end

  # ── GET /instances/:id/timeline (design §"Router"/timeline) ────────────

  defp handle_timeline(conn, raw_id) do
    opts = conn.assigns.scoped_opts
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, id} <- cast_instance_id(raw_id),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      params = %{cursor: Map.get(query, "cursor"), page_size: page_size}
      Instances.timeline(id, params, opts) |> render_page_result(conn, &timeline_item_map/1)
    else
      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")
    end
  end

  defp timeline_item_map(item) do
    %{
      "event_id" => item.event_id,
      "event_type" => item.event_type,
      "sequence_num" => item.sequence_num,
      "instance_id" => item.instance_id,
      "timestamp" => DateTime.to_iso8601(item.timestamp),
      "node_id" => item.node_id,
      "task_id" => item.task_id,
      "metadata" => item.metadata,
      "actor_display_name" => item.actor_display_name,
      "description" => item.description
    }
  end

  # ── Shared page-result rendering (list/history/timeline) ────────────────

  defp render_page_result({:ok, %{items: items, next_cursor: next_cursor}}, conn, item_fn) do
    Response.ok(conn, %{
      "items" => Enum.map(items, item_fn),
      "next_cursor" => next_cursor,
      "count" => length(items)
    })
  end

  defp render_page_result({:error, :not_found}, conn, _item_fn), do: Response.not_found(conn)

  defp render_page_result({:error, :invalid_id}, conn, _item_fn),
    do: Response.unprocessable(conn, "instance_id is not a valid UUID")

  defp render_page_result({:error, :invalid_status}, conn, _item_fn),
    do: Response.unprocessable(conn, "status is not a recognised value")

  defp render_page_result({:error, :invalid_cursor}, conn, _item_fn),
    do: Response.unprocessable(conn, "cursor is not valid for this endpoint")

  defp render_page_result({:error, :wrong_endpoint}, conn, _item_fn),
    do: Response.unprocessable(conn, "cursor is not valid for this endpoint")

  defp render_page_result({:error, :expired}, conn, _item_fn),
    do: Response.send_problem(conn, Error.cursor_expired())

  defp parse_optional_timestamp(nil), do: {:ok, nil}

  defp parse_optional_timestamp(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _reason} -> {:error, :invalid_timestamp}
    end
  end

  # ── GET /instances/:id/pins (design §"Router"/get_pins) ─────────────────

  defp handle_get_pins(conn, raw_id) do
    opts = conn.assigns.scoped_opts

    case cast_instance_id(raw_id) do
      {:ok, id} ->
        render_get_pins(conn, id, PinResolver.reconstruct_effective_pins(id, opts))

      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")
    end
  end

  defp render_get_pins(conn, id, {:ok, pins}) do
    Response.ok(conn, %{"instance_id" => id, "pins" => Enum.map(pins, &pin_map/1)})
  end

  defp render_get_pins(conn, _id, {:error, :instance_not_found}), do: Response.not_found(conn)
  defp render_get_pins(conn, _id, {:error, _internal}), do: Response.internal_error(conn)

  defp pin_map(pin) do
    %{
      "kind" => Atom.to_string(pin.kind),
      "ref" => pin.ref,
      "resolved_id" => pin.resolved_id,
      "version" => pin.version,
      "source" => Atom.to_string(pin.source)
    }
  end

  # ── GET /instances/storage-usage (REQ-392 design §1.2) ───────────────────

  defp handle_storage_usage(conn) do
    opts = conn.assigns.scoped_opts
    render_storage_usage(conn, Attachments.storage_summary(opts))
  end

  defp render_storage_usage(conn, {:ok, %{used_bytes: used_bytes, allowance_bytes: allowance}}) do
    Response.ok(conn, %{"used_bytes" => used_bytes, "allowance_bytes" => allowance})
  end

  defp render_storage_usage(conn, {:error, :tenant_not_found}) do
    Response.unprocessable(conn, "request tenant does not exist")
  end

  # ── POST /instances/:id/attachments (REQ-212 design §5.4) ────────────────

  defp handle_upload_attachment(conn, raw_id) do
    opts = conn.assigns.scoped_opts

    with {:ok, instance_id} <- cast_instance_id(raw_id),
         {:ok, actor_id} <- actor_id(conn),
         {:ok, attrs} <- upload_attrs_from_conn(conn, instance_id, actor_id) do
      render_upload_attachment(conn, attrs, Attachments.upload(attrs, opts))
    else
      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")

      {:error, :missing_scope_or_actor} ->
        Response.internal_error(conn)

      {:error, :missing_file} ->
        Response.unprocessable(conn, "a file part named \"file\" is required")
    end
  end

  # Sourced fields (design §5.4): instance_id from the already-cast path
  # :id, raw_bytes/file_name/content_type from the multipart `file` part
  # (%Plug.Upload{}), uploaded_by from the authenticated caller (never a
  # request field), description from the optional `description` text part.
  @spec upload_attrs_from_conn(Plug.Conn.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Attachments.upload_attrs()} | {:error, :missing_file}
  defp upload_attrs_from_conn(conn, instance_id, actor_id) do
    case conn.body_params["file"] do
      %Plug.Upload{path: path, filename: filename, content_type: content_type} ->
        attrs = %{
          instance_id: instance_id,
          raw_bytes: File.read!(path),
          file_name: filename,
          content_type: content_type,
          uploaded_by: actor_id,
          description: attachment_description(conn.body_params["description"])
        }

        {:ok, attrs}

      _missing_or_not_a_file ->
        {:error, :missing_file}
    end
  end

  defp attachment_description(value) when is_binary(value) and byte_size(value) > 0, do: value
  defp attachment_description(_absent_or_empty), do: nil

  defp render_upload_attachment(conn, _attrs, {:ok, attachment}) do
    Response.created(conn, attachment_json(attachment))
  end

  # REQ-389 design §3.3 -- distinct in status code (415, vs. 413/422/503)
  # and body text (names the rejected content_type and the allowed set)
  # from every other clause here. content_type is read from the same
  # already-extracted attrs map the caller passed to Attachments.upload/2,
  # never re-derived.
  defp render_upload_attachment(conn, attrs, {:error, :content_type_not_allowed}) do
    allowed =
      Attachments.allowed_content_types()
      |> Enum.sort()
      |> Enum.join(", ")

    Response.unsupported_media_type(
      conn,
      "content type \"#{attrs.content_type}\" is not allowed for attachments; allowed types are: #{allowed}"
    )
  end

  defp render_upload_attachment(conn, _attrs, {:error, :file_too_large}) do
    Response.payload_too_large(conn, "uploaded file exceeds the maximum allowed size")
  end

  # ISS-0399 design §7 OQ-4 -- infected content is a caller-actionable
  # rejection (4xx), never a 500.
  defp render_upload_attachment(conn, _attrs, {:error, :infected, verdict}) do
    Response.unprocessable(conn, "uploaded file failed a content scan (#{verdict})")
  end

  # ISS-0399 design §7 OQ-4 -- the scanner adapter itself was unavailable
  # (e.g. a future external-AV call timed out); this is an infrastructure
  # failure, not a rejection of the file itself, and is retry-able.
  defp render_upload_attachment(conn, _attrs, {:error, :scan_unavailable}) do
    Response.service_unavailable(conn, "content scan is temporarily unavailable, please retry")
  end

  defp render_upload_attachment(conn, _attrs, {:error, :storage_quota_exceeded}) do
    Response.conflict(conn, "tenant storage quota has been reached")
  end

  defp render_upload_attachment(conn, _attrs, {:error, :tenant_not_found}) do
    Response.unprocessable(conn, "request tenant does not exist")
  end

  # An Ecto.Changeset failure here means file_name exceeded 255 characters
  # (REQ-211 schema's only realistic changeset-rejection path via this
  # route's own construction) or another required_fields gap this route's
  # own construction should make unreachable -- mapped anyway for
  # completeness, matching render_create/2's own "unreachable but mapped"
  # discipline above.
  defp render_upload_attachment(conn, _attrs, {:error, %Ecto.Changeset{}}) do
    Response.unprocessable(conn, "request failed validation")
  end

  # ── GET /instances/:id/attachments (REQ-212 design §5.2) ─────────────────

  defp handle_list_attachments(conn, raw_id) do
    opts = conn.assigns.scoped_opts
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, instance_id} <- cast_instance_id(raw_id),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      params = %{
        instance_id: instance_id,
        cursor: Map.get(query, "cursor"),
        page_size: page_size
      }

      render_list_attachments(conn, Attachments.list(params, opts))
    else
      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")
    end
  end

  # Deliberately NOT render_page_result/3 -- that shared helper adds a
  # "count" key this route's own {items, next_cursor} shape (matching DLQ's
  # precedent) must not carry. See moduledoc/design §5.2.
  defp render_list_attachments(conn, {:ok, %{items: items, next_cursor: next_cursor}}) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &attachment_json/1),
      "next_cursor" => next_cursor
    })
  end

  defp render_list_attachments(conn, {:error, reason})
       when reason in [:invalid_cursor, :wrong_endpoint],
       do: Response.unprocessable(conn, "cursor is not valid for this endpoint")

  defp render_list_attachments(conn, {:error, :expired}),
    do: Response.send_problem(conn, Error.cursor_expired())

  defp render_list_attachments(conn, {:error, :page_size_too_large}),
    do: Response.bad_request(conn, "page_size out of range")

  # ── GET /instances/:id/attachments/:attachment_id (REQ-212 design §4/§5.3) ──

  defp handle_get_attachment_content(conn, raw_id, raw_attachment_id) do
    opts = conn.assigns.scoped_opts

    with {:ok, instance_id} <- cast_instance_id(raw_id),
         {:ok, attachment, artifact} <-
           fetch_scoped_attachment_content(raw_attachment_id, instance_id, opts, conn) do
      send_attachment_content(conn, attachment, artifact)
    else
      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :content_missing} ->
        Response.internal_error(conn)

      {:error, :not_available} ->
        Response.conflict(conn, "attachment content is not currently available")

      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")
    end
  end

  # INV-RT-1 (this codebase's project-wide route-layer boundary -- no
  # Repo.* call may be issued directly from lib/letflow/routers/, enforced
  # by test/letflow/routers/req078_supporting_routes_test.exs's T-19 test):
  # both the byte content lookup (Attachments.get_content/3's own second
  # Repo.get against repository_artifacts) and this handler's two 404
  # checks are delegated to the context module rather than issued here.
  #
  # Both the cross-tenant check (structural, via opts[:prefix]) and the
  # cross-instance-same-tenant check (explicit, in-handler) fold to the same
  # {:error, :not_found} -- design §5.1, AC5/AC6/INV-5. A malformed
  # attachment_id (:invalid_id) folds to the same tuple too, matching
  # Letflow.Routers.Dlq's own :invalid_id -> not_found precedent for a
  # cross-tenant-probeable UUID.
  @spec fetch_scoped_attachment_content(String.t(), Ecto.UUID.t(), keyword(), Plug.Conn.t()) ::
          {:ok, Attachment.t(), Artifact.t()}
          | {:error, :not_found | :content_missing | :not_available}
  defp fetch_scoped_attachment_content(raw_attachment_id, instance_id, opts, conn) do
    case Attachments.get_content(raw_attachment_id, instance_id, opts) do
      {:ok, %Attachment{instance_id: ^instance_id} = attachment, artifact} ->
        {:ok, attachment, artifact}

      # defense-in-depth: instance check now handled upstream in get_content/3;
      # get_content/3 returns {:error, :not_found} for cross-instance before
      # reaching here -- kept per design §5.1, AC5/AC6/INV-5 (ISS-0785)
      {:ok, %Attachment{} = attachment, _artifact} ->
        record_attachment_access_denied_audit(
          attachment.id,
          attachment,
          instance_id,
          opts,
          conn
        )

        {:error, :not_found}

      {:error, :invalid_id} ->
        {:error, :not_found}

      {:error, :not_found} ->
        # ISS-0785: get_content/3 now rejects cross-instance before the blob read, so
        # both cross-instance and cross-tenant/never-issued land here as :not_found.
        # Do a cheap tenant-scoped existence check to restore the audit distinction.
        found_attachment =
          case Attachments.get(raw_attachment_id, opts) do
            {:ok, attachment} -> attachment
            _ -> nil
          end

        record_attachment_access_denied_audit(
          raw_attachment_id,
          found_attachment,
          instance_id,
          opts,
          conn
        )

        {:error, :not_found}

      {:error, :content_missing} ->
        {:error, :content_missing}

      {:error, :not_available} ->
        {:error, :not_available}
    end
  end

  # REQ-388 design §2/§5 -- one Letflow.Audit entry on each denied branch of a
  # GET .../attachments/:attachment_id fetch (cross-tenant/never-issued,
  # fused per §3, and cross-instance-same-tenant). Reuses
  # TenantSettings.maybe_record_rejected_keys/5's own synchronous,
  # same-process, log-and-swallow idiom (§1) -- no async/Task.start
  # mechanism exists elsewhere in this codebase for an audit write. Both call
  # sites do the exact same shape of work (one Audit.insert_entry/3 call),
  # so this design's own addition does not introduce a new timing
  # distinguisher between the two audited branches (design §4).
  @spec record_attachment_access_denied_audit(
          String.t(),
          Attachment.t() | nil,
          Ecto.UUID.t(),
          keyword(),
          Plug.Conn.t()
        ) :: :ok
  defp record_attachment_access_denied_audit(
         attachment_id,
         found_attachment,
         instance_id,
         opts,
         conn
       ) do
    prefix = Keyword.fetch!(opts, :prefix)
    reason = if found_attachment, do: "cross_instance", else: "cross_tenant_or_not_found"

    attrs = %{
      actor_id: conn.assigns.auth_context.user_id,
      action: "attachment.access_denied",
      resource_type: "attachment",
      resource_id: attachment_id,
      before_state: nil,
      after_state: %{
        "instance_id" => instance_id,
        "reason" => reason
      },
      trace_id: conn.assigns[:trace_id]
    }

    case Audit.insert_entry(Letflow.Repo, attrs, prefix) do
      {:ok, _entry} ->
        :ok

      {:error, error_reason} ->
        # Best-effort, log-and-swallow (design §5, mirroring
        # TenantSettings.maybe_record_rejected_keys/5 and
        # Engine.record_task_activation_rejection_audit/5's own INV-8
        # discipline) -- an audit-write failure must never turn this
        # already-decided 404 into a 500, and must never delay the caller
        # beyond whatever insert_entry/3 itself takes.
        Logger.error(
          "attachment.access_denied audit write failed " <>
            "(attachment_id=#{attachment_id}, instance_id=#{instance_id}): " <>
            inspect(error_reason)
        )

        :ok
    end
  rescue
    exception ->
      # ISS-0980: no Repo.transaction/1 wrapper to rescue around here (this
      # write is intentionally non-transactional/best-effort), but a raise
      # from Audit.insert_entry/3 itself (e.g. a DROP TABLE-class fault) must
      # be caught at the function level for the same reason the {:error,
      # error_reason} branch above exists -- this already-decided 404 must
      # never become a 500 because of an unrelated audit-write hiccup. Same
      # ids-only, no-query-text logging discipline.
      Logger.error(
        "attachment.access_denied audit write raised " <>
          "(attachment_id=#{attachment_id}, instance_id=#{instance_id}): " <>
          inspect(exception)
      )

      :ok
  end

  # Metadata-only sibling of fetch_scoped_attachment_content/3, for DELETE
  # -- same two 404 checks, no repository_artifacts lookup (DELETE never
  # needs the byte content).
  @spec fetch_scoped_attachment_metadata(String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Attachment.t()} | {:error, :not_found}
  defp fetch_scoped_attachment_metadata(raw_attachment_id, instance_id, opts) do
    case Attachments.get(raw_attachment_id, opts) do
      {:ok, %Attachment{instance_id: ^instance_id} = attachment} -> {:ok, attachment}
      {:ok, %Attachment{}} -> {:error, :not_found}
      {:error, :invalid_id} -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp send_attachment_content(conn, %Attachment{} = attachment, %Artifact{} = artifact) do
    conn
    |> put_resp_content_type(attachment.content_type)
    |> put_resp_header("content-disposition", content_disposition(attachment.file_name))
    |> send_resp(200, artifact.content)
  end

  # Escapes literal `"` and `\` (Content-Disposition's own quoting rules)
  # and strips CR/LF/other C0 control characters before interpolating a
  # caller-supplied file_name into a raw HTTP header value -- put_resp_header/3
  # does not sanitize a handler-constructed header VALUE for CRLF injection
  # the way it does for a handler-controlled header NAME (design §3.3.1,
  # flagged for SECURITY-REVIEWER). Strip (not reject) chosen per design §7
  # OQ-3 -- this never affects the stored/returned file_name value itself,
  # only this one header's rendering.
  @spec content_disposition(String.t()) :: String.t()
  defp content_disposition(file_name) do
    sanitized =
      file_name
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> strip_control_characters()

    "attachment; filename=\"#{sanitized}\""
  end

  defp strip_control_characters(value) do
    String.replace(value, ~r/[\x00-\x1F\x7F]/, "")
  end

  # ── POST /instances/:id/attachments/:attachment_id/link (REQ-386 design §3.1) ──

  # Mints a signed, time-limited token for an attachment the caller has
  # already proven access to. Reuses fetch_scoped_attachment_metadata/3
  # verbatim (the same private helper DELETE already uses) -- issuing a link
  # needs proof of access, not the byte content itself, so this never
  # touches repository_artifacts.
  defp handle_issue_attachment_link(conn, raw_id, raw_attachment_id) do
    opts = conn.assigns.scoped_opts
    tenant_id = conn.assigns.auth_context.tenant_id

    with {:ok, instance_id} <- cast_instance_id(raw_id),
         {:ok, _attachment} <-
           fetch_scoped_attachment_metadata(raw_attachment_id, instance_id, opts),
         {:ok, %{token: token, expires_at: expires_at}} <-
           AttachmentLinks.issue(raw_attachment_id, tenant_id) do
      render_attachment_link(conn, raw_id, raw_attachment_id, token, expires_at)
    else
      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :invalid_tenant} ->
        Response.internal_error(conn)

      {:error, {:secret_write_failed, _reason}} ->
        Response.internal_error(conn)
    end
  end

  defp render_attachment_link(conn, raw_id, raw_attachment_id, token, expires_at) do
    Response.ok(conn, %{
      "attachment_id" => raw_attachment_id,
      "token" => token,
      "url" => link_content_url(raw_id, raw_attachment_id, token),
      "expires_at" => DateTime.to_iso8601(expires_at),
      "expires_in_seconds" => 300
    })
  end

  # No scheme/host -- matches every other response shape in this codebase,
  # none of which construct absolute URLs.
  @spec link_content_url(String.t(), String.t(), String.t()) :: String.t()
  defp link_content_url(instance_id, attachment_id, token) do
    "/instances/#{instance_id}/attachments/#{attachment_id}/link-content?link_token=#{URI.encode_www_form(token)}"
  end

  # ── GET /instances/:id/attachments/:attachment_id/link-content (REQ-386 design §3.2) ──

  # Deliberately a separate route/handler from handle_get_attachment_content/3
  # above -- not a modification of it. The existing route and its existing
  # handler are unmodified by this requirement; this handler calls the same
  # fetch_scoped_attachment_content/4 helper a second time, from a second
  # call site, with the attachment id recovered from a verified token rather
  # than the raw path segment. NOTE (merge of REQ-386/REQ-388, both
  # concurrently in flight against this same helper): REQ-388 widened
  # fetch_scoped_attachment_content/3 to /4 to carry `conn` through to its
  # own denied-access audit write (record_attachment_access_denied_audit/5)
  # -- this call site passes `conn` too, so a denied fetch through the
  # signed-link path is audited exactly the same way as one through the
  # plain-GET path, with no separate/duplicated audit logic needed here.
  defp handle_get_attachment_link_content(conn, raw_id, raw_attachment_id) do
    opts = conn.assigns.scoped_opts
    tenant_id = conn.assigns.auth_context.tenant_id
    conn = fetch_query_params(conn)
    link_token = conn.query_params["link_token"]

    with {:ok, instance_id} <- cast_instance_id(raw_id),
         {:ok, decoded_attachment_id} <- verify_link_token(link_token, tenant_id),
         :ok <- check_attachment_id_matches(decoded_attachment_id, raw_attachment_id),
         {:ok, attachment, artifact} <-
           fetch_scoped_attachment_content(decoded_attachment_id, instance_id, opts, conn) do
      send_attachment_content(conn, attachment, artifact)
    else
      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")

      {:error, :expired_or_invalid} ->
        Response.attachment_link_expired(conn)

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :content_missing} ->
        Response.internal_error(conn)

      {:error, :not_available} ->
        Response.conflict(conn, "attachment content is not currently available")
    end
  end

  # A missing/non-binary link_token is exactly as invalid as a malformed one
  # -- same shared response, no separate branch (design §3.2 step 4).
  @spec verify_link_token(term(), Ecto.UUID.t()) ::
          {:ok, String.t()} | {:error, :expired_or_invalid}
  defp verify_link_token(link_token, tenant_id) when is_binary(link_token) do
    AttachmentLinks.verify(link_token, tenant_id)
  end

  defp verify_link_token(_link_token, _tenant_id), do: {:error, :expired_or_invalid}

  # A validly-signed, unexpired token naming a *different* attachment than
  # the URL it was presented on is an integrity failure of the token/URL
  # pairing -- folded into the same expired-or-invalid response as every
  # other verification failure (design §3.2 step 5), not :not_found, so
  # there remains exactly one failure class for "the token doesn't check
  # out."
  @spec check_attachment_id_matches(String.t(), String.t()) ::
          :ok | {:error, :expired_or_invalid}
  defp check_attachment_id_matches(decoded_attachment_id, decoded_attachment_id), do: :ok
  defp check_attachment_id_matches(_decoded, _raw), do: {:error, :expired_or_invalid}

  # ── DELETE /instances/:id/attachments/:attachment_id (REQ-212 design §3.4) ──

  defp handle_delete_attachment(conn, raw_id, raw_attachment_id) do
    opts = conn.assigns.scoped_opts

    with {:ok, instance_id} <- cast_instance_id(raw_id),
         {:ok, _attachment} <-
           fetch_scoped_attachment_metadata(raw_attachment_id, instance_id, opts),
         {:ok, actor_id} <- actor_id(conn),
         {:ok, _deleted} <- Attachments.delete(raw_attachment_id, actor_id, opts) do
      Response.no_content(conn)
    else
      {:error, :not_found} -> Response.not_found(conn)
      {:error, :missing_scope_or_actor} -> Response.internal_error(conn)
    end
  end

  # ── Response allowlist (INV-2) — shared by POST/GET list (REQ-212 design §5.5) ──

  # Hand-built allowlist, matching dlq_entry_json/1's precedent -- never a
  # raw Jason.Encoder derivation over %Attachment{}, which would leak
  # __meta__/tenant_id. content_hash is likewise deliberately never
  # included -- see moduledoc.
  @spec attachment_json(Attachment.t()) :: map()
  defp attachment_json(%Attachment{} = attachment) do
    %{
      "id" => attachment.id,
      "instance_id" => attachment.instance_id,
      "file_name" => attachment.file_name,
      "content_type" => attachment.content_type,
      "byte_size" => attachment.byte_size,
      "uploaded_by" => attachment.uploaded_by,
      "description" => attachment.description,
      "created_at" => DateTime.to_iso8601(attachment.created_at)
    }
  end

  # Exhaustive over InstanceState.status/0's closed 4-atom union (create_result()
  # only ever produces :active/:completed, a subset -- shared here rather than
  # duplicated). A 5th atom would be a compile-time inexhaustive-case warning,
  # not a silent runtime fallback.
  defp status_string(:active), do: "ACTIVE"
  defp status_string(:completed), do: "COMPLETED"
  defp status_string(:cancelled), do: "CANCELLED"
  defp status_string(:error), do: "ERROR"

  defp validate_schema(schema, body) do
    case Validation.validate(schema, body) do
      {:ok, attrs} -> {:ok, attrs}
      {:errors, field_errors} -> {:errors, field_errors}
    end
  end

  # ── Request parsing ───────────────────────────────────────────────────────

  defp object_body(conn) do
    case conn.body_params do
      %{"_json" => _non_object} -> {:error, :malformed_json}
      body when is_map(body) -> {:ok, body}
      _other -> {:error, :malformed_json}
    end
  end

  defp cast_instance_id(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_instance_id}
    end
  end

  defp validate_body(body) do
    case Validation.validate(@rebind_schema, body) do
      {:ok, attrs} -> {:ok, attrs}
      {:errors, field_errors} -> {:errors, field_errors}
    end
  end

  # Per-element shape (kind/ref/version all present, all strings; kind one of
  # the three) has no FieldConstraint vocabulary, so it is checked here and
  # maps to R-Co's 422 INVALID_INPUT.
  defp normalise_entries(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case entry do
        %{"kind" => kind, "ref" => ref, "version" => version}
        when kind in @pin_kinds and is_binary(ref) and is_binary(version) ->
          {:cont, {:ok, [%{kind: kind, ref: ref, version: version} | acc]}}

        _malformed ->
          {:halt, {:error, :invalid_input}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp normalise_entries(_not_a_list), do: {:error, :invalid_input}

  defp scoped_repo_opts(conn) do
    case Context.scoped_repo_opts(conn) do
      {:ok, opts} -> {:ok, opts}
      {:error, _missing_auth_context_or_invalid_tenant_id} -> {:error, :missing_scope_or_actor}
    end
  end

  defp actor_id(conn) do
    case conn.assigns[:auth_context] do
      %{user_id: user_id} when is_binary(user_id) -> {:ok, user_id}
      _other -> {:error, :missing_scope_or_actor}
    end
  end

  # GH #2550: the stable 422 for an over-long `idempotency-key` header, with
  # nothing written. Same problem body on start, cancel and rebind.
  defp idempotency_key_too_long(conn),
    do: Response.send_problem(conn, Validation.problem([Idempotency.too_long_error(:header)]))

  # GH #2550: an `idempotency-key` header that is not valid UTF-8 or contains
  # NUL -- a stable 422 instead of the Postgres error (a 500) it used to reach.
  defp idempotency_key_invalid(conn),
    do: Response.send_problem(conn, Validation.problem([Idempotency.invalid_error(:header)]))

  # ── Response allowlist (INV-2) ────────────────────────────────────────────

  @spec rebind_result_map(PinRebind.rebind_result()) :: map()
  defp rebind_result_map(result) do
    %{
      "instance_id" => result.instance_id,
      "changes" => Enum.map(result.changed, &changed_entry_map/1),
      "rebound_at" => DateTime.to_iso8601(result.rebound_at)
    }
  end

  @spec changed_entry_map(PinRebind.changed_entry()) :: map()
  defp changed_entry_map(changed) do
    %{
      "kind" => Atom.to_string(changed.kind),
      "ref" => changed.ref,
      "prior_version" => changed.prior_version,
      "new_version" => changed.new_version
    }
  end
end
