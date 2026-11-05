Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.ActorLabelTest do
  @moduledoc """
  GH #3735 R7 (A-1, A-3): `Letflow.Modules.Stock.ActorLabel`, the display name of a user id on the stock reads.
  Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.CountsFixture, as: F
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Stock.ActorLabel
  alias Letflow.StockFixture, as: S

  setup do
    ctx = S.setup_oidc!([:a, :b])
    ta = S.tenant!("alab", ctx.names.a)
    tb = S.tenant!("alab", ctx.names.b)
    fx_a = %{tenant_id: ta.tenant_id, schema_name: ta.schema_name}
    fx_b = %{tenant_id: tb.tenant_id, schema_name: tb.schema_name}
    {:ok, %{a: ta.schema_name, b: tb.schema_name, fx_a: fx_a, fx_b: fx_b}}
  end

  test "A-1 employee-linked user: code - full_name", ctx do
    unit = F.unit!(ctx.a)
    user = Fx.user!(ctx.fx_a, ["TENANT_ADMIN"])
    emp = F.employee!(ctx.a, unit, user: user.id)
    {:ok, rec} = Letflow.Modules.Org.lookup(ctx.a, emp)

    assert ActorLabel.label(ctx.a, user.id) == rec["code"] <> " - " <> rec["full_name"]
  end

  test "A-1 no employee: display name, then username when the display name is blank", ctx do
    named = Fx.user!(ctx.fx_a, ["TENANT_ADMIN"])
    assert ActorLabel.label(ctx.a, named.id) == "GH2552 Role Holder"

    blank = Fx.user!(ctx.fx_a, ["TENANT_ADMIN"]) |> blank_display_name!(ctx.a)
    assert ActorLabel.label(ctx.a, blank.id) == blank.username
  end

  test "A-1 unknown uuid, nil and non-uuid text are nil, never raise", ctx do
    assert ActorLabel.label(ctx.a, Ecto.UUID.generate()) == nil
    assert ActorLabel.label(ctx.a, nil) == nil
    assert ActorLabel.label(ctx.a, "not-a-uuid") == nil
    assert ActorLabel.label(ctx.a, "") == nil
    assert ActorLabel.label(ctx.a, 42) == nil
  end

  test "A-3 a user of another tenant is nil (INV-1/6 negative)", ctx do
    other = Fx.user!(ctx.fx_b, ["TENANT_ADMIN"])
    assert ActorLabel.label(ctx.b, other.id) == "GH2552 Role Holder"
    assert ActorLabel.label(ctx.a, other.id) == nil
    assert ActorLabel.labels(ctx.a, [other.id, nil]) == %{}
  end

  test "labels/2 resolves each distinct id once and leaves misses out", ctx do
    u = Fx.user!(ctx.fx_a, ["TENANT_ADMIN"])
    missing = Ecto.UUID.generate()

    assert ActorLabel.labels(ctx.a, [u.id, u.id, missing, nil]) == %{u.id => "GH2552 Role Holder"}
  end

  defp blank_display_name!(user, schema) do
    user
    |> Ecto.Changeset.change(display_name: "  ")
    |> Letflow.Repo.update!(prefix: schema)
  end
end
