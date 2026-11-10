defmodule Letflow.Modules.RuntimeDemo.RegistrationTest do
  @moduledoc """
  T-1641: the QA-only demo module is in the test catalogue, its manifest validates in every release, and
  the production permission golden does not know it.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.RuntimeDemo

  setup do
    old = Application.get_env(:letflow, :runtime_demo_release)

    on_exit(fn ->
      if old,
        do: Application.put_env(:letflow, :runtime_demo_release, old),
        else: Application.delete_env(:letflow, :runtime_demo_release)
    end)
  end

  test "R1: registered in the test catalogue" do
    assert Catalog.fetch("runtime_demo") == {:ok, RuntimeDemo}
    assert RuntimeDemo.router() == Letflow.Modules.RuntimeDemo.Router
  end

  test "R2: every release manifest passes Catalog.validate/2 and names only declared permissions" do
    for release <- RuntimeDemo.releases() do
      Application.put_env(:letflow, :runtime_demo_release, release)
      m = RuntimeDemo.manifest()
      assert Catalog.validate(m) == :ok
      assert m.permissions == [:RuntimeDemoRead]
      assert m.role_grants == %{}
      assert Enum.all?(m.route_policies, fn {_method, _path, atom} -> atom in m.permissions end)
    end
  end

  test "R3: TENANT_ADMIN may read, TASK_WORKER may not" do
    admin = %AccessContext{user_id: "u", roles: [:TENANT_ADMIN]}
    worker = %AccessContext{user_id: "u", roles: [:TASK_WORKER]}
    assert Authorization.evaluate_access(admin, :RuntimeDemoRead).kind == :Allow
    assert Authorization.evaluate_access(worker, :RuntimeDemoRead).kind == :Deny403
  end

  test "R4: the production golden stays the production matrix (no runtime_demo row)" do
    golden = File.read!("priv/permission_matrix/effective.golden")
    refute golden =~ "runtime_demo"
    refute golden =~ "RuntimeDemoRead"
  end
end
