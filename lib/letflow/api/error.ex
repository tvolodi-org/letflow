defmodule Letflow.Api.Error do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  RFC 9457 Problem Details builder — ports `src/api/errors.zig` (272 lines).

  Pure: no `Plug.Conn` dependency and no I/O. Build a `t()` with one of the
  per-status constructors below, then either serialise it yourself with
  `serialise/1` or hand it to `Letflow.Api.Response.send_problem/2`, which
  resolves `trace_id` from the conn and sends it.

  ## Zig-to-Elixir translation notes

  PROVENANCE (historical, not current decision authority):
  * **`HandlerResult` struct → conn-threading functions.** `errors.zig`'s
    companion `response.zig` returns a `HandlerResult` value
    (`status_code`/`body`/`content_type`) because Zig has no request object to
    thread through. In Elixir the conn *is* the result carrier, so that struct
    is not ported at all: `Letflow.Api.Response` exposes functions that take
    and return a `Plug.Conn.t()` instead. See `Letflow.Api.Response`'s
    moduledoc.
  PROVENANCE (historical, not current decision authority):
  * **Content-Type is a deliberate divergence from R-Co.** `response.zig`'s
    `problemResponse/2` does not set `content_type` on the `HandlerResult` it
    returns, so it falls through to the struct default
    `CONTENT_TYPE_JSON = "application/json"` — R-Co serves RFC 9457-shaped
    error bodies as `application/json`. Letflow intentionally does **not**
    replicate that: error responses are sent as `application/problem+json`,
    the media type RFC 9457 §3 defines for exactly this document shape.
    Success responses stay on `application/json`, matching R-Co.
  PROVENANCE (historical, not current decision authority):
  * **No allocator-failure fallback.** `errors.zig`'s `serialise/2` can fail
    with `error{OutOfMemory}`, and `response.zig`'s `problemResponse/2` has a
    hand-written literal 500 JSON string for that case. Elixir has no
    caller-managed allocator, so neither the error union nor the fallback body
    has an analogue; both are deliberately dropped rather than transliterated.
  PROVENANCE (historical, not current decision authority):
  * **Strings are properly escaped.** `errors.zig`'s `serialise/2` builds its
    JSON with `std.fmt.allocPrint` and literal `"{s}"` interpolation, which
    does **not** escape quotes, backslashes, or control characters inside
    `detail`. `serialise/1` here uses `Jason`, which does full RFC 8259 string
    escaping — this fixes an unescaped-string bug present in the Zig source and
    must not be "fixed" back to raw interpolation.

  ## Security invariants

  * **INV-4** — `internal/0` takes no `detail` argument. Its detail string is a
    module attribute baked into the function body, so no exception message,
    struct, or stacktrace can reach a 500 body through any parameter: the
    signature has no slot for one.
  * **INV-5** — `not_found/0` likewise takes no argument. Every 404 in the
    system, whether a genuine missing resource or a cross-tenant probe
    (REQ-072), goes through this one constructor with no varying input, so the
    two bodies are byte-identical by construction.

  Every other constructor keeps a `detail` parameter; the caller is
  responsible for passing a caller-safe string (never a raw Ecto/Postgrex
  error, secret material, or a stack trace).
  """

  @problems_base Application.compile_env(
                   :letflow,
                   :problems_base_uri,
                   "https://bpm.example.com/problems/"
                 )

  @internal_error_detail "an unexpected error occurred"
  @not_found_detail "the requested resource was not found"

  @derive {Jason.Encoder, only: [:type, :title, :status, :detail, :trace_id]}
  defstruct [:type, :title, :status, :detail, trace_id: "", errors: nil, extensions: nil]

  @typedoc """
  PROVENANCE (historical, not current decision authority):
  An RFC 9457 Problem Details object. Mirrors `errors.zig`'s `ProblemDetails`
  field set 1:1 (`type`/`title`/`status`/`detail`/`trace_id`), plus one
  extension member this port adds: `errors`, a list of per-field validation
  errors (REQ-068 `Letflow.Api.Validation.problem/1`), `nil` on every
  constructor here and every non-validation error — see
  `lib/letflow/design/req068-validation.md` §0.5.

  **Deliberately excluded from the `@derive {Jason.Encoder, only: [...]}`
  list above** — `Jason`'s derived struct encoder does NOT omit `nil` fields
  (it emits `"errors":null`, verified against `deps/jason/lib/encoder.ex`),
  which would add a sixth key to every existing non-validation problem
  document and break the "serialise/1 emits all five RFC 9457 keys" contract
  `error_test.exs` already pins. `serialise/1` below builds the JSON map
  explicitly instead, including `errors` only when it is a non-empty list,
  so every non-validation problem document stays byte-identical to before
  this field was added.
  """
  @type t :: %__MODULE__{
          type: String.t(),
          title: String.t(),
          status: 400..599,
          detail: String.t(),
          trace_id: String.t(),
          errors: [struct()] | nil,
          extensions: map() | nil
        }

  @doc """
  Serialise a problem document to a JSON body.

  PROVENANCE (historical, not current decision authority):
  Unlike `errors.zig`'s `serialise/2`, this does **not** resolve `trace_id`
  from a thread-local — `Letflow.Api.Error` is conn-agnostic by design (see
  `docs/migration/stage-4-api-surface.md`: prefer `conn.assigns`, do not port a
  thread-local global). `Letflow.Api.Response.send_problem/2` splices
  `conn.assigns[:trace_id]` in before calling this.

  `extensions` (REQ-077 §9.6) — a `map()` of string-keyed RFC 9457 §3.2
  extension members, e.g. the `conflicts` array a promotion-conflict document
  carries — is merged into the emitted document only when it is a non-empty
  map, following the exact precedent `errors` already sets: excluded from the
  `@derive {Jason.Encoder, only: [...]}` list above (for the same "Jason does
  not omit `nil` fields" reason `errors` is excluded) and merged explicitly
  here instead, so every document with no extension members stays
  byte-identical to before this field existed.
  """
  @spec serialise(t()) :: String.t()
  def serialise(%__MODULE__{errors: nil, extensions: extensions} = problem)
      when extensions in [nil, %{}] do
    problem
    |> Map.take([:type, :title, :status, :detail, :trace_id])
    |> Jason.encode!()
  end

  def serialise(%__MODULE__{errors: nil, extensions: extensions} = problem)
      when is_map(extensions) and map_size(extensions) > 0 do
    problem
    |> Map.take([:type, :title, :status, :detail, :trace_id])
    |> Map.merge(extensions)
    |> Jason.encode!()
  end

  def serialise(%__MODULE__{errors: [_ | _] = errs, extensions: extensions} = problem)
      when extensions in [nil, %{}] do
    problem
    |> Map.take([:type, :title, :status, :detail, :trace_id])
    |> Map.put(:errors, errs)
    |> Jason.encode!()
  end

  def serialise(%__MODULE__{errors: [_ | _] = errs, extensions: extensions} = problem)
      when is_map(extensions) and map_size(extensions) > 0 do
    problem
    |> Map.take([:type, :title, :status, :detail, :trace_id])
    |> Map.put(:errors, errs)
    |> Map.merge(extensions)
    |> Jason.encode!()
  end

  @doc "HTTP 400 — Bad Request."
  @spec bad_request(String.t()) :: t()
  def bad_request(detail) do
    %__MODULE__{
      type: @problems_base <> "bad-request",
      title: "Bad Request",
      status: 400,
      detail: detail
    }
  end

  @doc """
  HTTP 401 — Unauthorized.

  The caller MUST set the `WWW-Authenticate: Bearer` header separately; this
  constructor only produces the Problem Details body.
  """
  @spec unauthorized(String.t()) :: t()
  def unauthorized(detail) do
    %__MODULE__{
      type: @problems_base <> "unauthorized",
      title: "Unauthorized",
      status: 401,
      detail: detail
    }
  end

  @doc "HTTP 403 — Forbidden."
  @spec forbidden(String.t()) :: t()
  def forbidden(detail) do
    %__MODULE__{
      type: @problems_base <> "forbidden",
      title: "Forbidden",
      status: 403,
      detail: detail
    }
  end

  @doc """
  HTTP 404 — Not Found.

  Takes no `detail` argument, per INV-5: the true-not-found body and the
  cross-tenant-probe body must be byte-identical, which is guaranteed here by
  there being exactly one code path and no varying input.
  """
  @spec not_found() :: t()
  def not_found do
    %__MODULE__{
      type: @problems_base <> "not-found",
      title: "Not Found",
      status: 404,
      detail: @not_found_detail
    }
  end

  @doc """
  HTTP 410 — Attachment Link Expired (REQ-386).

  Takes no `detail` argument, deliberately -- same INV-5 shape as
  `not_found/0`. `Letflow.Repository.AttachmentLinks.verify/3` collapses six
  structurally distinct failure causes (malformed token, bad JSON, unknown
  tenant, unresolvable/wrong-tenant signing key, signature mismatch, expiry)
  into one `{:error, :expired_or_invalid}` value, and this constructor is the
  only response ever built from it -- so a signed link that has genuinely
  expired and a token that was never validly issued (e.g. for a foreign
  tenant's attachment, or an attachment id that never existed at all)
  produce byte-identical response bodies, matching REQ-386's own AC4.
  """
  @spec attachment_link_expired() :: t()
  def attachment_link_expired do
    %__MODULE__{
      type: @problems_base <> "attachment-link-expired",
      title: "Attachment Link Expired",
      status: 410,
      detail: "This link has expired or is no longer valid. Request a new link and try again."
    }
  end

  @doc "HTTP 409 — Conflict."
  @spec conflict(String.t()) :: t()
  def conflict(detail) do
    %__MODULE__{
      type: @problems_base <> "conflict",
      title: "Conflict",
      status: 409,
      detail: detail
    }
  end

  @doc """
  HTTP 409 — Pack Is Owned by a Module (REQ-411).

  Returned when a caller posts a pack document to
  `POST /api/v1/solution-packs/install` whose `pack_id` matches the
  `pack_id` of a pack owned by a registered module in
  `Letflow.Modules.Catalog`.  The caller must install the owning module
  instead (via the module-install route).
  """
  @spec module_owned_pack() :: t()
  def module_owned_pack do
    %__MODULE__{
      type: @problems_base <> "module-owned-pack",
      title: "Pack Is Owned by a Module",
      status: 409,
      detail: "this pack is managed by a registered module; install the module instead"
    }
  end

  @doc """
  HTTP 409 — Module Has Installed Dependents (REQ-578). An uninstall was refused because active
  modules depend on the module. The body carries the constant `code` `"dependents_installed"` and
  the sorted module ids of the dependents (catalog ids of the caller's own tenant).
  """
  @spec module_dependents_installed([String.t()]) :: t()
  def module_dependents_installed(ids) when is_list(ids) do
    %__MODULE__{
      type: @problems_base <> "module-dependents-installed",
      title: "Module Has Installed Dependents",
      status: 409,
      detail: "other installed modules depend on this module; uninstall them first",
      extensions: %{"code" => "dependents_installed", "dependents" => Enum.sort(ids)}
    }
  end

  @doc """
  HTTP 409 — Module Has Open Work (REQ-627). An uninstall was refused because an active instance or a
  pending task of the module's definitions exists. Constant `code` `"open_work_exists"` and the two counts
  of the caller's own tenant; no ids.
  """
  @spec module_open_work_exists(non_neg_integer(), non_neg_integer()) :: t()
  def module_open_work_exists(open_instances, open_tasks) do
    %__MODULE__{
      type: @problems_base <> "module-open-work-exists",
      title: "Module Has Open Work",
      status: 409,
      detail: "running instances or open tasks of this module exist; finish or cancel them first",
      extensions: %{
        "code" => "open_work_exists",
        "open_instances" => open_instances,
        "open_tasks" => open_tasks
      }
    }
  end

  @doc """
  HTTP 409 — Module Upgrade Required (REQ-578). A reactivate was refused because the stored
  manifest hash is missing or differs from the compiled module. Constant `code`
  `"upgrade_required"`.
  """
  @spec module_upgrade_required() :: t()
  def module_upgrade_required do
    %__MODULE__{
      type: @problems_base <> "module-upgrade-required",
      title: "Module Upgrade Required",
      status: 409,
      detail: "the installed module differs from the current version; upgrade it instead",
      extensions: %{"code" => "upgrade_required"}
    }
  end

  @doc """
  HTTP 422 — Module Install DDL Failed (GH #2540).

  Returned by `POST /tenant/modules` and `POST /tenant/solutions` when a database
  error (a real DDL failure while promoting a column or creating an entity table)
  aborts the install. The whole install was rolled back in one transaction, so
  nothing is left behind and the call may be retried once the cause is fixed.
  The body carries the constant `code` `"module_install_ddl_failed"` and a fixed
  detail. Takes no argument, so no SQL text, schema or table name, module id or
  stack trace can reach the body (INV-8).
  """
  @spec module_install_ddl_failed() :: t()
  def module_install_ddl_failed do
    %__MODULE__{
      type: @problems_base <> "module-install-ddl-failed",
      title: "Module Install DDL Failed",
      status: 422,
      detail:
        "module installation failed because a database change could not be applied; nothing was installed",
      extensions: %{"code" => "module_install_ddl_failed"}
    }
  end

  @doc """
  HTTP 409 — Record Version Conflict (GH #2528).

  Returned when an entity record update or delete carried an
  `expected_last_event_global_seq` that no longer matches the stored row: the
  record was changed by someone else since the caller loaded it. The body
  carries the constant `code` `"record_version_conflict"` and a fixed detail.
  Takes no argument, so no record data, field value or sequence number can
  reach the body (INV-2, INV-4).
  """
  @spec record_version_conflict() :: t()
  def record_version_conflict do
    %__MODULE__{
      type: @problems_base <> "record-version-conflict",
      title: "Record Version Conflict",
      status: 409,
      detail: "the record was changed by someone else; reload it and try again",
      extensions: %{"code" => "record_version_conflict"}
    }
  end

  @doc """
  HTTP 422 — Entity Type Is Append-Only (GH #2529).

  Returned when an entity record update or delete targets an entity type whose
  current active definition declares `append_only: true` (a tenant policy that
  activating a version without the flag lifts; it is not a tamper-proof lock --
  that is `managed_by`, decision 0050 D7). 422 rather than 409 (the SPA
  reads 409 as an edit conflict) or 403 (reserved for module ownership). The
  body carries the constant `code` `"entity_append_only"` and a fixed detail.
  Takes no argument, so no entity type, record id or field value can reach the
  body (INV-2, INV-4).
  """
  @spec entity_append_only() :: t()
  def entity_append_only do
    %__MODULE__{
      type: @problems_base <> "entity-append-only",
      title: "Entity Type Is Append-Only",
      status: 422,
      detail: "records of this entity type are append-only and cannot be updated or deleted",
      extensions: %{"code" => "entity_append_only"}
    }
  end

  @doc """
  HTTP 422 — Idempotency Key Reused (GH #2543, design D6).

  Returned when an entity record command reuses an `idempotency_key` that was
  already used for a different request (another command, entity type, target
  record, field values or actor). 422 rather than 409: the SPA reads 409 as
  "reload and retry", and reloading does not fix a reused key -- the client
  must send a new one. The body carries the constant `code`
  `"idempotency_key_reuse"` and a fixed detail. Takes no argument, so no
  record id, field value, entity type or event data of the original request
  can reach the body (INV-2, INV-4).
  """
  @spec idempotency_key_reuse() :: t()
  def idempotency_key_reuse do
    %__MODULE__{
      type: @problems_base <> "idempotency-key-reuse",
      title: "Idempotency Key Reused",
      status: 422,
      detail: "this idempotency_key was already used for a different request; send a new key",
      extensions: %{"code" => "idempotency_key_reuse"}
    }
  end

  @doc """
  HTTP 403 — Entity Type Is Managed by a Module (REQ-496, decision 0050 D7, M4).

  The ONE uniform refusal for a tenant write to a module-managed entity type, on
  the generic record routes, the entity-definition routes and both
  solution-pack routes. Constant: takes no argument, so no type name, module id,
  record id, field value or append-only status can reach the body (INV-2, INV-4);
  the only per-request member is `trace_id`.
  """
  @spec entity_type_managed() :: t()
  def entity_type_managed do
    %__MODULE__{
      type: @problems_base <> "entity-type-managed",
      title: "Entity Type Is Managed by a Module",
      status: 403,
      detail:
        "this entity type is reserved for or managed by a module and cannot be changed through this route",
      extensions: %{"code" => "entity_type_managed"}
    }
  end

  @doc "HTTP 415 — Unsupported Media Type."
  @spec unsupported_media_type(String.t()) :: t()
  def unsupported_media_type(detail) do
    %__MODULE__{
      type: @problems_base <> "unsupported-media-type",
      title: "Unsupported Media Type",
      status: 415,
      detail: detail
    }
  end

  @doc """
  HTTP 413 — Content Too Large.

  PROVENANCE (historical, not current decision authority):
  Not present in `errors.zig` — R-Co's manual body-reading loop bounds reads
  itself rather than raising a typed error for "too large". Added by REQ-068
  for `Letflow.Plugs.SafeJsonParser`, the first Letflow caller that needs it
  (see `lib/letflow/design/req068-validation.md` §0.4).
  """
  @spec payload_too_large(String.t()) :: t()
  def payload_too_large(detail) do
    %__MODULE__{
      type: @problems_base <> "payload-too-large",
      title: "Content Too Large",
      status: 413,
      detail: detail
    }
  end

  @doc "HTTP 422 — Unprocessable Entity."
  @spec unprocessable(String.t()) :: t()
  def unprocessable(detail) do
    %__MODULE__{
      type: @problems_base <> "unprocessable-entity",
      title: "Unprocessable Entity",
      status: 422,
      detail: detail
    }
  end

  @doc """
  HTTP 422 — Output Refused (REQ-460, design req459 §3.2). A HUMAN_TASK
  completion was refused before any state change because its submitted output
  lacks a `required_outputs` key or carries a value a `variable_schema` rejects;
  the same request, corrected, can be resent.

  The body carries the constant `code` `"output_refused"` and two sorted,
  deduplicated lists of key NAMES (RFC 9457 §3.2 extension members). The
  constructor takes lists of names and nothing else, so no value, enum, schema
  text, id, stack, module or SQL text can reach the body (INV-2, INV-4).
  """
  @spec output_refused(missing_keys :: [String.t()], rejected_keys :: [String.t()]) :: t()
  def output_refused(missing_keys, rejected_keys)
      when is_list(missing_keys) and is_list(rejected_keys) do
    %__MODULE__{
      type: @problems_base <> "output-refused",
      title: "Output Refused",
      status: 422,
      detail: "the submitted output was refused; resend the complete output",
      extensions: %{
        "code" => "output_refused",
        "missing_keys" => missing_keys |> Enum.uniq() |> Enum.sort(),
        "rejected_keys" => rejected_keys |> Enum.uniq() |> Enum.sort()
      }
    }
  end

  @doc """
  HTTP 422 — Form Hook Refused (GH #3409, decision 0067 D8, F-3). The node's `form_validation`
  script refused the completion; nothing was written and the corrected request can be resent.

  The body carries the constant `code` `"form_hook_refused"`, the manifest's refusal code under
  `hook_code` and the `fields` entries (`field`, `code`) in the order the script returned them.
  The constructor takes a binary code and `%{field:, code:}` entries and nothing else, so no
  source, key, version, sha256 or submitted value can reach the body (INV-2, INV-4).
  """
  @spec form_hook_refused(String.t(), [%{field: String.t(), code: String.t()}]) :: t()
  def form_hook_refused(code, fields) when is_binary(code) and is_list(fields) do
    %__MODULE__{
      type: @problems_base <> "form-hook-refused",
      title: "Form Hook Refused",
      status: 422,
      detail: "the form validation refused the submitted output; correct it and resend",
      extensions: %{
        "code" => "form_hook_refused",
        "hook_code" => code,
        "fields" => Enum.map(fields, fn %{field: f, code: c} -> %{"field" => f, "code" => c} end)
      }
    }
  end

  @doc """
  HTTP 422 — a completion submitted the redaction sentinel for a restricted variable the caller
  cannot read (decision 0062 R8/R9). Nothing was written. The body carries the constant `code`
  `"redacted_value_submitted"` and the sorted key NAMES; no value, label or sentinel text.
  """
  @spec redacted_value_submitted([String.t()]) :: t()
  def redacted_value_submitted(keys) when is_list(keys) do
    %__MODULE__{
      type: @problems_base <> "redacted-value-submitted",
      title: "Redacted Value Submitted",
      status: 422,
      detail:
        "a submitted value is the redaction placeholder for a variable the caller may not read",
      extensions: %{
        "code" => "redacted_value_submitted",
        "keys" => keys |> Enum.uniq() |> Enum.sort()
      }
    }
  end

  @doc """
  HTTP 429 — Too Many Requests.

  The caller MUST set the `Retry-After` header separately; this constructor
  only produces the Problem Details body.
  """
  @spec rate_limited(String.t()) :: t()
  def rate_limited(detail) do
    %__MODULE__{
      type: @problems_base <> "rate-limited",
      title: "Too Many Requests",
      status: 429,
      detail: detail
    }
  end

  @doc """
  HTTP 500 — Internal Server Error.

  Takes no `detail` argument, per INV-4: the detail string must not vary with
  the underlying exception, so there is no parameter through which
  exception-derived text could be threaded.
  """
  @spec internal() :: t()
  def internal do
    %__MODULE__{
      type: @problems_base <> "internal-error",
      title: "Internal Server Error",
      status: 500,
      detail: @internal_error_detail
    }
  end

  @doc """
  HTTP 500 — Internal Server Error with a caller-supplied fixed detail.

  Callers pass a literal string that names no exception and no value (INV-4). Used where
  the answer must say something the generic detail cannot, such as a committed tenant
  that may exist after a later step failed (SECURITY-REVIEWER R1, F1).
  """
  @spec internal(detail :: String.t()) :: t()
  def internal(detail) when is_binary(detail) do
    %__MODULE__{
      type: @problems_base <> "internal-error",
      title: "Internal Server Error",
      status: 500,
      detail: detail
    }
  end

  @doc "HTTP 503 — Service Unavailable."
  @spec service_unavailable(String.t()) :: t()
  def service_unavailable(detail) do
    %__MODULE__{
      type: @problems_base <> "service-unavailable",
      title: "Service Unavailable",
      status: 503,
      detail: detail
    }
  end

  @doc """
  HTTP 410 — Cursor Expired. Promoted from a private literal in
  `Letflow.Routers.Tasks` (REQ-083) to this shared constructor by REQ-080,
  its second call site (`Letflow.Routers.Instances`'s `list`/`history`/
  `timeline` routes) — that module's own comment invited this promotion
  ("Promote to a shared constructor if a second call site needs one later").
  """
  @spec cursor_expired() :: t()
  def cursor_expired do
    %__MODULE__{
      type: @problems_base <> "cursor-expired",
      title: "Cursor Expired",
      status: 410,
      detail: "cursor has expired; please restart pagination"
    }
  end

  @doc """
  PROVENANCE (historical, not current decision authority):
  HTTP 422 — Empty Promotion Plan. REQ-066 §0.2 deliberately deferred this
  constructor ("PRM-01 AC3/AC4 ... is itself a separate, not-yet-landed
  Letflow requirement") — REQ-077 is that requirement. Matches
  `src/api/errors.zig:254-272`'s slug/title/status exactly.
  """
  @spec empty_promotion_plan(String.t()) :: t()
  def empty_promotion_plan(detail) do
    %__MODULE__{
      type: @problems_base <> "empty-promotion-plan",
      title: "Empty Promotion Plan",
      status: 422,
      detail: detail
    }
  end

  @doc """
  HTTP 422 — Invalid Promotion Source. Same deferred-by-REQ-066 lineage as
  `empty_promotion_plan/1` above.
  """
  @spec invalid_promotion_source(String.t()) :: t()
  def invalid_promotion_source(detail) do
    %__MODULE__{
      type: @problems_base <> "invalid-promotion-source",
      title: "Invalid Promotion Source",
      status: 422,
      detail: detail
    }
  end

  @doc """
  PROVENANCE (historical, not current decision authority):
  HTTP 409 — Promotion Conflict. A genuine addition (not REQ-066-deferred):
  R1/R7/R10's conflict response must carry the `conflicts` array
  (`promotion_review.zig:197-209`) as an RFC 9457 §3.2 extension member —
  the actionable half of the response, so a client does not have to re-fetch
  and re-diff to learn which `process_key`/version conflicted (REQ-077
  design §9.6).
  """
  @spec promotion_conflict(String.t(), [map()]) :: t()
  def promotion_conflict(detail, conflicts) when is_list(conflicts) do
    %__MODULE__{
      type: @problems_base <> "promotion-conflict",
      title: "Promotion Conflict",
      status: 409,
      detail: detail,
      extensions: %{"conflicts" => conflicts}
    }
  end

  @doc """
  HTTP 409 — Service Referenced By Active Definitions (REQ-192, design
  `lib/letflow/design/req192-service-catalog-routes.md` §11). Modeled on
  `promotion_conflict/2`'s own real RFC 9457 extensions-map shape (the one
  existing precedent in this codebase for a 409 carrying a structured id
  list), with its own accurate `type`/`title` rather than reusing
  `promotion_conflict/2` under a service-flavored `detail` string — see the
  design's "alternative considered and rejected" note.

  `definition_ids` names every ACTIVE process-definition id (across every
  tenant) still referencing the service the caller tried to delete —
  `Letflow.ServiceCatalog.delete/1`'s own
  `{:error, {:referenced_by_active_definitions, definition_ids}}` shape.
  """
  @spec service_referenced_by_active_definitions([String.t()]) :: t()
  def service_referenced_by_active_definitions(definition_ids) when is_list(definition_ids) do
    %__MODULE__{
      type: @problems_base <> "service-referenced-by-active-definitions",
      title: "Service Referenced By Active Definitions",
      status: 409,
      detail: "the service is referenced by one or more ACTIVE process definitions",
      extensions: %{"definition_ids" => definition_ids}
    }
  end

  @doc """
  HTTP 409 — Service Referenced By Active Instances (ISS-0923, design
  `lib/letflow/design/iss0923-catalog-delete-blocks-on-pinned-instances.md` §8).
  Same shape rationale as `service_referenced_by_active_definitions/1` above, for
  `Letflow.ServiceCatalog.delete/1`'s
  `{:error, {:referenced_by_active_instances, instance_refs}}` shape.

  `instance_refs` is `Letflow.ServiceCatalog.instance_refs()`: a capped, ascending
  list of opaque non-terminal instance ids plus a `truncated` flag. `detail` is a
  fixed sentence with no ids interpolated; the ids live only in the extensions map.
  """
  @spec service_referenced_by_active_instances(%{
          instance_ids: [String.t()],
          truncated: boolean()
        }) :: t()
  def service_referenced_by_active_instances(%{instance_ids: ids, truncated: truncated})
      when is_list(ids) and is_boolean(truncated) do
    %__MODULE__{
      type: @problems_base <> "service-referenced-by-active-instances",
      title: "Service Referenced By Active Instances",
      status: 409,
      detail: "the service is pinned by one or more non-terminal process instances",
      extensions: %{"instance_ids" => ids, "truncated" => truncated}
    }
  end

  @doc """
  HTTP 409 — Service Scope Narrowing Conflict (REQ-192, design §11). Same
  shape rationale as `service_referenced_by_active_definitions/1` above, for
  `Letflow.ServiceCatalog.update_scope/2`'s
  `{:error, {:referenced_by_active_definitions, conflicts}}` narrowing-path
  shape instead — `conflicts :: [Letflow.ServiceCatalog.reference_conflict()]`,
  each `%{tenant_id: ..., definition_ids: [...]}`, re-mapped to a
  string-keyed extensions map here since `Error.serialise/1`'s
  `Jason.encode!/1` call requires JSON-safe keys throughout.
  """
  @spec service_scope_narrowing_conflict([%{tenant_id: String.t(), definition_ids: [String.t()]}]) ::
          t()
  def service_scope_narrowing_conflict(conflicts) when is_list(conflicts) do
    %__MODULE__{
      type: @problems_base <> "service-scope-narrowing-conflict",
      title: "Service Scope Narrowing Conflict",
      status: 409,
      detail: "other tenants' ACTIVE process definitions still reference this service",
      extensions: %{
        "conflicts" =>
          Enum.map(conflicts, fn c ->
            %{"tenant_id" => c.tenant_id, "definition_ids" => c.definition_ids}
          end)
      }
    }
  end
end
