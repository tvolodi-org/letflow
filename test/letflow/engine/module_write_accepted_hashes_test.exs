defmodule Letflow.Engine.ModuleWriteAcceptedHashesTest do
  @moduledoc """
  REQ-769 / T-1371 (A3, A4, A5, A7): `tenant_modules.accepted_manifest_hashes` widens only the
  stamp-versus-installed comparison. Installed == compiled stays strict, the in-transaction
  recheck reads the list again, and `Installs.install_hashes/2` reads one row.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.EntityPortImpl
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Modules.Installs
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.Support.ScriptTaskFixture

  @x String.duplicate("9", 64)

  defmodule FlipPort do
    @moduledoc false
    @behaviour Letflow.Engine.EntityPort
    @impl true
    def prefetch(prefix, reads, vars), do: EntityPortImpl.prefetch(prefix, reads, vars)
    @impl true
    def authorize_module_writes(lines, ctx),
      do: EntityPortImpl.authorize_module_writes(lines, ctx)

    @impl true
    def prepare(lines, ctx) do
      result = EntityPortImpl.prepare(lines, ctx)
      {schema, module_id} = Application.fetch_env!(:letflow, :flip_accepted_target)
      Mw.set_installed_hash!(schema, module_id, String.duplicate("0", 64))
      result
    end

    @impl true
    def validate_lines(lines, ctx), do: EntityPortImpl.validate_lines(lines, ctx)
    @impl true
    def multi(multi, lines, ctx), do: EntityPortImpl.multi(multi, lines, ctx)
    @impl true
    def interpret_failure(step, reason), do: EntityPortImpl.interpret_failure(step, reason)
  end

  defp hash_mismatch?(ctx) do
    match?(
      {:error, {:entity_write_refused, 0, :write_not_permitted}},
      Fx.complete(ctx, %{"label" => "L1"})
    ) and
      Enum.any?(
        Fx.audit_rows(ctx.schema, "entity_write.refused"),
        &(&1.after_state["detail"] == "hash_mismatch")
      )
  end

  test "A2b stamp X in the accepted list, installed == compiled: the completion succeeds" do
    ctx = Mw.case!("t1371-ok", :module)
    Mw.set_stamp_hash!(ctx, @x)
    Mw.set_accepted_hashes!(ctx.schema, "fixture_ledger", [@x])
    assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
    assert length(Fx.records(ctx.schema, "fxl_ledger")) == 1
  end

  test "A3 stamp X with an empty or foreign list is refused: hash_mismatch" do
    ctx = Mw.case!("t1371-no", :module)
    Mw.set_stamp_hash!(ctx, @x)
    Mw.set_accepted_hashes!(ctx.schema, "fixture_ledger", ["other"])
    assert hash_mismatch?(ctx)
  end

  test "A3b stamp X in the list but installed != compiled is refused" do
    ctx = Mw.case!("t1371-drift", :module)
    Mw.set_stamp_hash!(ctx, @x)
    Mw.set_installed_hash!(ctx.schema, "fixture_ledger", String.duplicate("d", 64))
    Mw.set_accepted_hashes!(ctx.schema, "fixture_ledger", [@x])
    assert hash_mismatch?(ctx)
  end

  test "A4 the recheck inside the transaction reads the list again (installed flipped)" do
    ctx = Mw.case!("t1371-toctou", :module)
    Mw.set_stamp_hash!(ctx, @x)
    Mw.set_accepted_hashes!(ctx.schema, "fixture_ledger", [@x])
    ScriptTaskFixture.put_env!(:entity_port, FlipPort)
    ScriptTaskFixture.put_env!(:flip_accepted_target, {ctx.schema, "fixture_ledger"})
    assert hash_mismatch?(ctx)
    assert Fx.records(ctx.schema, "fxl_ledger") == []
  end

  test "A7 install_hashes/2: installed row, null hash, uninstalled, not installed" do
    ctx = Mw.case!("t1371-unit", :module)
    Mw.set_accepted_hashes!(ctx.schema, "fixture_ledger", [@x])

    assert {:ok, %{installed: installed, accepted: [@x]}} =
             Installs.install_hashes("fixture_ledger", prefix: ctx.schema)

    assert {:ok, installed} ==
             Installs.installed_manifest_hash("fixture_ledger", prefix: ctx.schema)

    assert {:error, :not_installed} = Installs.install_hashes("nope", prefix: ctx.schema)

    Mw.set_installed_hash!(ctx.schema, "fixture_ledger", nil)

    assert {:error, :no_installed_hash} =
             Installs.install_hashes("fixture_ledger", prefix: ctx.schema)
  end
end
