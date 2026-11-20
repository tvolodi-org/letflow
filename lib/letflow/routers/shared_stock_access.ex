defmodule Letflow.Routers.SharedStockAccess do
  @moduledoc """
  REQ-859 / GH #4572 (decision 0091 sections 6 to 9; Qoimeks parity G13 part 3): the per-tenant
  address of the old Qoimeks app, `/qoimeks/:tenant_slug`, forwarded from `Letflow.Router` outside
  `/api/v1` (it never enters `Letflow.Plugs.ApiPipeline`, so the value is never an API token).

  | Route | Answer |
  |---|---|
  | `GET /catalog` | 200 JSON object (REQ-908, the old app's shape): `skus` (sorted by code: `id, code, name, unit` (`""` when none), `location_id` and `barcode` only when present) and `locations` (sorted by code: `id, code, name`) |
  | `GET /balances[?sku_id&location_id]` | 200 JSON array of the non-zero balances sorted by place code (REQ-908): `sku_id, location_id, location_code, qty` |
  | `GET /movements[?sku_id&location_id&limit]` | 200 JSON array, newest first, `limit` 50 when missing or outside 1..500 (REQ-909, the old app's `Movement`): `id` (text), `kind` (`receipt`, `issue`, `transfer`, `adjustment`), `sku_id, sku_code, sku_name, unit, location_id, location_code, qty, operator` (`""` when none), `created_at`, `balances` (`[]` here), `to_location_id` and `to_location_code` (a transfer), `reverses`, `reversed_by` |
  | `POST /movements` | 201 one movement (the row of `GET /movements`, with `balances` after the movement: one entry per place touched) of the posted document; 200 the STORED row when the same `id` is sent again with equal data; body `kind` (`receipt`, `issue`, `transfer`, and REQ-912 `adjustment`, the count: `qty` is the counted number, 0 allowed, answered by the movement row with `qty` = the counted number when the tenant's four-eyes switch for counts is OFF, else 400 `invalid kind`; every refusal of a count is a 400 with the old server's Russian text, see `Letflow.Modules.Stock.OldAppWrites`), `sku_id`, `location_id`, `to_location_id` (transfer), `qty`, `operator` (or the `X-Operator` header), `id` (REQUIRED: the client operation id, a UUID string; missing or not a UUID is 400 `id is required`; the same `id` with other data is 409); a zero or negative `qty` is 400 `quantity must be positive` |
  | `POST /movements/:id/reverse` | 201 the reversal's own movement row, 200 its stored row for the same reversal `id` sent again; a movement already reversed under another `id` is 400 `already reversed`, a reversal is 400 `a reversal cannot be reversed; post a new operation instead` (the old server's texts, REQ-909); body `id` (REQUIRED, the reversal's own new UUID), `operator` (or `X-Operator`) |
  | `GET /codes/lookup?code=` | REQ-910, the old app's scan to find (read only, the lookup of `Letflow.Modules.Codes.resolve/2`; `code` is trimmed, the match is exact and case-sensitive): 200 `{"object_type", "object_id", "object_code", "object_name", "code"}` (`object_type` `sku` or `location`, `object_id` the integer of the catalog); 400 `{"error": "code is required", "reason": "invalid_request"}` when `code` is missing or blank; 404 `{"error": "not found", "reason": "code_not_found"}`, the one body of every other outcome (unknown, not assigned, retired, a lot, an inactive target: INV-5) |
  | `POST /api/voice` | K10 / REQ-911, the old app's microphone call (the `/api` form only; `POST /voice` is 404), over `Letflow.Modules.Stock.VoiceService.draft_audio/2` (`Letflow.Modules.Stock.OldAppVoice`): the multipart body (`audio`, `lang`) is read after authentication, capped at 10_485_760 bytes; 200 the old Draft `transcript`, `skus` and, when present, `kind` (`receipt`, `issue`, `transfer`), `location`, `to_location`, `qty` (no count by voice); refusals are the old server's texts: 400 `audio file is required (max 10 MB)`, 400 `lang must be ru or kk`, 503 and 502 with `source` `speech`, 422 `nothing was said`, 502 with `source` `llm` |
  | the same six calls with `/api` in front: `GET /api/catalog`, `GET /api/balances`, `GET /api/movements`, `POST /api/movements`, `POST /api/movements/:id/reverse`, `GET /api/codes/lookup` | REQ-907: exactly the answer of the call without `/api` (the real old app adds `/api` to every path; decision 0091 section 11c) |
  | any other method or path | 404 `{"error": "not found"}`, with or without `/api` (the code list, assign and remove, feedback and parse calls are not served) |

  Order of work for every request, and nothing else runs before it:

  1. `Letflow.Plugs.AuthAttemptLimit` in `mode: :failures` records the caller's address key.
  2. Authentication: `Authorization: Bearer <value>`; the tenant is named by the path slug and is
     proved by the slug being listed (`LETFLOW_SHARED_STOCK_ACCESS_TENANTS`), the tenant row being
     active, the stock module installed, and the value hashing to the tenant's own active
     `shared_stock_access` row. Every refusal is the SAME 401 (`unauthorized`, `invalid or expired
     bearer token`, the body of `Letflow.Plugs.AuthPipeline`) with no tenant-dependent header (INV-5).
     A presented value that fails for ANY reason spends one failure token of the caller's address
     (so a guesser cannot tell a real slug from a made-up one by when 429 starts); with the bucket
     empty the answer is the constant 429 of `AuthAttemptLimit.send_rate_limited/2`. A request with
     no Authorization header spends nothing. Known, accepted for QA: an address whose slug is not
     listed in the deployment setting is refused before any database access, so the response time
     can tell a listed slug from an unlisted one; the body, headers and 429 counting are uniform
     and slugs are not secret (tenant-config).
  3. Accepted requests are limited per credential (the `shared_stock_access` row id, not the
     address) by the `request_capacity` and `request_refill_per_sec` of `AuthAttemptLimit.config/0`:
     the over-limit answer is 429 with `retry-after`. Another tenant's credential has its own bucket.
  4. While the tenant's scope enforcement is `on` or `shadow` the shared access answers 403
     `{"error": "scope_enforcement_active"}` (decision 0091 section 9; personal accounts are not
     affected: this router is not theirs).

  The `/api` form (REQ-907) is one plug, `strip_api/2`, that runs AFTER step 4 and before `:match`: it
  removes ONE leading `api` path segment, so both forms reach the same six routes and the plugs above
  run once per request (a path with `/api` spends the same failure or request token as the plain one).
  The router declares no second set of routes. A path that is not one of the six stays 404 after
  authentication, and so does `/api/api/catalog`.

  Writes (REQ-860, `Letflow.Modules.Stock.OldAppWrites`): the body is read here, AFTER authentication,
  capped at #{8192} bytes (413 over it, 400 when it is not a JSON object); an operator name that is
  missing, blank or over 200 characters is 400 and nothing is written. The refusals are `{"error": text}`
  with the status `OldAppWrites` gives. The shared access reaches nothing else of the platform: this
  router serves six calls and no task, approval, count, import or user route: the count of REQ-912 is
  a movement post of kind `adjustment`, and the one approval the shared access completes is the approve task of
  its own count, in the same call, when the tenant's switch is OFF (`Letflow.Engine.SeparationOfDuties`).

  Reads use the tenant schema of the proved tenant only (INV-1): `Letflow.Ledger.authorize_shared_access/3`
  and `Letflow.Modules.Stock.OldAppReads` (through `Letflow.Modules.Catalog`; the code lookup needs no
  ledger authorization and reads only the codes, item and place masters of that schema). The router holds no `Repo` call. A crash in a read is a
  plain 500 `{"error": "internal error"}` with no detail (INV-8). Answers carry
  `cache-control: private, no-store`.
  """

  use Plug.Router

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Ledger
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Plugs.AuthAttemptLimit
  alias Letflow.Plugs.AuthAttemptLimit.Bucket
  alias Letflow.SharedStockAccess
  alias Letflow.TenantProvisioning

  require Logger

  @ledger "stock"
  @module "stock"

  plug(AuthAttemptLimit, mode: :failures)
  plug(:authenticate)
  plug(:strip_api)
  plug(:match)
  plug(:dispatch)

  get "/catalog" do
    case Catalog.old_app_catalog(conn.assigns.shared_access.prefix) do
      {:ok, rows} -> json(conn, 200, rows)
      {:error, _reason} -> json(conn, 500, %{error: "internal error"})
    end
  end

  get "/codes/lookup" do
    params = Plug.Conn.fetch_query_params(conn).query_params
    code_lookup(conn, params)
  end

  # K10 / REQ-911: only the `/api` form is served (the app never calls `/voice`).
  post "/voice" do
    if conn.assigns[:api_form], do: voice(conn), else: json(conn, 404, %{error: "not found"})
  end

  get "/balances" do
    read(conn, &Catalog.old_app_balances/2)
  end

  get "/movements" do
    read(conn, &Catalog.old_app_movements/2)
  end

  post "/movements" do
    write(conn, fn access, authorized, params ->
      Catalog.old_app_post(
        access.prefix,
        access.actor_id,
        authorized,
        params,
        operator_header(conn)
      )
    end)
  end

  post "/movements/:id/reverse" do
    write(conn, fn access, authorized, params ->
      Catalog.old_app_reverse(
        access.prefix,
        access.actor_id,
        authorized,
        id,
        params,
        operator_header(conn)
      )
    end)
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  # REQ-907: after authentication, the `/api` form is the plain form (one segment is removed, once).
  @doc false
  def strip_api(%Plug.Conn{path_info: ["api" | rest]} = conn, _opts),
    do: %{conn | path_info: rest} |> Plug.Conn.assign(:api_form, true)

  def strip_api(conn, _opts), do: conn

  # -- authentication -----------------------------------------------------------------------------

  @doc false
  def authenticate(conn, _opts) do
    slug = conn.script_name |> List.last()

    case bearer(conn) do
      :none ->
        unauthorized(conn)

      {:ok, value} ->
        case prove(slug, value) do
          {:ok, access} -> accept(conn, access)
          :error -> reject(conn)
        end
    end
  end

  defp bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> value] when byte_size(value) > 0 -> {:ok, value}
      _other -> :none
    end
  end

  # The tenant and its credential, or :error for every reason (the reasons never reach the caller).
  defp prove(slug, value) when is_binary(slug) do
    with true <- SharedStockAccess.enabled?(slug),
         {:ok, %Tenant{status: :active} = tenant} <- Identity.get_tenant_by_slug(slug),
         {:ok, prefix} <- TenantProvisioning.schema_name_for_tenant(tenant.id),
         true <- Installs.installed?(@module, prefix: prefix),
         {:ok, credential} <- SharedStockAccess.verify(prefix, value) do
      {:ok,
       %{
         prefix: prefix,
         tenant_id: tenant.id,
         credential_id: credential.id,
         actor_id: credential.actor_id,
         scope_enforcement: tenant.scope_enforcement
       }}
    else
      _refused -> :error
    end
  rescue
    exception ->
      # No detail: the message could carry the slug or a value.
      Logger.warning("shared_stock_access_prove_failed #{inspect(exception.__struct__)}")
      :error
  end

  defp prove(_slug, _value), do: :error

  defp reject(conn) do
    case AuthAttemptLimit.record_failure(conn) do
      {:ok, conn} -> unauthorized(conn)
      {:limited, conn} -> conn
    end
  end

  defp accept(conn, %{credential_id: id} = access) do
    {capacity, refill} = request_params()

    # The Bucket key shape is {:auth_attempt, mode, id}; the id is the credential row, not an address.
    key = {:auth_attempt, :requests, {:shared_stock_access, id}}
    now_ms = System.monotonic_time(:millisecond)

    case Bucket.consume(key, capacity, refill, now_ms) do
      :ok ->
        if access.scope_enforcement == :off do
          Plug.Conn.assign(conn, :shared_access, access)
        else
          conn |> json(403, %{error: "scope_enforcement_active"}) |> Plug.Conn.halt()
        end

      :rate_limited ->
        AuthAttemptLimit.send_rate_limited(
          conn,
          Bucket.retry_after(key, capacity, refill, now_ms)
        )
    end
  end

  defp request_params do
    config = AuthAttemptLimit.config()
    {config.request_capacity, config.request_refill_per_sec}
  end

  defp unauthorized(conn) do
    conn
    |> Letflow.Api.Response.unauthorized("invalid or expired bearer token")
    |> Plug.Conn.halt()
  end

  # -- reads --------------------------------------------------------------------------------------

  defp read(conn, fun) do
    params = Plug.Conn.fetch_query_params(conn).query_params

    with_authorized(conn, fn conn, authorized ->
      case fun.(authorized, params) do
        {:ok, rows} -> json(conn, 200, rows)
        {:error, :invalid_filter} -> json(conn, 400, %{error: "invalid filter"})
        _unavailable -> json(conn, 500, %{error: "internal error"})
      end
    end)
  end

  # REQ-910: every refusal is `{"error": text, "reason": code}` as the old server sent; a not-found
  # is one constant body (INV-5); a crash is a plain 500 with no detail (INV-8).
  defp code_lookup(conn, params) do
    case Catalog.old_app_code_lookup(conn.assigns.shared_access.prefix, params) do
      {:ok, row} ->
        json(conn, 200, row)

      {:error, :code_required} ->
        json(conn, 400, %{error: "code is required", reason: "invalid_request"})

      {:error, :not_found} ->
        json(conn, 404, %{error: "not found", reason: "code_not_found"})
    end
  rescue
    exception ->
      Logger.error("shared_stock_access_failed #{inspect(exception.__struct__)}")
      json(conn, 500, %{error: "internal error"})
  end

  # K10 / REQ-911: the multipart body is parsed here, AFTER authentication, at the old server's cap for
  # the whole body (10 << 20); an unreadable, oversized or non-multipart body is the old "audio file is
  # required" refusal. Nothing about the phrase is logged (a crash is a plain 500, INV-8).
  @max_voice_body 10_485_760

  defp voice(conn) do
    parsers = Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"], length: @max_voice_body)

    result =
      try do
        parsed = Plug.Parsers.call(conn, parsers)

        case parsed.body_params do
          %{} = params when not is_struct(params) -> {:ok, parsed, params}
          _unfetched -> {:ok, parsed, %{}}
        end
      rescue
        _unreadable in [
          Plug.Parsers.RequestTooLargeError,
          Plug.Parsers.ParseError,
          Plug.Parsers.BadEncodingError,
          Plug.Parsers.UnsupportedMediaTypeError
        ] ->
          :unreadable
      end

    case result do
      {:ok, conn, params} ->
        case Catalog.old_app_voice(conn.assigns.shared_access.prefix, params) do
          {:ok, body} -> json(conn, 200, body)
          {:error, {status, body}} -> json(conn, status, body)
        end

      :unreadable ->
        json(conn, 400, %{error: "audio file is required (max 10 MB)"})
    end
  rescue
    exception ->
      Logger.error("shared_stock_access_failed #{inspect(exception.__struct__)}")
      json(conn, 500, %{error: "internal error"})
  end

  # The ONE place the tenant-wide ledger authorization of the shared access is minted, from the proved
  # tenant row's values (a scan test pins it); reads and writes both go through it.
  defp with_authorized(conn, fun) do
    %{prefix: prefix, tenant_id: tenant_id} = conn.assigns.shared_access

    case Ledger.authorize_shared_access(prefix, tenant_id, @ledger) do
      {:ok, authorized} -> fun.(conn, authorized)
      _unavailable -> json(conn, 500, %{error: "internal error"})
    end
  rescue
    exception ->
      Logger.error("shared_stock_access_failed #{inspect(exception.__struct__)}")
      json(conn, 500, %{error: "internal error"})
  end

  # -- writes -------------------------------------------------------------------------------------

  @max_body 8192

  defp write(conn, fun) do
    with_authorized(conn, fn conn, authorized ->
      case read_json(conn) do
        {:ok, conn, params} ->
          case fun.(conn.assigns.shared_access, authorized, params) do
            {:ok, movement, :created} -> json(conn, 201, movement)
            {:ok, movement, :replayed} -> json(conn, 200, movement)
            {:error, {status, text}} -> json(conn, status, %{error: text})
          end

        {:error, conn, status, text} ->
          json(conn, status, %{error: text})
      end
    end)
  end

  # The body is read only after the credential is proved, and never beyond @max_body bytes.
  defp read_json(conn) do
    case Plug.Conn.read_body(conn, length: @max_body, read_length: @max_body) do
      {:ok, "", conn} ->
        {:ok, conn, %{}}

      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, %{} = params} -> {:ok, conn, params}
          _other -> {:error, conn, 400, "invalid body"}
        end

      {:more, _partial, conn} ->
        {:error, conn, 413, "body too large"}

      {:error, _reason} ->
        {:error, conn, 400, "invalid body"}
    end
  end

  defp operator_header(conn) do
    case Plug.Conn.get_req_header(conn, "x-operator") do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "private, no-store")
    |> Letflow.Api.Response.send_json(status, body)
  end
end
