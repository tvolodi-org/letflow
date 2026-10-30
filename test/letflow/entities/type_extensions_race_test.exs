defmodule Letflow.Entities.TypeExtensionsRaceTest do
  @moduledoc """
  REQ-609 / GH #3417 (design ID C3): two concurrent creators of the last slot of a type end with
  exactly the cap, one success and one `:extension_limit_reached`, because the count is taken
  under a transaction advisory lock. Committed tenant, Sandbox `:auto` mode.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.EntityTypeExtension
  alias Letflow.Entities.TypeExtensions
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Repo
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    base = Fx.committed_tenant_case!("gh3417-race")

    on_exit(fn ->
      Fx.drop_committed_tenant!(base.tenant.tenant_id)
      SandboxAutoMode.exit_auto_mode!(Repo)
    end)

    :ok = Fx.install_managed_fixture!(base.schema)
    %{base: base}
  end

  test "C3 two creators of the 50th slot: one wins, the cap holds", %{base: base} do
    actor = %{user_id: base.user.id, trace_id: nil}

    create = fn name ->
      TypeExtensions.create_extension_audited(
        %{"entity_type" => "fxm_site", "name" => name, "spec" => %{"type" => "string"}},
        actor,
        base.schema
      )
    end

    for i <- 1..49, do: {:ok, _} = create.("x_f#{i}")

    results =
      ["x_last_a", "x_last_b"]
      |> Enum.map(fn name -> Task.async(fn -> create.(name) end) end)
      |> Task.await_many(30_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :extension_limit_reached})) == 1
    assert Repo.aggregate(EntityTypeExtension, :count, :id, prefix: base.schema) == 50
  end
end
