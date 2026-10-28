defmodule Letflow.Api.Response do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  The single response contract every S4 route emits — ports
  `src/api/response.zig` (69 lines). Nothing renders a response body by hand
  once this module exists.

  ## Zig-to-Elixir translation

  PROVENANCE (historical, not current decision authority):
  `response.zig` defines a `HandlerResult` struct (`status_code`, `body`,
  `content_type` defaulting to `CONTENT_TYPE_JSON`) and returns it by value,
  because Zig has no request object to carry the result. **In Elixir the conn
  IS the result carrier**, so `HandlerResult` is not ported as a struct at all:
  every function here takes a `Plug.Conn.t()` and returns a `Plug.Conn.t()`,
  with status, body, and content type applied to the conn directly. `ok/2`,
  `created/2`, and `no_content/1` correspond to `response.zig`'s `ok`,
  `created`, and `noContent`; `send_problem/2` corresponds to
  `problemResponse/2`.

  `problemResponse/2`'s allocation-failure fallback (a hand-written literal 500
  JSON body) has no Elixir analogue and is deliberately not ported — see
  `Letflow.Api.Error`'s moduledoc.

  ## Content-Type — a deliberate divergence from R-Co

  **Success responses:** `application/json`, unchanged from R-Co.

  PROVENANCE (historical, not current decision authority):
  **Error responses:** `application/problem+json`. This diverges from R-Co:
  `response.zig`'s `problemResponse/2` never sets `content_type` on the
  `HandlerResult` it returns, so R-Co's error responses fall through to the
  struct default `CONTENT_TYPE_JSON = "application/json"` despite carrying an
  RFC 9457-shaped body. Letflow emits `application/problem+json` instead, per
  RFC 9457 §3. This is a considered divergence, documented here so it is not
  mistaken for an oversight and "corrected" back.

  Note that `Plug.Conn.put_resp_content_type/2` appends a charset, so the
  header values actually emitted on the wire are
  `application/json; charset=utf-8` and
  `application/problem+json; charset=utf-8`.

  ## Security invariants

  `not_found/1` (INV-5) and `internal_error/1` (INV-4) take **no
  detail-bearing argument** — their only parameter is the conn. There is no
  slot through which a caught exception's message, a raw Ecto/Postgrex error,
  or a stacktrace could reach the response body. Every other error helper takes
  a `detail` the handler chooses and is responsible for keeping caller-safe.

  Not a `Plug`: no `init/1`/`call/2`, no `@behaviour Plug`. Call these from
  route handlers and from plugs.
  """

  import Plug.Conn

  alias Letflow.Api.Error
  alias Letflow.Engine.EntityPort
  alias Letflow.Engine.VariableLabels
  alias Letflow.Engine.VariableMerge

  @json_content_type "application/json"
  @problem_content_type "application/problem+json"
  @separation_of_duties_body ~s({"detail":"separation of duties","status":403})
  # GH #2701 (REQ-516 S3): record events carry `field_values`, which no history item shows.
  @entity_record_event_types ["ENTITY_RECORD_CREATED", "ENTITY_RECORD_UPDATED"]

  # ── Client-visible variable and event-payload shaping (GH #2587 PR B3, CO-1, INV-2) ──

  @doc """
  The ONE helper every router uses before a process-variable map reaches a client
  (GH #2587 PR B3, decision 0054 CO-1, INV-2; GH #2616 part 2, decision 0062 R8): `variables`
  without its top-level reserved (`_sys`, `_sys.*`) keys, with each value whose labels intersect
  `hidden` replaced by the redaction placeholder. A STRIP and a redaction, not a permission gate:
  the stored projection, events and audit entries are untouched. `variable_labels` is the
  projection's (or in-memory state's) label map; `hidden` is the caller's grant-resolved set from
  `Letflow.Entities.Query.FieldGrants` (`nil` hides every labelled value). A non-map input is
  returned as `%{}` so a malformed value cannot leak.
  """
  @spec public_variables(term(), map(), MapSet.t() | nil) :: map()
  def public_variables(variables, variable_labels, hidden),
    do: VariableLabels.redact_variables(variables, variable_labels, hidden)

  @doc """
  The client-visible form of one stored instance event payload (history, GH #2587 PR B3, GH #2616
  part 2):

    * the engine-only `VariableMerge.sys_event_type/0` payload is never shown (`%{}`; history and
      timeline also exclude the row server-side);
    * the `EntityPort.applied_event_type/0` payload is reduced to `node_id`, `task_id`, `dispatch_id`,
      `lines_hash` and `lines` as `[%{"line_index", "entity_type"}]` (no record id, no event
      sequence; the hash-chained audit entry keeps them);
    * `ENTITY_RECORD_CREATED` and `ENTITY_RECORD_UPDATED` lose their `field_values` key (GH #2701,
      REQ-516 S3): the record's values are never shown by an instance history item;
    * every other payload has its variable values redacted by the labels stored on the event itself
      against `hidden` (`Letflow.Engine.VariableLabels.redact_event_payload/2`).

  The stored event is never changed; this shapes the response only.
  """
  @spec public_event_payload(String.t() | nil, term(), MapSet.t() | nil) :: term()
  def public_event_payload(event_type, payload, hidden) when is_map(payload) do
    cond do
      event_type == VariableMerge.sys_event_type() ->
        %{}

      event_type == EntityPort.applied_event_type() ->
        applied_payload(payload)

      event_type in @entity_record_event_types ->
        Map.delete(payload, "field_values")

      true ->
        VariableLabels.redact_event_payload(payload, hidden)
    end
  end

  def public_event_payload(_event_type, payload, _hidden), do: payload

  @doc """
  HTTP 422 — a completion submitted the redaction placeholder for a restricted variable the caller
  may not read (decision 0062 R8/R9). Key names only; see `Error.redacted_value_submitted/1`.
  """
  @spec redacted_value_submitted(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def redacted_value_submitted(conn, keys),
    do: send_problem(conn, Error.redacted_value_submitted(keys))

  defp applied_payload(payload) do
    lines =
      case Map.get(payload, "lines") do
        lines when is_list(lines) ->
          for %{} = line <- lines do
            %{
              "line_index" => Map.get(line, "line_index"),
              "entity_type" => Map.get(line, "entity_type")
            }
          end

        _other ->
          []
      end

    %{
      "node_id" => Map.get(payload, "node_id"),
      "task_id" => Map.get(payload, "task_id"),
      "dispatch_id" => Map.get(payload, "dispatch_id"),
      "lines_hash" => Map.get(payload, "lines_hash"),
      "lines" => lines
    }
  end

  # ── Success helpers ────────────────────────────────────────────────────────

  @doc """
  Encode `body` as JSON and send it at `status` with
  `Content-Type: application/json`.

  The shared primitive behind `ok/2` and `created/2`, and the single
  generalisation of the private `send_json/3` `Letflow.Router` used to carry.
  """
  @spec send_json(Plug.Conn.t(), 100..599, map()) :: Plug.Conn.t()
  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type(@json_content_type)
    |> send_resp(status, Jason.encode!(body))
  end

  @doc "HTTP 200 — OK, with a JSON body."
  @spec ok(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ok(conn, body), do: send_json(conn, 200, body)

  @doc "HTTP 201 — Created, with a JSON body."
  @spec created(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def created(conn, body), do: send_json(conn, 201, body)

  @doc """
  HTTP 204 — No Content.

  PROVENANCE (historical, not current decision authority):
  Takes no `body` parameter (mirroring `noContent()` in `response.zig`), so an
  accidental non-empty 204 body is impossible to pass in rather than merely
  discouraged. No `Content-Type` is set: a 204 carries no representation.
  """
  @spec no_content(Plug.Conn.t()) :: Plug.Conn.t()
  def no_content(conn), do: send_resp(conn, 204, "")

  # ── Error helpers ──────────────────────────────────────────────────────────

  @doc """
  Send an already-built `Letflow.Api.Error` problem document.

  The one primitive every per-status error helper funnels through. Resolves the
  document's `trace_id`, then sends it at the document's own status with
  `Content-Type: application/problem+json`.

  PROVENANCE (historical, not current decision authority):
  `trace_id` resolution matches `errors.zig`'s `serialise/2` precedence exactly:

    1. a non-empty `trace_id` already on the problem document wins (the
       supported explicit-override mechanism R-Co documents for tests);
    2. otherwise `conn.assigns[:trace_id]` — Letflow's conn-scoped stand-in for
       R-Co's `trace_context` thread-local;
    3. otherwise `""`.
  """
  @spec send_problem(Plug.Conn.t(), Error.t()) :: Plug.Conn.t()
  def send_problem(conn, %Error{} = problem) do
    conn |> put_problem(problem) |> send_resp()
  end

  @doc """
  Sets (does NOT send) the problem response: the same content type, status and body
  `send_problem/2` sends. For a `Plug.Conn.register_before_send/2` callback, which must replace
  the pending response without sending it (REQ-518 `Letflow.Api.Scope.Enforce` backstop).
  """
  @spec put_problem(Plug.Conn.t(), Error.t()) :: Plug.Conn.t()
  def put_problem(conn, %Error{} = problem) do
    problem = %{problem | trace_id: effective_trace_id(problem.trace_id, conn)}

    conn
    |> put_resp_content_type(@problem_content_type)
    |> resp(problem.status, Error.serialise(problem))
  end

  @doc "HTTP 400 — Bad Request."
  @spec bad_request(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def bad_request(conn, detail), do: send_problem(conn, Error.bad_request(detail))

  @doc """
  HTTP 401 — Unauthorized. Set `WWW-Authenticate` on the conn yourself before
  calling.
  """
  @spec unauthorized(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def unauthorized(conn, detail), do: send_problem(conn, Error.unauthorized(detail))

  @doc "HTTP 403 — Forbidden."
  @spec forbidden(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def forbidden(conn, detail), do: send_problem(conn, Error.forbidden(detail))

  @doc """
  HTTP 404 — Not Found.

  Takes no `detail`, per INV-5 — the cross-tenant-probe response and the
  genuine-missing-resource response are the same bytes because they are the
  same call.
  """
  @spec not_found(Plug.Conn.t()) :: Plug.Conn.t()
  def not_found(conn), do: send_problem(conn, Error.not_found())

  @doc """
  HTTP 410 — Attachment Link Expired (REQ-386). Takes no `detail`, same
  INV-5-shaped reasoning as `not_found/1` -- see
  `Letflow.Api.Error.attachment_link_expired/0`.
  """
  @spec attachment_link_expired(Plug.Conn.t()) :: Plug.Conn.t()
  def attachment_link_expired(conn), do: send_problem(conn, Error.attachment_link_expired())

  @doc "HTTP 409 — Conflict."
  @spec conflict(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def conflict(conn, detail), do: send_problem(conn, Error.conflict(detail))

  @doc "HTTP 409 — Pack Is Owned by a Module (REQ-411). See `Letflow.Api.Error.module_owned_pack/0`."
  @spec module_owned_pack(Plug.Conn.t()) :: Plug.Conn.t()
  def module_owned_pack(conn), do: send_problem(conn, Error.module_owned_pack())

  @doc "HTTP 409 — Module Has Installed Dependents (REQ-578). See `Error.module_dependents_installed/1`."
  @spec module_dependents_installed(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def module_dependents_installed(conn, ids),
    do: send_problem(conn, Error.module_dependents_installed(ids))

  @doc "HTTP 409 — Module Upgrade Required (REQ-578). See `Error.module_upgrade_required/0`."
  @spec module_upgrade_required(Plug.Conn.t()) :: Plug.Conn.t()
  def module_upgrade_required(conn), do: send_problem(conn, Error.module_upgrade_required())

  @doc "HTTP 422 — Module Install DDL Failed (GH #2540). See `Letflow.Api.Error.module_install_ddl_failed/0`."
  @spec module_install_ddl_failed(Plug.Conn.t()) :: Plug.Conn.t()
  def module_install_ddl_failed(conn), do: send_problem(conn, Error.module_install_ddl_failed())

  @doc """
  HTTP 413 — Content Too Large. See `Letflow.Api.Error.payload_too_large/1`
  (REQ-068) for why this has no R-Co source counterpart.
  """
  @spec payload_too_large(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def payload_too_large(conn, detail), do: send_problem(conn, Error.payload_too_large(detail))

  @doc "HTTP 415 — Unsupported Media Type."
  @spec unsupported_media_type(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def unsupported_media_type(conn, detail),
    do: send_problem(conn, Error.unsupported_media_type(detail))

  @doc "HTTP 422 — Unprocessable Entity."
  @spec unprocessable(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def unprocessable(conn, detail), do: send_problem(conn, Error.unprocessable(detail))

  @doc """
  HTTP 422 — Output Refused (REQ-460). Key names only; see `Error.output_refused/2`.
  """
  @spec output_refused(Plug.Conn.t(), [String.t()], [String.t()]) :: Plug.Conn.t()
  def output_refused(conn, missing_keys, rejected_keys),
    do: send_problem(conn, Error.output_refused(missing_keys, rejected_keys))

  @doc """
  HTTP 422 — Form Hook Refused (GH #3409). Codes and field names only; see `Error.form_hook_refused/2`.
  """
  @spec form_hook_refused(Plug.Conn.t(), String.t(), [%{field: String.t(), code: String.t()}]) ::
          Plug.Conn.t()
  def form_hook_refused(conn, code, fields),
    do: send_problem(conn, Error.form_hook_refused(code, fields))

  @doc """
  HTTP 422 — a definition binding a tenant script that is not runnable as bound (GH 2534 PR
  7c-1, design gh2534-7c-script-handler.md 4.5). The node id is the caller's own graph; the
  reason is a closed code. One body for every route that activates a definition (activate,
  version rollback, review promotion apply, review-free tenant promotion).
  """
  @spec script_binding_invalid(Plug.Conn.t(), String.t(), atom()) :: Plug.Conn.t()
  def script_binding_invalid(conn, node_id, reason) when is_atom(reason),
    do:
      send_json(conn, 422, %{
        "error" => "script_binding_invalid",
        "node_id" => node_id,
        "reason" => Atom.to_string(reason)
      })

  @doc """
  A declarative entity write of a HUMAN_TASK completion was refused (GH #2587 PR B2, design
  D-B.17 / section 8). ONE envelope, `{"error": "<code>", "line_index": <declared index> |
  null}`, so the bytes are a function of `(status, code, index)` alone: `write_not_permitted`
  is byte-identical for every cause (INV-5), and no field name, entity name or managed/scope
  detail can reach it. `line_index` is `null` for a contention refusal. `line_index: 20`
  with `validation_failed` means "line cap exceeded" (the first index past the 20-line cap),
  not a declared line.
  """
  @spec entity_write_refused(Plug.Conn.t(), atom(), non_neg_integer() | nil) :: Plug.Conn.t()
  def entity_write_refused(conn, code, index)
      when is_atom(code) and (is_nil(index) or is_integer(index)) do
    send_json(conn, entity_write_status(code), %{
      "error" => Atom.to_string(code),
      "line_index" => index
    })
  end

  defp entity_write_status(:write_not_permitted), do: 403
  defp entity_write_status(:record_version_conflict), do: 409
  defp entity_write_status(:entity_write_contention), do: 503
  defp entity_write_status(_validation_class), do: 422

  @doc """
  HTTP 409 -- the activator of the definition is no longer an active user, so its delegated
  entity writes cannot run (GH #2587 PR B2, decision 0054 D4a; a refusal stub). The task
  stays pending; recovery is cancelling the instance or re-activating the definition.
  """
  @spec entity_write_needs_reactivation(Plug.Conn.t()) :: Plug.Conn.t()
  def entity_write_needs_reactivation(conn),
    do: send_json(conn, 409, %{"error" => "entity_write_needs_reactivation"})

  @doc """
  HTTP 409 — the definition's recorded activator lost its authority (GH #2692, REQ-515); a new
  instance is refused before any token exists. Recovery: `POST /definitions/:id/reactivate`.
  """
  @spec definition_needs_reactivation(Plug.Conn.t()) :: Plug.Conn.t()
  def definition_needs_reactivation(conn),
    do: send_json(conn, 409, %{"error" => "definition_needs_reactivation"})

  @doc """
  HTTP 409 — `reactivate` on a definition that is not flagged (GH #2692, REQ-515).
  """
  @spec not_needs_reactivation(Plug.Conn.t()) :: Plug.Conn.t()
  def not_needs_reactivation(conn),
    do: send_json(conn, 409, %{"error" => "not_needs_reactivation"})

  @doc """
  HTTP 422 — a graph with `entity_writes` promoted by a principal who is not a user of the
  TARGET tenant (GH #2587 PR B1, REVIEWER F2). Nothing is written; the graph is created as a
  draft in the target and activated by a target-tenant principal. The body reveals only that.
  """
  @spec entity_write_activator_not_in_target_tenant(Plug.Conn.t()) :: Plug.Conn.t()
  def entity_write_activator_not_in_target_tenant(conn),
    do: send_json(conn, 422, %{"error" => "entity_write_activator_not_in_target_tenant"})

  @doc """
  HTTP 422 — a definition's `entity_writes` were refused at activation (GH #2587 PR B1, design
  gh2587-req499-pr-b-human-task-writes.md 5.3, 6.2). One body for every route that activates a
  definition (activate, version rollback, review promotion apply, review-free tenant
  promotion). `violations` are `Letflow.Definitions.entity_writes_violation()` maps: the node
  id from the caller's own graph, the declared line index and a stable code. No field name,
  entity type or value is echoed.
  """
  @spec entity_writes_invalid(Plug.Conn.t(), [map()]) :: Plug.Conn.t()
  def entity_writes_invalid(conn, violations) when is_list(violations),
    do:
      send_json(conn, 422, %{
        "error" => "entity_writes_invalid",
        "violations" =>
          Enum.map(violations, fn %{node_id: node_id, index: index, code: code} ->
            %{"node_id" => node_id, "index" => index, "code" => Atom.to_string(code)}
          end)
      })

  @doc """
  HTTP 422 — a service-catalog `endpoint_url` references the reserved engine variable
  namespace (GH #2623). The body echoes neither the URL nor the matched name.
  """
  @spec endpoint_url_reserved_variable(Plug.Conn.t()) :: Plug.Conn.t()
  def endpoint_url_reserved_variable(conn),
    do:
      send_json(conn, 422, %{
        "error" => "endpoint_url_reserved_variable",
        "field" => "endpoint_url"
      })

  @doc """
  HTTP 422 — the graph names the reserved engine namespace (GH #2587 PR A1b, design
  gh2587-req499-pr-a-prerequisites.md 2A.4). `references` are
  `Letflow.Definitions.ReservedReferences.reserved_reference()` maps; every echoed value comes
  from the caller's own graph (or a property name of a script the same tenant published), never
  a variable value. One body for every route that activates a definition.
  """
  @spec expression_references_reserved_variable(Plug.Conn.t(), [map()]) :: Plug.Conn.t()
  def expression_references_reserved_variable(conn, references) when is_list(references),
    do:
      send_json(conn, 422, %{
        "error" => "expression_references_reserved_variable",
        "references" => Enum.map(references, &reserved_reference_map/1)
      })

  defp reserved_reference_map(%{
         element: element,
         id: id,
         location: location,
         field: field,
         name: name
       }),
       do: %{
         "element" => Atom.to_string(element),
         "id" => id,
         "location" => Atom.to_string(location),
         "field" => field,
         "name" => name
       }

  @doc """
  HTTP 403 — Separation of Duties (REQ-463). A constant two-member body
  (`{"detail":"separation of duties","status":403}`): no trace_id, type, title,
  node id, user id or name, so every cause answers byte-identically (design
  req459 section 4.2). Deliberately bypasses `send_problem/2`.
  """
  @spec separation_of_duties(Plug.Conn.t()) :: Plug.Conn.t()
  def separation_of_duties(conn) do
    conn
    |> put_resp_content_type(@problem_content_type)
    |> send_resp(403, @separation_of_duties_body)
  end

  @doc """
  HTTP 429 — Too Many Requests. Set `Retry-After` on the conn yourself before
  calling.
  """
  @spec rate_limited(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def rate_limited(conn, detail), do: send_problem(conn, Error.rate_limited(detail))

  @doc """
  HTTP 500 — Internal Server Error.

  Takes no `detail`, per INV-4 — the body cannot vary with the underlying
  exception because nothing about the exception can be passed in.
  """
  @spec internal_error(Plug.Conn.t()) :: Plug.Conn.t()
  def internal_error(conn), do: send_problem(conn, Error.internal())

  @doc """
  HTTP 500 — Internal Server Error with a fixed, caller-supplied detail (a literal; see
  `Letflow.Api.Error.internal/1`).
  """
  @spec internal_error(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def internal_error(conn, detail), do: send_problem(conn, Error.internal(detail))

  @doc "HTTP 503 — Service Unavailable."
  @spec service_unavailable(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def service_unavailable(conn, detail), do: send_problem(conn, Error.service_unavailable(detail))

  # See send_problem/2's doc for the precedence this implements.
  @spec effective_trace_id(String.t(), Plug.Conn.t()) :: String.t()
  defp effective_trace_id("", conn), do: conn.assigns[:trace_id] || ""
  defp effective_trace_id(trace_id, _conn) when is_binary(trace_id), do: trace_id
end
