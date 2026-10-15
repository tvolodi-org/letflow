defmodule Letflow.Api.Context do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Tenant-scoped request context and the cross-tenant 404 mechanism — ports
  `src/api/tenant_context.zig` (104 lines), `src/api/trace_context.zig` (55
  lines), and `src/api/pipeline_context.zig` (45 lines), folded into this one
  module with no separate Letflow module for any of the three. See
  `lib/letflow/design/req072-tenant-request-context.md` for the full design;
  this moduledoc restates the parts of it that must stay visible from the
  code itself.

  ## Why one module, and why all three fold together (AC1)

  R-Co's three source files are all the same shape: a `threadlocal` global
  set once per request by request-entry middleware, read by everything
  downstream, cleared at request end. Zig has no per-request object to carry
  state on, so a thread-local stands in for one. Elixir/Plug already has that
  object — `conn` — so the threadlocal shape has no reason to exist here at
  all: **every one of the three becomes an explicit `conn.assigns` key,
  populated once, read directly off the conn by whoever needs it.**

  PROVENANCE (historical, not current decision authority):
  `pipeline_context.zig`'s one field, `pipeline_run_id`, has no current
  Letflow caller (no S1–S3 module reads or writes a pipeline-run correlation
  id yet), so there is nothing left for a `pipeline_context`-equivalent
  module to do once that field is just another `conn.assigns` key. This
  module therefore *reserves* `conn.assigns[:pipeline_run_id]` as a
  documented-but-unwritten key name, so a future caller has a fixed place to
  put it, rather than inventing a new key later. `tenant_context.zig`'s
  `StorageMode` (`LEGACY_RLS`/`SCHEMA`) enum is a deliberate non-port for the
  same "fold, don't silently drop" reasoning applied elsewhere: Letflow has
  no legacy-RLS mode (decision 0003 Dimension B — schema-per-tenant from the
  first migration), so there is no mode to track.

  ## No process dictionary, no ETS, anywhere in this module

  This module never reaches into the raw process dictionary directly (no
  `Kernel` `put`/`get` pair on `self()`'s dictionary) and never uses an
  `:ets` table for per-request context. The one place that looks
  process-dictionary-adjacent is `assign_trace_id/1`'s `Logger.metadata/1`
  call — that call is the public, idiomatic `:logger` API every Elixir/
  Phoenix app uses to correlate log lines with a request, not this module
  touching the dictionary itself. `Logger.metadata/1` happens to be
  implemented on top of the process dictionary inside `:logger` itself, but
  that is `:logger`'s own implementation detail, not a choice made here —
  this file makes no direct call of that raw `Kernel` pair anywhere. A
  future grep-based audit of this directory for that raw call shape, or for
  a direct ETS table reference, must return zero hits from this file.

  ## No function here takes a tenant/schema/prefix argument (AC6)

  Every public function in this module is enumerated below, with the
  argument that could be mistaken for a tenant-identity input and why none
  exists:

    * `assign_trace_id/1` — takes only `conn`; trace-id handling has no
      tenant dimension at all.
    * `generate_trace_id/0` — takes nothing; a pure UUID v4 helper.
    * `scoped_repo_opts/1` — takes only `conn`, and reads exactly one field
      from it, `conn.assigns[:auth_context][:tenant_id]`. There is no
      parameter slot into which a caller could pass a path/query/header
      tenant hint, so it cannot happen by mistake, not merely "by
      convention."

  No function in this module accepts a tenant id, schema name, or prefix as
  a caller-supplied argument.

  ## Why no cross-tenant existence check is added anywhere (AC7, INV-5)

  `scoped_repo_opts/1`'s `:prefix` is derived solely from the authenticated
  token (via `conn.assigns[:auth_context][:tenant_id]`), never from the
  request. A lookup for a resource belonging to another tenant therefore
  finds nothing in the caller's own schema — the resulting 404 is not a
  *deliberately suppressed* "yes, it exists, but it isn't yours" result; it
  is the **only** result the query could ever produce, because the query
  never had visibility into the other tenant's schema in the first place.

  Adding a second query that checks "does this id exist in ANY tenant's
  schema," purely to produce a different error message for that case, would:

    1. require a caller-supplied tenant/schema argument this module's own
       AC6 constraint forbids taking;
    2. run an extra query only on the cross-tenant path — exactly the
       query-count asymmetry INV-5/AC5 exist to rule out;
    3. leak, via response-time difference and/or a different error body,
       the fact that *some* tenant owns the resource — the exact signal
       INV-5 exists to prevent.

  No handler may add such a check "for a better error message." This is
  INV-5, and it is discharged once, structurally, at this module's boundary,
  for every route that composes `scoped_repo_opts/1`'s output into its own
  `Repo.*` call — not re-implemented or re-tested per route.

  ## `conn.assigns` keys this module owns

  | Key                    | Type          | Set by                    |
  |------------------------|---------------|----------------------------|
  | `:trace_id`            | `String.t()`  | `assign_trace_id/1`        |
  | `:pipeline_run_id`     | `String.t()`  | reserved, unwritten today  |

  `:auth_context` is set by `Letflow.Plugs.AuthPipeline` (REQ-071), not by
  this module — `scoped_repo_opts/1` only reads it.
  """

  import Plug.Conn

  alias Letflow.TenantProvisioning

  @trace_id_header "x-trace-id"
  @max_trace_id_bytes 256

  @doc """
  PROVENANCE (historical, not current decision authority):
  Plug-shaped `conn -> conn` function (not a full `@behaviour Plug` module —
  it takes no `opts`), mounted first in `Letflow.Plugs.ApiPipeline`'s chain,
  immediately after `Plug.Parsers` and before `Letflow.Plugs.AuthPipeline` —
  mirrors `trace.zig`'s own doc comment that trace-id assignment must run
  first, before auth and all other middleware, so even authentication
  failures are traceable.

  Behavior:

    1. Reads the `x-trace-id` request header.
    PROVENANCE (historical, not current decision authority):
    2. If present and non-empty: propagates it as-is, truncated to 256 bytes
       (`trace.zig`'s `MAX_TRACE_ID_LEN`) — no UUID-shape validation is
       performed on incoming values: a caller-supplied trace id is a
       correlation convenience, not a security-checked value, so accepting
       any non-empty string up to the length cap is deliberate, not a gap.
    3. If absent or empty: generates a fresh UUID v4 via
       `generate_trace_id/0`.
    4. Assigns `conn.assigns[:trace_id]`.
    5. Mirrors the same value into `Logger.metadata(trace_id: trace_id)`
       immediately after step 4, so every `Logger.*` call made anywhere
       later in the same process during this request automatically carries
       `trace_id`. See the moduledoc's "no process dictionary" section for
       why this does not violate this module's own no-raw-dictionary-access
       rule.
    PROVENANCE (historical, not current decision authority):
    6. Sets the `x-trace-id` response header eagerly, via
       `put_resp_header/3`, at this same point — not deferred to
       send-time the way a threadlocal-based design would need to
       (`trace.zig` writes the response header at send-time because that's
       the only point a threadlocal value is guaranteed still set). Setting
       it early is safe and simpler here: `put_resp_header/3` only stages the
       header on the conn struct, and Plug/Bandit doesn't finalize response
       headers until `send_resp/3` (or equivalent) is actually called later
       in the pipeline, so an early-set header survives unless a later plug
       explicitly overwrites it — no such later plug exists in this
       pipeline. A deliberate simplification, not an oversight.

  **Open question (OQ-1, not silently resolved):** `Logger.metadata/1` is
  per-BEAM-process. If Bandit/Plug ever handles a single HTTP request across
  more than one process (streaming, a future async-handoff pattern), the
  metadata set here would not automatically appear in a different process's
  log lines. Today's synchronous request-in-one-process model (matching
  every other plug in this pipeline) makes this a non-issue in practice, but
  it is not independently verified against Bandit's process model here.
  """
  @spec assign_trace_id(Plug.Conn.t()) :: Plug.Conn.t()
  def assign_trace_id(conn) do
    trace_id = incoming_trace_id(conn) || generate_trace_id()

    Logger.metadata(trace_id: trace_id)

    conn
    |> assign(:trace_id, trace_id)
    |> put_resp_header(@trace_id_header, trace_id)
  end

  # PROVENANCE (historical, not current decision authority):
  @doc "Pure UUID v4 helper, matching `trace.zig`'s `generateUuidV4/1` (36-char canonical form)."
  @spec generate_trace_id() :: String.t()
  def generate_trace_id, do: Ecto.UUID.generate()

  defp incoming_trace_id(conn) do
    case get_req_header(conn, @trace_id_header) do
      [value | _] when byte_size(value) > 0 -> truncate(value, @max_trace_id_bytes)
      _other -> nil
    end
  end

  defp truncate(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp truncate(value, max_bytes) do
    binary_part(value, 0, max_bytes)
  end

  @doc """
  The load-bearing scoping function (AC3, AC6) — the single mechanism every
  future S4 route uses to derive its `Repo.*` `:prefix` opt.

  Its **only** input is `conn`; the **only** field ever read from it is
  `conn.assigns[:auth_context][:tenant_id]` — never a request path, query
  string, or header value, not "read and then discarded," literally never
  touched, so there is no code path where a request-supplied tenant hint
  could win a precedence fight (INV-1).

  Returns `{:ok, prefix: schema_name}` on success — a keyword-list fragment
  meant to be spread directly into a caller's own `Repo.get(Schema, id,
  opts)` / `Repo.all(query, opts)` call, so no caller has to know or restate
  the `:prefix` key name itself.

  Returns `{:error, :missing_auth_context}` if `conn.assigns[:auth_context]`
  or its `:tenant_id` key is absent — a caller invoked this before
  `AuthPipeline` ran, or against a route that doesn't require auth. Returns
  `{:error, :invalid_tenant_id}` if `Letflow.TenantProvisioning.
  schema_name_for_tenant/1` itself returns that error tuple (mirrors
  `AuthPipeline.provision_user/3`'s handling of the same tuple).

  **Neither error case falls through to an unscoped query.** A caller
  receiving `{:error, _}` MUST NOT proceed to call `Repo.*` without a
  prefix — it must render an error response or otherwise halt the conn; this
  module does not itself decide which status code a caller maps `{:error,
  _}` to (route-specific policy, left to each route requirement — OQ-2).
  """
  @spec scoped_repo_opts(Plug.Conn.t()) ::
          {:ok, prefix: String.t()} | {:error, :missing_auth_context | :invalid_tenant_id}
  def scoped_repo_opts(conn) do
    case tenant_id_from_auth_context(conn) do
      {:ok, tenant_id} ->
        case TenantProvisioning.schema_name_for_tenant(tenant_id) do
          {:ok, schema_name} -> {:ok, prefix: schema_name}
          {:error, :invalid_tenant_id} -> {:error, :invalid_tenant_id}
        end

      :error ->
        {:error, :missing_auth_context}
    end
  end

  @doc """
  GH #2587 PR B1 (decision 0054 D4a): the activator authority of the authenticated caller, for
  a route that activates a definition (activate, version rollback, promotion apply, tenant
  promote). Built from the server-side `auth_context` ONLY; `platform_tenant?` is RECOMPUTED
  from the database-resolved tenant id (as `Letflow.Plugs.Authorize` does), never read from a
  stored flag. `nil` when the context has no user id.
  """
  @spec activator(Plug.Conn.t()) :: Letflow.Engine.EntityPort.activator() | nil
  def activator(conn) do
    case conn.assigns[:auth_context] do
      %{} = auth_context ->
        platform_tenant? =
          Letflow.PlatformTenant.platform_tenant?(Map.get(auth_context, :tenant_id))

        Letflow.Definitions.Activator.from_auth_context(auth_context, platform_tenant?)

      _no_context ->
        nil
    end
  end

  defp tenant_id_from_auth_context(conn) do
    case conn.assigns[:auth_context] do
      %{tenant_id: tenant_id} when not is_nil(tenant_id) -> {:ok, tenant_id}
      _other -> :error
    end
  end
end
