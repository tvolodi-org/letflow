defmodule Letflow.Support.ScopeWritesFixture do
  @moduledoc """
  Test-only helpers shared by the REQ-518 / GH #2535 slice 2c-ii tests (404 equivalence and
  writes; design `lib/letflow/design/req518-compiler-scope-filter.md` section 10.2; spec
  `test/specs/REQ-518-2c-ii.md`).

  `provision!/1` builds ONE dedicated provisioned OIDC tenant (the `fixture_scoped` module
  installed through `Letflow.Support.ScopeSetFixture`, the nine seeded `scoped_item` records,
  the stored mode `on`) and ONE real user whose `TENANT_ADMIN` role is held ONLY at the subtree
  `a` (allowed set: `sf-a`, `sf-a1`, `sf-a2x`; `sf-a2` and `sf-a3` are retired). Requests go
  through the FULL `Letflow.Router` (real `AuthPipeline`, `Authorize`, `Enforce`, the router),
  either as that scoped OIDC user (`request/4`, `multipart/3`) or as a tenant-wide API token
  (`admin_request/4`).

  Callers are `async: false`: a committed provisioned tenant, DDL-free but cross-connection
  locks, a VM-global `:oidc` config swap and VM-global telemetry handlers.
  """

  import ExUnit.Assertions
  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Identity.RoleScopeGrant
  alias Letflow.Oidc.ConfigurableTokenVerifierDouble
  alias Letflow.Repo
  alias Letflow.Repository.EntityAttachments
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.TokenMintFixture

  @role "TENANT_ADMIN"
  @boundary "r518w2ciiboundary"
  @volatile_headers ~w(x-trace-id)
  @not_found_event [:letflow, :scope, :not_found]

  # The counted tables a write route could touch.
  @write_tables ~w(entity_record_latest events event_idempotency entity_record_attachments repository_artifacts)

  @doc "The role the scoped user holds."
  @spec role() :: String.t()
  def role, do: @role

  @doc """
  The provisioned tenant, the seeded items (`fx.items`, by node key), the scoped OIDC user
  (`fx.user_id`, TENANT_ADMIN at node `a` only) and the stored mode `on`.
  """
  @spec provision!(String.t()) :: map()
  def provision!(slug_prefix) do
    original = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(original, :token_verifier, ConfigurableTokenVerifierDouble)
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:letflow, :oidc, original) end)

    realm = Letflow.TenantSlugFixture.unique_realm(slug_prefix)
    fx = F.provision!(slug_prefix, oidc_mode: :enabled, idp_realm_id: realm)
    fx = Map.put(fx, :realm, realm)
    items = F.seed_items!(fx)

    # the first request JIT-provisions the OIDC user; then the role is held ONLY at node a
    first = request(fx, :get, "/api/v1/instances", nil)
    assert first.status in [200, 403]
    user_id = first.assigns.auth_context.user_id
    schema = fx.schema_name
    TokenMintFixture.grant_roles!(schema, user_id, [@role])
    group = RSG.group_of!(schema, @role)
    _removed = RSG.raw_delete_rows!(schema, group, @role)
    :ok = RSG.raw_user_row!(schema, user_id, @role, F.nodes().a)
    :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)

    fx |> Map.put(:items, items) |> Map.put(:user_id, user_id)
  end

  @doc """
  Replaces the user's grant rows: `{:node, key}` one scoped row, `:tenant_wide` one tenant-wide
  row, `:none` no row at all (revocation).
  """
  @spec set_grant!(map(), {:node, atom()} | :tenant_wide | :none) :: :ok
  def set_grant!(fx, spec) do
    {_n, _} =
      Repo.delete_all(
        from(g in RoleScopeGrant,
          where: g.principal_type == :user and g.principal_id == ^fx.user_id and g.role == @role
        ),
        prefix: fx.schema_name
      )

    case spec do
      {:node, key} ->
        RSG.raw_user_row!(fx.schema_name, fx.user_id, @role, Map.fetch!(F.nodes(), key))

      :tenant_wide ->
        RSG.raw_user_row!(fx.schema_name, fx.user_id, @role, nil)

      :none ->
        :ok
    end
  end

  # ---- requests ----------------------------------------------------------------------------

  @doc "A JSON request as the scoped OIDC user through the full router."
  @spec request(map(), atom(), String.t(), term()) :: Plug.Conn.t()
  def request(fx, method, path, body) do
    fx
    |> json_conn(method, path, body)
    |> put_req_header("authorization", "Bearer realm-token:" <> fx.realm)
    |> dispatch()
  end

  @doc "A raw-body request (the body string is sent as given) as the scoped OIDC user."
  @spec raw_request(map(), atom(), String.t(), String.t()) :: Plug.Conn.t()
  def raw_request(fx, method, path, raw_body) do
    method
    |> conn(path, raw_body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer realm-token:" <> fx.realm)
    |> dispatch()
  end

  @doc "A JSON request with a tenant-wide TENANT_ADMIN API token (scope `:all`)."
  @spec admin_request(map(), atom(), String.t(), term()) :: Plug.Conn.t()
  def admin_request(fx, method, path, body) do
    token = Map.get_lazy(fx, :admin_token, fn -> Fixture.mint_token!(fx, [@role]) end)

    fx
    |> json_conn(method, path, body)
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("x-tenant-slug", fx.tenant.slug)
    |> dispatch()
  end

  @doc "A raw-body request with the tenant-wide admin API token."
  @spec raw_admin_request(map(), atom(), String.t(), String.t()) :: Plug.Conn.t()
  def raw_admin_request(fx, method, path, raw_body) do
    token = Map.get_lazy(fx, :admin_token, fn -> Fixture.mint_token!(fx, [@role]) end)

    method
    |> conn(path, raw_body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("x-tenant-slug", fx.tenant.slug)
    |> dispatch()
  end

  @doc "A multipart upload (`parts`: `:file`, `:no_file`) as the scoped OIDC user."
  @spec multipart(map(), String.t(), :file | :no_file) :: Plug.Conn.t()
  def multipart(fx, path, parts) do
    name = if parts == :file, do: "file", else: "notfile"

    body =
      "--#{@boundary}\r\n" <>
        "Content-Disposition: form-data; name=\"#{name}\"; filename=\"note.txt\"\r\n" <>
        "Content-Type: text/plain\r\n\r\n" <>
        "UPLOADED-BYTES\r\n--#{@boundary}--\r\n"

    :post
    |> conn(path, body)
    |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
    |> put_req_header("authorization", "Bearer realm-token:" <> fx.realm)
    |> dispatch()
  end

  defp json_conn(_fx, method, path, nil), do: conn(method, path)

  defp json_conn(_fx, method, path, body) do
    method
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  @doc "The status, the sorted header list without `x-trace-id`, and the body without `trace_id`."
  @spec norm(Plug.Conn.t()) :: {non_neg_integer(), [{String.t(), String.t()}], term()}
  def norm(conn) do
    headers =
      conn.resp_headers
      |> Enum.reject(fn {name, _} -> name in @volatile_headers end)
      |> Enum.sort()

    body =
      case Jason.decode(conn.resp_body) do
        {:ok, %{} = map} -> Map.delete(map, "trace_id")
        _ -> conn.resp_body
      end

    {conn.status, headers, body}
  end

  @doc "The decoded JSON body."
  @spec json(Plug.Conn.t()) :: term()
  def json(conn), do: Jason.decode!(conn.resp_body)

  # ---- paths -------------------------------------------------------------------------------

  @spec records_path(String.t(), String.t() | nil) :: String.t()
  def records_path(type, nil), do: "/api/v1/entities/records/#{type}"
  def records_path(type, id), do: "/api/v1/entities/records/#{type}/#{id}"

  @spec import_path(String.t()) :: String.t()
  def import_path(type), do: "/api/v1/entities/records/#{type}/import"

  @spec attachments_path(String.t(), String.t()) :: String.t()
  def attachments_path(type, id), do: records_path(type, id) <> "/attachments"

  @spec item_path(String.t(), String.t(), String.t()) :: String.t()
  def item_path(type, id, attachment_id), do: attachments_path(type, id) <> "/#{attachment_id}"

  @doc "A PUT/POST body for a `scoped_item` (`:omit` leaves the scope field out)."
  @spec item_body(String.t() | nil | :omit | term(), keyword()) :: map()
  def item_body(scope_node, extra \\ []) do
    values = %{"name" => Keyword.get(extra, :name, "written"), "amount" => 1}
    values = if scope_node == :omit, do: values, else: Map.put(values, "scope_node", scope_node)
    body = %{"field_values" => values}

    case Keyword.get(extra, :key) do
      nil -> body
      key -> Map.put(body, "idempotency_key", key)
    end
  end

  @doc "An import document for `type` holding one entry per `scope_nodes` element."
  @spec import_body(String.t(), [term()]) :: map()
  def import_body(type, scope_nodes) do
    records =
      scope_nodes
      |> Enum.with_index()
      |> Enum.map(fn {node, i} ->
        values = %{"name" => "imp-#{i}", "amount" => i}
        values = if node == :omit, do: values, else: Map.put(values, "scope_node", node)
        %{"record_id" => "src-#{i}", "field_values" => values}
      end)

    %{
      "record_export_schema_version" => "entities/record-export/v1",
      "entity_type" => type,
      "records" => records
    }
  end

  # ---- database observation ------------------------------------------------------------------

  @doc "Row counts of the tables a write route could touch (committed state of the tenant)."
  @spec counts(map()) :: %{String.t() => non_neg_integer()}
  def counts(fx) do
    for table <- @write_tables, into: %{} do
      {table, Repo.aggregate(table, :count, prefix: fx.schema_name)}
    end
  end

  @doc "The latest `field_values` of a record (nil when there is no row)."
  @spec stored_values(map(), String.t(), String.t()) :: map() | nil
  def stored_values(fx, type, record_id) do
    case Repo.one(
           from(l in Letflow.Entities.Record.Latest,
             where: l.entity_type == ^type and l.record_id == ^record_id
           ),
           prefix: fx.schema_name
         ) do
      nil -> nil
      row -> row.field_values
    end
  end

  @doc "The stored latest row of a record (nil when there is none)."
  @spec stored_row(map(), String.t(), String.t()) :: Letflow.Entities.Record.Latest.t() | nil
  def stored_row(fx, type, record_id) do
    Repo.one(
      from(l in Letflow.Entities.Record.Latest,
        where: l.entity_type == ^type and l.record_id == ^record_id
      ),
      prefix: fx.schema_name
    )
  end

  @doc "The SQL text of every statement `fun` ran (in order), and its result."
  @spec statements((-> term())) :: {term(), [String.t()]}
  def statements(fun) do
    {result, queries} = Fixture.capture_repo_queries(fun)
    {result, Enum.map(queries, & &1.query)}
  end

  @doc "Creates a record attachment directly (the repository, no HTTP). Returns the attachment."
  @spec attach!(map(), String.t(), String.t()) :: map()
  def attach!(fx, type, record_id) do
    {:ok, attachment} =
      EntityAttachments.upload(
        %{
          entity_type: type,
          record_id: record_id,
          raw_bytes: "ATTACHED-BYTES",
          file_name: "att.txt",
          content_type: "text/plain",
          uploaded_by: fx.user_id,
          description: nil
        },
        prefix: fx.schema_name
      )

    attachment
  end

  # ---- telemetry -----------------------------------------------------------------------------

  @doc "Attaches a collector of `[:letflow, :scope, :not_found]`; returns the reference."
  @spec attach_not_found!() :: reference()
  def attach_not_found! do
    ref = make_ref()
    id = {__MODULE__, ref}

    :ok =
      :telemetry.attach(id, @not_found_event, &__MODULE__.handle_event/4, {self(), ref})

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
    ref
  end

  @doc false
  @spec handle_event([atom()], map(), map(), {pid(), reference()}) :: :ok
  def handle_event(_event, measurements, metadata, {pid, ref}) do
    send(pid, {:not_found, ref, measurements, metadata})
    :ok
  end

  @doc "Every collected `{measurements, metadata}` so far (drains the mailbox)."
  @spec drain_not_found(reference()) :: [{map(), map()}]
  def drain_not_found(ref), do: drain(ref, [])

  defp drain(ref, acc) do
    receive do
      {:not_found, ^ref, measurements, metadata} -> drain(ref, [{measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
