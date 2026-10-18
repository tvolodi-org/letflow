defmodule Letflow.Api.ScopeTest do
  @moduledoc """
  REQ-497 PR 1b (GH #2533), AC5: `Letflow.Api.Scope.allowed?/3`, `effective_scope/2` and the
  static shape of `lib/letflow/api/scope.ex`. Design
  `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` sections 1.1-1.4 and 12.1; spec
  `test/specs/REQ-497-1b.md`, tests T-A1..T-A13.

  Every principal is built from REAL stored state: the roles come from
  `Identity.list_effective_role_names/2` (group membership) through
  `Authorization.effective_roles/2`, the grants from `Scope.load_grants/2` over real
  `role_scope_grants` rows. Scoped and user rows are inserted RAW by
  `Letflow.Support.RoleScopeGrantsFixture` (no route writes one in stage 1); bindings and their
  tenant-wide group rows come from `Letflow.Support.TokenMintFixture` (which writes the row with
  the binding, so a fresh binding has no T9 gap). Scope trees are written through the sole
  writer `ScopeNodePaths.write/2`.

  Binding ruling pinned here: a platform-scope permission is decided WITHOUT reading grants or
  the resource (zero repo queries, captured with `PlatformTenantFixture.capture_repo_queries/1`,
  whatever the `grants` value), and a permission outside `Authorization.permissions/0` denies
  `:role_not_held` before anything else (T-A13).

  `async: false`: dedicated provisioned tenants (the fixture flips the sandbox to `:auto`) and
  the platform-tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.Principal
  alias Letflow.Identity
  alias Letflow.PlatformTenant
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture

  @scope_source Path.expand("../../../lib/letflow/api/scope.ex", __DIR__)

  setup do
    Fixture.unpin!()
    :ok
  end

  # --- fixtures --------------------------------------------------------------------------------

  defp tenant!(slug_prefix), do: TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

  # The group the binding `role` points to (created with its tenant-wide row on first use).
  defp holder!(fx, roles), do: TokenMintFixture.role_holder!(fx.schema_name, roles)

  defp group_of!(fx, role), do: RSG.group_of!(fx.schema_name, role)

  # A root node through the sole tree writer.
  defp root!(fx), do: RSG.node!(fx.schema_name)

  defp child!(fx, parent_id) do
    id = "req497-a-child-#{System.unique_integer([:positive])}"
    {:ok, _node} = ScopeNodePaths.write({:insert, id, parent_id}, fx.schema_name)
    id
  end

  # A `:user` principal built exactly as `Scope.principal_from_conn/1` builds it, from the DB.
  defp user_principal(fx, user_id) do
    platform? = PlatformTenant.platform_tenant?(fx.tenant_id)

    %Principal{
      kind: :user,
      user_id: user_id,
      prefix: fx.schema_name,
      platform_tenant?: platform?,
      roles:
        Authorization.effective_roles(
          Identity.list_effective_role_names(user_id, prefix: fx.schema_name),
          platform?
        ),
      grants: Scope.load_grants(user_id, fx.schema_name)
    }
  end

  defp token_principal(fx, user_id, role_strings) do
    platform? = PlatformTenant.platform_tenant?(fx.tenant_id)

    %Principal{
      kind: :token,
      user_id: user_id,
      prefix: fx.schema_name,
      platform_tenant?: platform?,
      roles: Authorization.effective_roles(role_strings, platform?),
      grants: :token
    }
  end

  # `fun`'s result and the number of repo queries the calling process issued while it ran.
  defp with_query_count(fun) do
    {result, queries} = Fixture.capture_repo_queries(fun)
    {result, length(queries)}
  end

  # T-A1 fixture: a TASK_WORKER member whose group has (only) its tenant-wide row.
  defp tenant_wide_worker!(fx) do
    user = holder!(fx, ["TASK_WORKER"])

    assert RSG.rows(fx.schema_name)
           |> Enum.member?(RSG.tw(group_of!(fx, "TASK_WORKER"), "TASK_WORKER"))

    user
  end

  # T-A3 fixture: user row on N1, the TASK_WORKER group row only on N2.
  defp union_worker!(fx) do
    user = holder!(fx, ["TASK_WORKER"])
    n2 = RSG.make_group_scoped_only!(fx.schema_name, group_of!(fx, "TASK_WORKER"), "TASK_WORKER")
    n1 = root!(fx)
    :ok = RSG.raw_user_row!(fx.schema_name, user.id, "TASK_WORKER", n1)
    %{user: user, n1: n1, n2: n2}
  end

  # T-A5 fixture: a TASK_WORKER binding with ZERO rows (a T9 gap).
  defp rowless_worker!(fx) do
    user = holder!(fx, ["TASK_WORKER"])
    assert RSG.raw_delete_rows!(fx.schema_name, group_of!(fx, "TASK_WORKER"), "TASK_WORKER") == 1
    user
  end

  # --- T-A1 ------------------------------------------------------------------------------------

  test "T-A1 own group with its tenant-wide row: :TasksRead on :tenant_wide is {:allow, :tenant_wide}" do
    fx = tenant!("req497-a1")
    p = user_principal(fx, tenant_wide_worker!(fx).id)

    assert p.roles == [:TASK_WORKER]
    assert Scope.allowed?(p, :TasksRead, :tenant_wide) == {:allow, :tenant_wide}
  end

  # --- T-A2 ------------------------------------------------------------------------------------

  test "T-A2 tenant-wide wins within a principal: a tenant-wide AND a scoped row allow another node without a read" do
    fx = tenant!("req497-a2")
    user = tenant_wide_worker!(fx)
    scoped_node = root!(fx)
    other_node = root!(fx)

    :ok =
      RSG.raw_scoped_row!(
        fx.schema_name,
        group_of!(fx, "TASK_WORKER"),
        "TASK_WORKER",
        scoped_node
      )

    p = user_principal(fx, user.id)

    {decision, queries} =
      with_query_count(fn -> Scope.allowed?(p, :TasksRead, {:node, other_node}) end)

    assert decision == {:allow, :tenant_wide}
    # Step 9: a combined tenant-wide scope allows a node without reading the tree.
    assert queries == 0
  end

  # --- T-A3 ------------------------------------------------------------------------------------

  test "T-A3 union across principals: user row on N1 and group row on N2 allow N1 and a child of N2, not N3" do
    fx = tenant!("req497-a3")
    %{user: user, n1: n1, n2: n2} = union_worker!(fx)
    n2_child = child!(fx, n2)
    n3 = root!(fx)

    p = user_principal(fx, user.id)

    assert Scope.allowed?(p, :TasksRead, {:node, n1}) == {:allow, :subtree}
    assert Scope.allowed?(p, :TasksRead, {:node, n2_child}) == {:allow, :subtree}
    assert Scope.allowed?(p, :TasksRead, {:node, n3}) == {:deny, :out_of_scope}
    # Only nodes: the tenant-wide resource is not covered.
    assert Scope.allowed?(p, :TasksRead, :tenant_wide) == {:deny, :not_tenant_wide}
  end

  # --- T-A4 ------------------------------------------------------------------------------------

  test "T-A4 a tenant-wide USER row for a role the user holds through no group has no effect" do
    fx = tenant!("req497-a4")
    user = tenant_wide_worker!(fx)
    # Make sure the PROCESS_DESIGNER binding exists (held by somebody else), then give `user`
    # only a tenant-wide user row for it.
    _designer = holder!(fx, ["PROCESS_DESIGNER"])
    :ok = RSG.raw_user_row!(fx.schema_name, user.id, "PROCESS_DESIGNER", nil)

    p = user_principal(fx, user.id)

    refute :PROCESS_DESIGNER in p.roles
    assert Map.has_key?(p.grants.rows_by_role, "PROCESS_DESIGNER")
    assert Authorization.role_allows?(:PROCESS_DESIGNER, :EntitiesDefinitionsWrite)
    assert Scope.allowed?(p, :EntitiesDefinitionsWrite, :tenant_wide) == {:deny, :role_not_held}
    assert Scope.effective_scope(p, "PROCESS_DESIGNER") == :deny
  end

  # --- T-A5 ------------------------------------------------------------------------------------

  test "T-A5 a binding with zero rows is denied :no_grant_rows, never tenant-wide" do
    fx = tenant!("req497-a5")
    p = user_principal(fx, rowless_worker!(fx).id)
    node = root!(fx)

    assert p.roles == [:TASK_WORKER]
    assert Scope.allowed?(p, :TasksRead, :tenant_wide) == {:deny, :no_grant_rows}
    assert Scope.allowed?(p, :TasksRead, {:node, node}) == {:deny, :no_grant_rows}
  end

  # --- T-A6 ------------------------------------------------------------------------------------

  test "T-A6 :unresolvable is denied for a user, a token, a tenant-wide and a platform-tenant PLATFORM_ADMIN principal" do
    fx = tenant!("req497-a6")
    scoped = union_worker!(fx)
    other = tenant!("req497-a6-tw")
    tenant_wide = user_principal(other, tenant_wide_worker!(other).id)

    principals = [
      user_principal(fx, scoped.user.id),
      token_principal(fx, scoped.user.id, ["TASK_WORKER"]),
      tenant_wide
    ]

    for p <- principals do
      assert Scope.allowed?(p, :TasksRead, :unresolvable) == {:deny, :unresolvable},
             inspect(p.kind)
    end

    # A platform-tenant PLATFORM_ADMIN on a tenant-scope permission: step 2 precedes step 4.
    platform = tenant!("req497-a6-p")
    Fixture.pin!(platform.tenant_id)
    pa = holder!(platform, ["PLATFORM_ADMIN"])
    pa_principal = user_principal(platform, pa.id)
    assert :PLATFORM_ADMIN in pa_principal.roles
    assert Scope.allowed?(pa_principal, :TasksRead, :unresolvable) == {:deny, :unresolvable}
  end

  # --- T-A7 ------------------------------------------------------------------------------------

  test "T-A7 a missing or malformed node denies :unresolvable without raising; the decision follows the CURRENT tree after a move" do
    fx = tenant!("req497-a7")
    %{user: user, n2: n2} = union_worker!(fx)
    elsewhere = root!(fx)
    moving = child!(fx, elsewhere)

    p = user_principal(fx, user.id)

    assert Scope.allowed?(p, :TasksRead, {:node, "req497-no-such-node"}) == {:deny, :unresolvable}
    assert Scope.allowed?(p, :TasksRead, {:node, "a/b"}) == {:deny, :unresolvable}
    assert Scope.allowed?(p, :TasksRead, {:node, ""}) == {:deny, :unresolvable}

    # Existing, outside the subtree.
    assert Scope.allowed?(p, :TasksRead, {:node, moving}) == {:deny, :out_of_scope}

    # Move `moving` under N2: the very next decision sees the new tree.
    {:ok, _node} = ScopeNodePaths.write({:move, moving, n2}, fx.schema_name)
    assert Scope.allowed?(p, :TasksRead, {:node, moving}) == {:allow, :subtree}

    # And back out again.
    {:ok, _node} = ScopeNodePaths.write({:move, moving, elsewhere}, fx.schema_name)
    assert Scope.allowed?(p, :TasksRead, {:node, moving}) == {:deny, :out_of_scope}
  end

  # --- T-A8 ------------------------------------------------------------------------------------

  describe "T-A8 static pin of lib/letflow/api/scope.ex" do
    setup do
      {:ok, ast} = @scope_source |> File.read!() |> Code.string_to_quoted()
      %{ast: ast, source: File.read!(@scope_source)}
    end

    test "the tree is reached only through ScopeNodePaths.resolve/2 and allowed_node_ids/2 (REQ-518)",
         %{
           ast: ast
         } do
      calls = remote_calls(ast, [:ScopeNodePaths])
      assert calls != []
      assert calls |> Enum.uniq() |> Enum.sort() == [:allowed_node_ids, :resolve]
    end

    test "no ScopeNodePaths.Node schema and no \"scope_node_paths\" literal", %{ast: ast} do
      aliases =
        collect(ast, fn
          {:__aliases__, _, parts} -> [parts]
          _ -> []
        end)

      refute Enum.any?(aliases, &(:Node in &1)), "scope.ex references a Node schema"

      strings =
        collect(ast, fn
          s when is_binary(s) -> [s]
          _ -> []
        end)

      refute Enum.any?(strings, &String.contains?(&1, "scope_node_paths"))
    end

    test "no Repo call outside load_grants/2 (grants are read through RoleScopeGrants)", %{
      ast: ast
    } do
      defs_with_repo =
        ast
        |> function_defs()
        |> Enum.filter(fn {_name, body} ->
          remote_calls(body, [:Repo]) != [] or remote_calls(body, [:Letflow, :Repo]) != []
        end)
        |> Enum.map(fn {name, _body} -> name end)
        |> Enum.uniq()

      assert defs_with_repo -- [:load_grants] == []

      load_grants_calls =
        ast
        |> function_defs()
        |> Enum.filter(fn {name, _} -> name == :load_grants end)
        |> Enum.flat_map(fn {_, body} -> remote_calls(body, [:RoleScopeGrants]) end)

      assert load_grants_calls == [:applicable_rows_for_user]
    end
  end

  # Function names called as `Alias.fun(...)` on the given alias parts.
  defp remote_calls(ast, alias_parts) do
    collect(ast, fn
      {{:., _, [{:__aliases__, _, ^alias_parts}, fun]}, _, _args} when is_atom(fun) -> [fun]
      _ -> []
    end)
  end

  # `{name, body}` for every def/defp in the file (nested modules included).
  defp function_defs(ast) do
    collect(ast, fn
      {kind, _, [{:when, _, [{name, _, _} | _]} | rest]} when kind in [:def, :defp] ->
        [{name, rest}]

      {kind, _, [{name, _, _} | rest]} when kind in [:def, :defp] and is_atom(name) ->
        [{name, rest}]

      _ ->
        []
    end)
  end

  defp collect(ast, fun) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc -> {node, acc ++ fun.(node)} end)

    acc
  end

  # --- T-A9 ------------------------------------------------------------------------------------

  describe "T-A9 platform-scope permissions never read grants or the resource" do
    test "a platform-tenant PLATFORM_ADMIN is allowed identically with its group row present, absent, or scoped, and with grants not loaded; zero queries" do
      fx = tenant!("req497-a9")
      Fixture.pin!(fx.tenant_id)
      pa = holder!(fx, ["PLATFORM_ADMIN"])
      pa_group = group_of!(fx, "PLATFORM_ADMIN")
      node = root!(fx)

      present = user_principal(fx, pa.id)
      assert Authorization.permission_scope(:TenantsManage) == :platform

      _ = RSG.raw_delete_rows!(fx.schema_name, pa_group, "PLATFORM_ADMIN")
      absent = user_principal(fx, pa.id)
      assert absent.grants.rows_by_role == %{}

      _node = RSG.make_group_scoped_only!(fx.schema_name, pa_group, "PLATFORM_ADMIN")
      scoped = user_principal(fx, pa.id)

      not_loaded = %{present | grants: :not_loaded}

      for p <- [present, absent, scoped, not_loaded],
          resource <- [:tenant_wide, {:node, node}, :unresolvable] do
        {decision, queries} =
          with_query_count(fn -> Scope.allowed?(p, :TenantsManage, resource) end)

        assert decision == {:allow, :platform}, inspect({p.grants, resource})
        assert queries == 0, "platform-scope decision issued #{queries} queries"
      end
    end

    test "a PLATFORM_ADMIN outside the platform tenant is denied :role_not_held, with zero queries" do
      fx = tenant!("req497-a9-np")
      pa = holder!(fx, ["PLATFORM_ADMIN"])

      # Effective roles already drop it outside the platform tenant ...
      p = user_principal(fx, pa.id)
      refute p.platform_tenant?
      refute :PLATFORM_ADMIN in p.roles

      # ... and a principal that still carries the atom is refused by the scope check too.
      raw = %{p | roles: [:PLATFORM_ADMIN]}

      for principal <- [p, raw] do
        {decision, queries} =
          with_query_count(fn -> Scope.allowed?(principal, :TenantsManage, :tenant_wide) end)

        assert decision == {:deny, :role_not_held}
        assert queries == 0
      end
    end
  end

  # --- T-A10 -----------------------------------------------------------------------------------

  test "T-A10 a token principal is allowed :token even when its owner's groups hold only scoped rows; its rows are never read" do
    fx = tenant!("req497-a10")
    %{user: owner} = union_worker!(fx)
    other_node = root!(fx)
    p = token_principal(fx, owner.id, ["TASK_WORKER"])

    for resource <- [:tenant_wide, {:node, other_node}] do
      {decision, queries} = with_query_count(fn -> Scope.allowed?(p, :TasksRead, resource) end)
      assert decision == {:allow, :token}
      assert queries == 0
    end
  end

  # --- T-A11 -----------------------------------------------------------------------------------

  test "T-A11 a user principal whose grants are :not_loaded is denied :grants_unavailable" do
    fx = tenant!("req497-a11")
    p = %{user_principal(fx, tenant_wide_worker!(fx).id) | grants: :not_loaded}

    assert Scope.allowed?(p, :TasksRead, :tenant_wide) == {:deny, :grants_unavailable}
    assert Scope.allowed?(p, :TasksRead, {:node, root!(fx)}) == {:deny, :grants_unavailable}
  end

  # --- T-A12 -----------------------------------------------------------------------------------

  test "T-A12 effective_scope/2 is :tenant_wide, {:nodes, sorted} and :deny for the T-A1, T-A3 and T-A5 fixtures" do
    a1 = tenant!("req497-a12-1")
    a3 = tenant!("req497-a12-3")
    a5 = tenant!("req497-a12-5")

    p1 = user_principal(a1, tenant_wide_worker!(a1).id)
    %{user: u3, n1: n1, n2: n2} = union_worker!(a3)
    p3 = user_principal(a3, u3.id)
    p5 = user_principal(a5, rowless_worker!(a5).id)

    assert Scope.effective_scope(p1, "TASK_WORKER") == :tenant_wide
    assert Scope.effective_scope(p3, "TASK_WORKER") == {:nodes, Enum.sort([n1, n2])}
    assert Scope.effective_scope(p5, "TASK_WORKER") == :deny

    # Not held, and grants not loaded: :deny.
    assert Scope.effective_scope(p1, "PROCESS_DESIGNER") == :deny
    assert Scope.effective_scope(%{p1 | grants: :not_loaded}, "TASK_WORKER") == :deny
    assert Scope.effective_scope(%{p1 | grants: :token}, "TASK_WORKER") == :deny
  end

  # --- T-A13 -----------------------------------------------------------------------------------

  test "T-A13 an unclassified permission is denied :role_not_held for a platform-tenant PLATFORM_ADMIN, a TENANT_ADMIN and a token principal" do
    # Why step 0 exists: without it the atom would be classified :platform and the
    # PLATFORM_ADMIN catch-all would allow it.
    refute :NotARealPermission in Authorization.permissions()
    assert Authorization.permission_scope(:NotARealPermission) == :platform
    assert Authorization.role_allows?(:PLATFORM_ADMIN, :NotARealPermission)

    platform = tenant!("req497-a13-p")
    Fixture.pin!(platform.tenant_id)
    pa = user_principal(platform, holder!(platform, ["PLATFORM_ADMIN"]).id)
    assert pa.platform_tenant? and :PLATFORM_ADMIN in pa.roles

    fx = tenant!("req497-a13")
    ta_user = holder!(fx, ["TENANT_ADMIN"])
    ta = user_principal(fx, ta_user.id)
    token = token_principal(fx, ta_user.id, ["TENANT_ADMIN"])

    for p <- [pa, ta, token], resource <- [:tenant_wide, :unresolvable] do
      {decision, queries} =
        with_query_count(fn -> Scope.allowed?(p, :NotARealPermission, resource) end)

      assert decision == {:deny, :role_not_held}, inspect({p.kind, p.roles})
      assert queries == 0
    end
  end
end
