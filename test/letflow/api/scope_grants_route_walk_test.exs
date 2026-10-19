defmodule Letflow.Api.ScopeGrantsRouteWalkTest do
  @moduledoc """
  REQ-497 PR 1b, AC15 and N4 (decision 0051 Stage-1 cut: no route creates a scoped
  `role_scope_grants` row; design `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md`
  section 9, tests T-RW1..T-RW4; spec `test/specs/REQ-497-1b.md`).

    * T-RW1 static writer pin over the AST of every `lib/**/*.ex`: only
      `lib/letflow/identity/role_scope_grants.ex` writes the table; its public function set is
      exactly the six 1a writers plus the read functions; no writer takes a `scope_node_id`
      and none writes `tenant_wide: false`.
    * T-RW2 dynamic walk: in dedicated tenants a tripwire trigger fires on any write whose NEW
      or OLD row is scoped. Its hit counter is a SEQUENCE (`nextval` survives the rollback the
      trigger's own exception causes), so a route that swallowed the error is still caught.
      Every `{method, path, key}` of every router exporting `__authz_routes__/0` is called
      once with an empty body as a TENANT_ADMIN of the tenant (and, for platform-scope keys,
      as a platform-tenant PLATFORM_ADMIN); the FULL row set (`row_to_json` of every column) of
      both schemas must be byte-identical before and after each call. The identity/onboarding
      binding and membership routes and `PUT /tenant/scope-enforcement` are then called with a
      VALID body, each with its exact expected delta (the 1a writer cascades: a kind change
      removes or re-creates exactly the binding's tenant-wide group row, a rebind moves it, a
      group delete removes exactly that group's rows); every row not in the delta keeps every
      column.
    * T-RW3 (N4): `POST /tenant/modules` (the route reaching `Modules.Installs` ->
      `SolutionPack.install` -> `Modules.EntityActivation`), `POST /entities/definitions` and
      `POST /entities/definitions/:name/activate` with valid bodies change no grant row, and a
      create with a managed name keeps the #2530 refusal (0050 D7).
    * T-RW4 (N4): AST pin that tenant provisioning/onboarding call no definition writer and no
      pack install and write no `EntityDefinition`; behaviourally, provisioning a new tenant
      leaves an installed managed type's `managed_by` and name unchanged.

  `async: false`: real provisioned tenants, DDL (triggers), the VM-global platform pin.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Api.Error
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Support.PendingAdminHelper, as: H
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @fixed_id "00000000-0000-4000-8000-000000000497"
  @trace "req497-route-walk-trace"
  @grants_module "lib/letflow/identity/role_scope_grants.ex"

  # --- tripwire ----------------------------------------------------------------------------------

  defp install_tripwire!(schema) do
    Repo.query!(~s|CREATE SEQUENCE "#{schema}".req497_rw_tripwire_seq|)

    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".req497_rw_tripwire() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|DECLARE hit boolean := false; BEGIN | <>
        ~s|IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.tenant_wide = false THEN hit := true; END IF; | <>
        ~s|IF TG_OP IN ('UPDATE', 'DELETE') AND OLD.tenant_wide = false THEN hit := true; END IF; | <>
        ~s|IF hit THEN PERFORM nextval('"#{schema}".req497_rw_tripwire_seq'); | <>
        ~s|RAISE EXCEPTION 'REQ-497 route walk: scoped role_scope_grants write'; END IF; | <>
        ~s|IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER req497_rw_tripwire BEFORE INSERT OR UPDATE OR DELETE | <>
        ~s|ON "#{schema}".role_scope_grants FOR EACH ROW | <>
        ~s|EXECUTE FUNCTION "#{schema}".req497_rw_tripwire()|
    )

    :ok
  end

  defp tripwire_hits(schema) do
    %{rows: [[last, called?]]} =
      Repo.query!(~s|SELECT last_value, is_called FROM "#{schema}".req497_rw_tripwire_seq|)

    if called?, do: last, else: 0
  end

  # Proves the tripwire counts a scoped write even though the write itself is rolled back.
  defp prove_tripwire!(schema) do
    group = RSG.fresh_group!(schema)

    assert_raise Postgrex.Error, fn ->
      RSG.raw_scoped_row!(schema, group.id, "TASK_WORKER", "req497-rw-node")
    end

    assert tripwire_hits(schema) == 1

    assert Repo.query!(
             ~s|SELECT count(*) FROM "#{schema}".role_scope_grants WHERE NOT tenant_wide|
           ).rows ==
             [[0]]
  end

  # --- row sets ----------------------------------------------------------------------------------

  # Every column of every row, as Postgres renders it, keyed by the logical grant key.
  defp snapshot(schema) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT row_to_json(g)::text FROM "#{schema}".role_scope_grants g ORDER BY g.id|
      )

    Map.new(rows, fn [json] ->
      row = Jason.decode!(json)
      {{row["principal_type"], row["principal_id"], row["role"], row["scope_node_id"]}, json}
    end)
  end

  # The scoped (tenant_wide = false) rows only: the walk of T-RW2c.
  defp scoped_snapshot(schema) do
    schema
    |> snapshot()
    |> Enum.reject(fn {_key, json} -> Jason.decode!(json)["tenant_wide"] end)
    |> Map.new()
  end

  # `{inspect(router), method, path}` of every call that changed a scoped row (REQ-517 AC 15).
  defp scoped_mismatches(schema, calls, ctx) do
    Enum.flat_map(calls, fn {router, method, path} ->
      before = scoped_snapshot(schema)
      _outcome = walk_call(router, method, path, ctx)

      if scoped_snapshot(schema) == before,
        do: [],
        else: [{inspect(router), method, path}]
    end)
  end

  defp tw_key(group_id, role), do: {"group", group_id, role, nil}

  # `after` equals `before` except: `removed` keys are gone, `added` keys are new tenant-wide
  # group rows. Every other row keeps every column. No scoped row, no user row.
  defp assert_delta!(schema, before, removed, added, label) do
    after_rows = snapshot(schema)

    for key <- removed,
        do: assert(Map.has_key?(before, key), "#{label}: #{inspect(key)} not before")

    for key <- added do
      assert Map.has_key?(after_rows, key), "#{label}: #{inspect(key)} not after"
      refute Map.has_key?(before, key), "#{label}: #{inspect(key)} already before"
      assert Jason.decode!(after_rows[key])["tenant_wide"] == true
    end

    assert Map.drop(after_rows, added) == Map.drop(before, removed), label

    assert Enum.all?(after_rows, fn {_key, json} -> Jason.decode!(json)["tenant_wide"] end),
           label

    assert RoleScopeGrants.user_row_count(schema) == 0, label
    after_rows
  end

  # --- requests ----------------------------------------------------------------------------------

  defp concrete(path) do
    path
    |> String.split("/")
    |> Enum.map(fn
      ":" <> _param -> @fixed_id
      "*" <> _glob -> "req497-walk"
      segment -> segment
    end)
    |> Enum.join("/")
  end

  defp request(router, method, path, auth_context, body) do
    conn = Plug.Test.conn(method, path)

    %{conn | body_params: body}
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, auth_context)
    |> assign(:trace_id, @trace)
    |> router.call(router.init([]))
  end

  # A route may raise or exit on an empty body; that is not what this test measures (the row
  # set and the tripwire are).
  defp walk_call(router, method, path, auth_context) do
    request(router, method, concrete(path), auth_context, %{})
    :ok
  rescue
    _exception -> :raised
  catch
    _kind, _reason -> :exited
  end

  defp routers do
    {:ok, modules} = :application.get_key(:letflow, :modules)

    modules
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :__authz_routes__, 0)))
    |> Enum.sort()
  end

  defp platform_key?(key) do
    Authorization.permission_scope(Authorization.required_permission(key)) == :platform
  rescue
    _no_mapping -> false
  end

  defp oidc_context(user_id, tenant_id, roles),
    do: %{user_id: user_id, tenant_id: tenant_id, roles: roles, credential: :oidc}

  defp walk_world! do
    world = H.world!()
    install_tripwire!(world.tenant.schema_name)
    install_tripwire!(world.platform.schema_name)
    prove_tripwire!(world.tenant.schema_name)

    ta = TokenMintFixture.role_holder!(world.tenant.schema_name, ["TENANT_ADMIN"])

    %{
      world: world,
      ta: ta,
      ta_ctx: oidc_context(ta.id, world.tenant.tenant_id, ["TENANT_ADMIN"]),
      pa_ctx: oidc_context(world.operator_id, world.platform.tenant_id, ["PLATFORM_ADMIN"])
    }
  end

  # --- AST helpers (T-RW1, T-RW4) ----------------------------------------------------------

  @write_fns [
    :insert,
    :insert!,
    :insert_all,
    :update,
    :update!,
    :update_all,
    :delete,
    :delete!,
    :delete_all,
    :insert_or_update,
    :insert_or_update!
  ]

  defp lib_files, do: "lib/**/*.ex" |> Path.wildcard() |> Enum.sort()

  defp parse(path), do: path |> File.read!() |> Code.string_to_quoted!(file: path)

  defp function_bodies(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _, [_head, _body]} = node, acc when kind in [:def, :defp] -> {node, [node | acc]}
        node, acc -> {node, acc}
      end)

    acc
  end

  # The function name of a `def` / `defp` head (a head with a guard wraps the call in :when).
  defp head_name({:when, _, [call, _guard]}), do: head_name(call)
  defp head_name({name, _, _args}) when is_atom(name), do: name

  defp any_node?(ast, pred) do
    {_ast, found?} = Macro.prewalk(ast, false, fn node, acc -> {node, acc or pred.(node)} end)
    found?
  end

  # The table name as a whole identifier (not e.g. a migration file name containing it).
  defp table_literal?(bin),
    do: Regex.match?(~r/(?<![A-Za-z0-9_])role_scope_grants(?![A-Za-z0-9_])/, bin)

  defp names_grant_table?(node) do
    case node do
      {:__aliases__, _, segments} -> List.last(segments) == :RoleScopeGrant
      bin when is_binary(bin) -> table_literal?(bin)
      _other -> false
    end
  end

  # Repo.<write>, repo.<write> (an Ecto.Multi.run callback) or Multi.<write>.
  defp write_call?(node) do
    case node do
      {{:., _, [{:__aliases__, _, segments}, fun]}, _, _args} ->
        fun in @write_fns and List.last(segments) in [:Repo, :Multi]

      {{:., _, [{var, _, context}, fun]}, _, _args} when is_atom(var) and is_atom(context) ->
        fun in @write_fns

      _other ->
        false
    end
  end

  defp binaries(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        bin, acc when is_binary(bin) -> {bin, [bin | acc]}
        node, acc -> {node, acc}
      end)

    acc |> Enum.reverse() |> Enum.join(" ")
  end

  defp raw_sql_write?(node) do
    case node do
      {{:., _, [{:__aliases__, _, segments}, fun]}, _, args}
      when fun in [:query, :query!] and is_list(args) ->
        List.last(segments) == :Repo and
          Regex.match?(
            ~r/(insert\s+into|update|delete\s+from|truncate)[^;]*role_scope_grants/is,
            binaries(args)
          )

      _other ->
        false
    end
  end

  defp writes_grants?(fun_ast) do
    (any_node?(fun_ast, &names_grant_table?/1) and any_node?(fun_ast, &write_call?/1)) or
      any_node?(fun_ast, &raw_sql_write?/1)
  end

  # --- N4 helpers (T-RW3, T-RW4) -----------------------------------------------------------

  defp definition_body(name) do
    %{
      "name" => name,
      "display_name" => "REQ-497 route walk",
      "fields" => [%{"name" => "name", "type" => "string", "required" => true}]
    }
  end

  defp managed_types(schema) do
    Repo.all(
      from(d in EntityDefinition,
        where: not is_nil(d.managed_by),
        select: {d.name, d.managed_by},
        distinct: true,
        order_by: [d.name, d.managed_by]
      ),
      prefix: schema
    )
  end

  # ===========================================================================================
  describe "T-RW1 static writer pin" do
    test "T-RW1a only role_scope_grants.ex has a function that writes the table (schema alias, literal or raw SQL)" do
      files = lib_files()
      assert @grants_module in files
      assert length(files) > 100

      writers =
        for path <- files,
            path |> parse() |> function_bodies() |> Enum.any?(&writes_grants?/1),
            do: path

      assert writers == [@grants_module]
    end

    test "T-RW1b RoleScopeGrants' public functions are exactly the six 1a writers, the REQ-517 row writers and the readers" do
      Code.ensure_loaded!(RoleScopeGrants)

      assert Enum.sort(RoleScopeGrants.__info__(:functions)) ==
               Enum.sort(
                 # the six 1a writers
                 # REQ-517 PR 2a: the four row writers behind Letflow.Identity.ScopedGrants
                 # read-only
                 # REQ-517 PR 2a readers
                 [
                   reconcile_binding!: 3,
                   ensure_tenant_wide_group_row!: 3,
                   repair_group_row!: 3,
                   remove_group_rows!: 3,
                   move_group_rows!: 4,
                   delete_group_principal_rows!: 2
                 ] ++
                   [
                     insert_scoped: 5,
                     insert_tenant_wide: 4,
                     delete_row!: 2,
                     delete_scoped_rows!: 4
                   ] ++
                   [
                     bindings_without_row: 1,
                     bindings_without_row_count: 1,
                     orphan_group_rows: 1,
                     user_row_count: 1,
                     applicable_rows_for_user: 2
                   ] ++
                   [
                     get_row: 2,
                     rows_for: 4,
                     references_node?: 2,
                     list_page: 4,
                     effective?: 4
                   ]
               )
    end

    test "T-RW1c only insert_scoped takes a scope_node_id and only insert_scoped writes tenant_wide: false (REQ-517 narrowing of the stage-1 rule)" do
      ast = parse(@grants_module)

      defs =
        for {kind, _, [head, _body]} = node <- function_bodies(ast), kind in [:def, :defp] do
          {kind, head_name(head), head, node}
        end

      assert defs != []

      takers =
        for {:def, name, head, _node} <- defs,
            any_node?(head, fn
              {:scope_node_id, _, context} when is_atom(context) -> true
              _other -> false
            end),
            uniq: true,
            do: name

      assert takers == [:insert_scoped],
             "public functions taking scope_node_id: #{inspect(takers)}"

      false_writers =
        for {_kind, name, _head, node} <- defs,
            any_node?(node, &(&1 == {:tenant_wide, false})),
            uniq: true,
            do: name

      assert false_writers == [:insert_scoped],
             "functions naming tenant_wide: false: #{inspect(false_writers)}"
    end
  end

  # ===========================================================================================
  describe "T-RW2 dynamic walk" do
    test "T-RW2a every authz route of every router, empty body, leaves the full row set of both schemas identical and the tripwire untouched" do
      %{world: world, ta_ctx: ta_ctx, pa_ctx: pa_ctx} = walk_world!()
      tenant = world.tenant.schema_name
      platform = world.platform.schema_name

      routes =
        for router <- routers(),
            {method, path, key} <- router.__authz_routes__(),
            do: {router, method, path, key}

      assert length(routes) > 100, "the walk cannot pass vacuously"

      calls =
        Enum.flat_map(routes, fn {router, method, path, key} ->
          tenant_call = [{router, method, path, key, :tenant_admin, ta_ctx}]

          if platform_key?(key),
            do: tenant_call ++ [{router, method, path, key, :platform_admin, pa_ctx}],
            else: tenant_call
        end)

      assert Enum.any?(calls, &(elem(&1, 4) == :platform_admin))

      {mismatches, _log} =
        with_log(fn ->
          Enum.flat_map(calls, fn {router, method, path, key, caller, ctx} ->
            before = {snapshot(tenant), snapshot(platform)}
            _outcome = walk_call(router, method, path, ctx)
            after_rows = {snapshot(tenant), snapshot(platform)}

            if before == after_rows,
              do: [],
              else: [{inspect(router), method, path, key, caller}]
          end)
        end)

      assert mismatches == [], "routes that changed role_scope_grants: #{inspect(mismatches)}"
      # 1 = the control write of prove_tripwire!/1; nothing from any route.
      assert tripwire_hits(tenant) == 1
      assert tripwire_hits(platform) == 0
      assert RoleScopeGrants.user_row_count(tenant) == 0
      RSG.assert_t9_zero!(tenant)
    end

    test "T-RW2b binding, membership, token, status, onboarding and scope-enforcement routes with valid bodies: exact deltas only" do
      %{world: world, ta_ctx: ta_ctx, pa_ctx: pa_ctx} = walk_world!()
      s = world.tenant.schema_name
      platform = world.platform.schema_name
      identity = Letflow.Routers.Identity

      g1 = RSG.group!(s, "req497-rw-g1")
      g2 = RSG.group!(s, "req497-rw-g2")
      g3 = RSG.group!(s, "req497-rw-g3")
      g4 = RSG.group!(s, "req497-rw-g4")
      plain = RSG.user!(s)
      ta2 = TokenMintFixture.role_holder!(s, ["TENANT_ADMIN"])
      tw_group = RSG.group_of!(s, "TASK_WORKER")
      po_group = RSG.group_of!(s, "PROCESS_OPERATOR")
      po_role = RSG.binding(s, "PROCESS_OPERATOR")
      platform_before = snapshot(platform)

      # POST /roles, a new routing binding: no row.
      before = snapshot(s)

      conn =
        request(identity, :post, "/roles", ta_ctx, %{
          "name" => "req497-rw-route",
          "kind" => "process_routing_role",
          "group_id" => g1.id
        })

      assert conn.status in [200, 201], conn.resp_body
      before = assert_delta!(s, before, [], [], "POST /roles routing")

      # POST /roles kind change platform -> routing: exactly the binding's row goes.
      conn =
        request(identity, :post, "/roles", ta_ctx, %{
          "name" => "TASK_WORKER",
          "kind" => "process_routing_role",
          "group_id" => tw_group
        })

      assert conn.status in [200, 201], conn.resp_body

      before =
        assert_delta!(s, before, [tw_key(tw_group, "TASK_WORKER")], [], "kind -> routing")

      # ... and back to platform: exactly one new tenant-wide row.
      conn =
        request(identity, :post, "/roles", ta_ctx, %{
          "name" => "TASK_WORKER",
          "kind" => "platform_role",
          "group_id" => tw_group
        })

      assert conn.status in [200, 201], conn.resp_body

      before =
        assert_delta!(s, before, [], [tw_key(tw_group, "TASK_WORKER")], "kind -> platform")

      # POST /roles/:id/rebind: the row follows the binding.
      conn =
        request(identity, :post, "/roles/#{po_role.id}/rebind", ta_ctx, %{
          "group_id" => g4.id,
          "reason" => "REQ-497 route walk"
        })

      assert conn.status == 200, conn.resp_body

      before =
        assert_delta!(
          s,
          before,
          [tw_key(po_group, "PROCESS_OPERATOR")],
          [tw_key(g4.id, "PROCESS_OPERATOR")],
          "rebind"
        )

      # Membership add and remove: no row.
      conn =
        request(identity, :post, "/groups/#{g2.id}/members", ta_ctx, %{"user_id" => plain.id})

      assert conn.status in [200, 201], conn.resp_body
      before = assert_delta!(s, before, [], [], "member add")

      conn = request(identity, :delete, "/groups/#{g2.id}/members/#{plain.id}", ta_ctx, %{})
      assert conn.status == 204, conn.resp_body
      before = assert_delta!(s, before, [], [], "member remove")

      # Token mint and revoke (the owner is also a TA member, so N1 allows the revoke).
      conn =
        request(identity, :post, "/tokens", ta_ctx, %{
          "user_id" => ta2.id,
          "roles" => ["TENANT_ADMIN"]
        })

      assert conn.status in [200, 201], conn.resp_body
      token_id = Jason.decode!(conn.resp_body)["id"]
      before = assert_delta!(s, before, [], [], "token mint")

      conn = request(identity, :delete, "/tokens/#{token_id}", ta_ctx, %{})
      assert conn.status == 200, conn.resp_body
      before = assert_delta!(s, before, [], [], "token revoke")

      # User status deactivate and reactivate.
      for status <- ["inactive", "active"] do
        conn =
          request(identity, :post, "/users/#{plain.id}/status", ta_ctx, %{"status" => status})

        assert conn.status == 200, conn.resp_body
      end

      before = assert_delta!(s, before, [], [], "user status")

      # PUT /tenant/scope-enforcement, both ways.
      enforcement = Letflow.Routers.TenantScopeEnforcement

      conn = request(enforcement, :put, "/", ta_ctx, %{"mode" => "shadow"})
      assert conn.status == 200, conn.resp_body

      conn =
        request(enforcement, :put, "/", ta_ctx, %{"mode" => "off", "reason" => "REQ-497 walk"})

      assert conn.status == 200, conn.resp_body
      before = assert_delta!(s, before, [], [], "scope-enforcement flips")

      # Onboarding pending-admin revoke as the platform operator (admins remain, so 204).
      grant = H.create_grant!(world, "req497-rw-owner@example.com")
      record = H.onboarding_record!(world)

      conn =
        request(
          Letflow.Routers.Onboarding,
          :delete,
          "/#{record.id}/pending-admins/#{grant.id}",
          pa_ctx,
          %{}
        )

      assert conn.status == 204, conn.resp_body
      _ = assert_delta!(s, before, [], [], "pending-admin revoke")

      # DELETE /groups/:id of an unbound, memberless group carrying a stray tenant-wide row:
      # the 1a cascade removes exactly that group's row.
      :ok = RSG.raw_tenant_wide_row!(s, g3.id, "TASK_WORKER")
      before = snapshot(s)
      conn = request(identity, :delete, "/groups/#{g3.id}", ta_ctx, %{})
      assert conn.status == 204, conn.resp_body
      _after = assert_delta!(s, before, [tw_key(g3.id, "TASK_WORKER")], [], "group delete")

      assert snapshot(platform) == platform_before
      assert tripwire_hits(s) == 1
      assert tripwire_hits(platform) == 0
      RSG.assert_t9_zero!(s)
    end

    test "T-RW2c (REQ-517 AC 15) with valid bodies ONLY POST /, DELETE /:id and POST /make-tenant-wide of the grants router change scoped rows; a seeded route that inserts a scoped row is reported as a mismatch" do
      world = H.world!()
      s = world.tenant.schema_name
      ta = TokenMintFixture.role_holder!(s, ["TENANT_ADMIN"])
      ctx = oidc_context(ta.id, world.tenant.tenant_id, ["TENANT_ADMIN"])
      grants = Letflow.Routers.TenantRoleScopeGrants

      allowed = [
        {grants, "POST", "/"},
        {grants, "DELETE", "/:id"},
        {grants, "POST", "/make-tenant-wide"}
      ]

      # A binding with zero rows, two nodes: the state a scoped create starts from.
      group = RSG.group_of!(s, "TASK_WORKER")
      _ = RSG.raw_delete_rows!(s, group, "TASK_WORKER")
      [n1, n2, n3] = for _ <- 1..3, do: RSG.node!(s)

      create_body = fn node ->
        %{
          "principal_type" => "group",
          "principal_id" => group,
          "role" => "TASK_WORKER",
          "scope_node_id" => node
        }
      end

      # Positive control: each allowed route, with a valid body, DOES change the scoped rows.
      changed? = fn router, method, path, body ->
        before = scoped_snapshot(s)
        conn = request(router, method, path, ctx, body)
        {conn.status, scoped_snapshot(s) != before}
      end

      assert {201, true} = changed?.(grants, :post, "/", create_body.(n1))
      assert {201, true} = changed?.(grants, :post, "/", create_body.(n2))
      assert {201, true} = changed?.(grants, :post, "/", create_body.(n3))
      assert {200, false} = changed?.(grants, :get, "/", %{})

      [deleted | _] = scoped_snapshot(s) |> Map.keys() |> Enum.sort()
      {_type, _principal, _role, deleted_node} = deleted

      scoped_id = fn node ->
        Repo.one!(
          from(g in Letflow.Identity.RoleScopeGrant,
            where: g.scope_node_id == ^node,
            select: g.id
          ),
          prefix: s
        )
      end

      assert {204, true} = changed?.(grants, :delete, "/#{scoped_id.(deleted_node)}", %{})

      assert {200, true} =
               changed?.(grants, :post, "/make-tenant-wide", %{
                 "principal_type" => "group",
                 "principal_id" => group,
                 "role" => "TASK_WORKER"
               })

      # Walk: every OTHER route of every router, empty body, changes no scoped row.
      # (A scoped row must exist for a change to be visible: re-create one first.)
      _ = RSG.raw_delete_rows!(s, group, "TASK_WORKER")
      :ok = RSG.raw_scoped_row!(s, group, "TASK_WORKER", n1)

      other_routes =
        for router <- routers(),
            {method, path, _key} <- router.__authz_routes__(),
            {router, method |> to_string() |> String.upcase(), path} not in allowed,
            do: {router, method, path}

      assert length(other_routes) > 100, "the walk cannot pass vacuously"

      {mismatches, _log} =
        with_log(fn -> scoped_mismatches(s, other_routes, ctx) end)

      assert mismatches == [], "routes that changed a scoped row: #{inspect(mismatches)}"

      # Control: a seeded route that inserts a scoped row by SQL IS reported.
      seeded = [{__MODULE__.SeededScopedWriter, :post, "/seeded"}]

      assert scoped_mismatches(s, seeded, ctx) ==
               [{inspect(__MODULE__.SeededScopedWriter), :post, "/seeded"}]
    end
  end

  # A test-support router: inserts a scoped row by SQL, as a route outside the allowed list would.
  defmodule SeededScopedWriter do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      {:ok, schema} =
        Letflow.TenantProvisioning.schema_name_for_tenant(conn.assigns.auth_context.tenant_id)

      :ok =
        Letflow.Support.RoleScopeGrantsFixture.raw_scoped_row!(
          schema,
          Ecto.UUID.generate(),
          "TASK_WORKER",
          Letflow.Support.RoleScopeGrantsFixture.node!(schema)
        )

      Plug.Conn.send_resp(conn, 200, "")
    end
  end

  # ===========================================================================================
  describe "T-RW3 / T-RW4 N4: managed-name rule paths" do
    setup do
      %{world: world, ta_ctx: ta_ctx} = walk_world!()
      tenant_id = world.tenant.tenant_id

      on_exit(fn ->
        Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))
        Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
        Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
      end)

      {:ok, _seeded} = EventTypes.seed!(world.tenant.schema_name)
      %{world: world, ta_ctx: ta_ctx, schema: world.tenant.schema_name}
    end

    test "T-RW3 module install, definition create/activate and the managed-name refusal change no grant row",
         %{ta_ctx: ta_ctx, schema: s} do
      designer = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])
      designer_ctx = oidc_context(designer.id, ta_ctx.tenant_id, ["PROCESS_DESIGNER"])
      before = snapshot(s)

      conn =
        request(Letflow.Routers.TenantModules, :post, "/", ta_ctx, %{
          "module_id" => "fixture_managed",
          "rationale" => "REQ-497 route walk N4"
        })

      assert conn.status == 201, conn.resp_body
      assert snapshot(s) == before
      assert managed_types(s) != []

      entities = Letflow.Routers.Entities

      conn = request(entities, :post, "/definitions", designer_ctx, definition_body("rw_n4_free"))
      assert conn.status == 201, conn.resp_body
      assert snapshot(s) == before

      conn =
        request(entities, :post, "/definitions/rw_n4_free/activate", designer_ctx, %{
          "rationale" => "REQ-497 route walk N4"
        })

      assert conn.status in 200..299, conn.resp_body
      assert snapshot(s) == before

      # A managed name keeps the #2530 constant refusal (0050 D7), unchanged.
      conn = request(entities, :post, "/definitions", designer_ctx, definition_body("fxm_unit"))
      assert conn.status == 403, conn.resp_body
      assert conn.resp_body == Error.serialise(%{Error.entity_type_managed() | trace_id: @trace})
      assert snapshot(s) == before
      assert tripwire_hits(s) == 1
    end

    test "T-RW4a provisioning and onboarding call no definition writer and no pack install and write no EntityDefinition" do
      files = ["lib/letflow/tenant_provisioning.ex", "lib/letflow/tenant_onboarding.ex"]

      for path <- files do
        ast = parse(path)

        offending =
          any_node?(ast, fn
            {{:., _, [_receiver, fun]}, _, _args} ->
              fun in [:create_definition, :activate_definition]

            {fun, _, args} when fun in [:create_definition, :activate_definition] ->
              is_list(args)

            _other ->
              false
          end)

        refute offending, "#{path} calls a definition writer"

        refute any_node?(ast, fn
                 {{:., _, [{:__aliases__, _, segments}, :install]}, _, _args} ->
                   List.last(segments) == :SolutionPack

                 _other ->
                   false
               end),
               "#{path} calls SolutionPack.install"

        # N4 requires no EntityDefinition row written at runtime. Naming the schema (manifest
        # entries, provisioning migrations, reading a persisted row) is legitimate, so the check is
        # on WRITES: no Repo write call that takes the schema or the table name as an argument,
        # and no call into the EntityDefinition module (changeset builders).
        repo_writes =
          [:insert, :insert!, :insert_all, :update, :update!, :update_all] ++
            [:delete, :delete!, :delete_all, :insert_or_update, :insert_or_update!]

        names_definitions? = fn args ->
          any_node?(args, fn
            {:__aliases__, _, segments} -> List.last(segments) == :EntityDefinition
            bin when is_binary(bin) -> String.contains?(bin, "entity_definitions")
            _other -> false
          end)
        end

        refute any_node?(ast, fn
                 {{:., _, [{:__aliases__, _, segs}, fun]}, _, args}
                 when is_atom(fun) and is_list(args) ->
                   (List.last(segs) == :Repo and fun in repo_writes and names_definitions?.(args)) or
                     (List.last(segs) == :EntityDefinition and fun != :t)

                 _other ->
                   false
               end),
               "#{path} writes an EntityDefinition row"
      end
    end

    test "T-RW4b provisioning a new tenant leaves an installed managed type's managed_by, name and the grant rows unchanged",
         %{ta_ctx: ta_ctx, schema: s} do
      conn =
        request(Letflow.Routers.TenantModules, :post, "/", ta_ctx, %{
          "module_id" => "fixture_managed",
          "rationale" => "REQ-497 route walk N4"
        })

      assert conn.status == 201, conn.resp_body
      managed_before = managed_types(s)
      rows_before = snapshot(s)
      assert managed_before != []

      _other = TenantFixture.provisioned_tenant!(slug_prefix: "req497-rw4")

      assert managed_types(s) == managed_before
      assert snapshot(s) == rows_before
    end
  end
end
