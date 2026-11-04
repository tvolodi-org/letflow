defmodule Letflow.Ledger.AuthorizeTest do
  @moduledoc """
  REQ-637 / GH #3559 part B, criterion 3: `Letflow.Ledger.authorize/3` and the authorized value
  (T-AZ-1..8). Sandbox `:auto`, real committed tenants, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Ledger
  alias Letflow.Ledger.Authorized
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Support.TokenMintFixture

  @id Fx.ledger_id()

  setup do
    Fx.setup_auto_mode!()
    Fx.put_registry!()
    %{fx: Fx.tenant_fixture!()}
  end

  defp authorize(fx, roles, purpose, credential \\ :oidc) do
    user = Fx.user!(fx, roles)
    Ledger.authorize(Fx.conn_for(fx, user, roles, credential), @id, purpose)
  end

  test "T-AZ-1 a tenant admin gets the value for both purposes, prefix from the conn", %{fx: fx} do
    for purpose <- [:read, :reconcile] do
      assert {:ok, %Authorized{} = a} = authorize(fx, ["TENANT_ADMIN"], purpose)
      assert a.prefix == fx.schema_name
      assert a.ledger_id == @id
      assert a.registration_name == "test"
      assert a.purpose == purpose
      assert a.slot_names == ["k_primary", "k_second", "k_third"]
    end
  end

  test "T-AZ-2 a read-only role reads but cannot reconcile; a task worker holds neither", %{
    fx: fx
  } do
    assert {:ok, %Authorized{purpose: :read}} = authorize(fx, ["PROCESS_DESIGNER"], :read)
    assert authorize(fx, ["PROCESS_DESIGNER"], :reconcile) === :error
    assert authorize(fx, ["TASK_WORKER"], :read) === :error
    assert authorize(fx, ["TASK_WORKER"], :reconcile) === :error
  end

  test "T-AZ-3 an api token principal is refused, even with TENANT_ADMIN", %{fx: fx} do
    assert authorize(fx, ["TENANT_ADMIN"], :read, :api_token) === :error
    assert authorize(fx, ["TENANT_ADMIN"], :reconcile, :api_token) === :error
    assert authorize(fx, ["TENANT_ADMIN"], :read, :something_else) === :error
  end

  test "T-AZ-4 a role that is not held tenant-wide is refused", %{fx: fx} do
    # claims TENANT_ADMIN in the context but is a member of no group: no grant row at all
    user = TokenMintFixture.role_holder!(fx.schema_name, [])
    conn = Fx.conn_for(fx, user, ["TENANT_ADMIN"])
    assert Ledger.authorize(conn, @id, :read) === :error
  end

  test "T-AZ-5 every other refusal is the same bare :error", %{fx: fx} do
    user = Fx.user!(fx, ["TENANT_ADMIN"])
    good = Fx.conn_for(fx, user, ["TENANT_ADMIN"])

    no_ctx = Plug.Conn.assign(good, :auth_context, nil)
    not_loaded = update_ctx(good, &Map.put(&1, :scope_grants, :not_loaded))
    no_prefix = Plug.Conn.assign(good, :scoped_opts, [])

    other_prefix =
      Plug.Conn.assign(good, :scoped_opts, prefix: "tenant_" <> String.duplicate("0", 32))

    results = [
      Ledger.authorize(good, "unknown_ledger", :read),
      Ledger.authorize(good, 42, :read),
      Ledger.authorize(good, @id, :write),
      Ledger.authorize(no_ctx, @id, :read),
      Ledger.authorize(not_loaded, @id, :read),
      Ledger.authorize(no_prefix, @id, :read),
      Ledger.authorize(other_prefix, @id, :read),
      Ledger.authorize(:not_a_conn, @id, :read)
    ]

    assert Enum.all?(results, &(&1 === :error))
  end

  test "T-AZ-5b an empty registry (the production default) refuses everything", %{fx: fx} do
    Fx.put_registry!(%{})
    assert authorize(fx, ["TENANT_ADMIN"], :read) === :error
  end

  test "T-AZ-6 PLATFORM_ADMIN outside the platform tenant is refused; a ScopeSetError is too", %{
    fx: fx
  } do
    assert authorize(fx, ["PLATFORM_ADMIN"], :read) === :error

    # a permission atom the registry names but that is unknown fails closed
    Fx.put_registry!(put_in(Fx.registry()[@id].read_permission, :NoSuchPermissionAtom))
    assert authorize(fx, ["TENANT_ADMIN"], :read) === :error

    # grant rows naming a node that does not exist expand to nothing or raise: never :all
    user = Fx.user!(fx, ["TENANT_ADMIN"])
    conn = Fx.conn_for(fx, user, ["TENANT_ADMIN"])

    bad_grants = %Letflow.Api.Scope.Grants{
      user_id: user.id,
      rows_by_role: %{
        "TENANT_ADMIN" => [
          %{principal_type: :user, tenant_wide: false, scope_node_id: "not-a-uuid"}
        ]
      }
    }

    Fx.put_registry!()
    conn = update_ctx(conn, &Map.put(&1, :scope_grants, bad_grants))
    assert Ledger.authorize(conn, @id, :read) === :error
  end

  test "T-AZ-7 refusals log nothing and two tenants each get their own prefix", %{fx: fx} do
    other = Fx.tenant_fixture!()
    user = Fx.user!(fx, ["PROCESS_DESIGNER"])
    conn = Fx.conn_for(fx, user, ["PROCESS_DESIGNER"])

    log =
      capture_log(fn ->
        assert Ledger.authorize(conn, @id, :reconcile) === :error
        assert Ledger.authorize(conn, "unknown_ledger", :read) === :error
      end)

    refute log =~ @id
    refute log =~ "PROCESS_DESIGNER"
    refute log =~ "unknown_ledger"

    {:ok, a} = authorize(fx, ["TENANT_ADMIN"], :read)
    {:ok, b} = authorize(other, ["TENANT_ADMIN"], :read)
    assert a.prefix == fx.schema_name
    assert b.prefix == other.schema_name
    assert a.prefix != b.prefix
  end

  describe "T-AZ-8 nothing outside the ledger files builds an Authorized value" do
    @literal ~r/%(Letflow\.Ledger\.)?Authorized\{/

    test "the scan finds a synthetic offender" do
      assert "x = %Letflow.Ledger.Authorized{prefix: 1}" =~ @literal
      assert "def f(%Authorized{} = a), do: a" =~ @literal
    end

    test "no struct literal or pattern in lib/ outside the ledger files" do
      offenders =
        for file <- Path.wildcard("lib/**/*.ex"),
            file != "lib/letflow/ledger.ex",
            not String.starts_with?(file, "lib/letflow/ledger/"),
            File.read!(file) =~ @literal,
            do: file

      assert offenders == []
    end
  end

  defp update_ctx(conn, fun),
    do: Plug.Conn.assign(conn, :auth_context, fun.(conn.assigns.auth_context))
end
