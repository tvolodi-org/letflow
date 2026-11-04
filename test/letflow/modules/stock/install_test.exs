defmodule Letflow.Modules.Stock.InstallTest do
  @moduledoc """
  REQ-687 / GH #3707 criterion 1 (T-IN-1, T-IN-2) and criterion 3 end to end (T-LP-10): the real
  `stock` module installed on a committed tenant, a posting built by its `declare/2` and posted through
  the core, read back through `Letflow.Ledger.balances/4`. Sandbox `:auto`, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Modules.Stock.LedgerPolicy

  @why "test: REQ-687"
  @sku "11111111-1111-4111-8111-111111111111"
  @loc "33333333-3333-4333-8333-333333333333"
  @unit_a "44444444-4444-4444-8444-444444444444"
  @line "66666666-6666-4666-8666-666666666666"

  setup do
    Fx.setup_auto_mode!()
    Fx.put_registry!(Catalog.ledger_registry())

    previous = Application.fetch_env(:letflow, :modules_uninstall_enabled)
    Application.put_env(:letflow, :modules_uninstall_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:letflow, :modules_uninstall_enabled, value)
        :error -> Application.delete_env(:letflow, :modules_uninstall_enabled)
      end
    end)

    fx = Fx.tenant_fixture!()
    {:ok, registration} = Catalog.fetch_ledger("stock", "stock")
    %{fx: fx, s: fx.schema_name, registration: registration}
  end

  defp opts(s), do: [prefix: s, rationale: @why]

  defp receipt!(ctx, quantity, extra \\ []) do
    command = %{
      cause: "receipt",
      document_type: "t",
      lines: [
        %{
          line_id: @line,
          sku: @sku,
          unit: "pcs",
          quantity: quantity,
          to: %{org_unit: @unit_a, location: @loc}
        }
      ]
    }

    {:ok, posting} = LedgerPolicy.declare(command, ctx.registration)

    Fx.post!(
      Fx.capability(
        ctx.s,
        "receipt",
        posting.legs,
        [
          ledger_id: "stock",
          registration: ctx.registration,
          ensure_storage: false,
          posting: posting
        ] ++ extra
      )
    )
  end

  defp balances(ctx) do
    {:ok, auth} = Ledger.authorize(admin_conn(ctx), "stock", :read)
    {:ok, report} = Ledger.balances(auth, {:posting_seq, :latest}, %{}, %{})
    report
  end

  defp admin_conn(ctx) do
    user = Fx.user!(ctx.fx, ["TENANT_ADMIN"])
    Fx.conn_for(ctx.fx, user, ["TENANT_ADMIN"])
  end

  test "T-IN-1: install creates the storage; a declared receipt posts and reads back", ctx do
    assert {:ok, _} = Installs.install("stock", Ecto.UUID.generate(), opts(ctx.s))
    posted = receipt!(ctx, "5")
    assert posted.ledger_id == "stock"

    report = balances(ctx)
    assert report.ledger_seq == 1

    assert [%{k: [@sku, @loc, @unit_a, "", "" | _], quantity: quantity, unit_ref: "pcs"}] =
             report.rows

    assert Decimal.equal?(Decimal.new(quantity), 5)
  end

  test "T-IN-2: uninstall then reactivate keeps the first posting and accepts a second", ctx do
    assert {:ok, _} = Installs.install("stock", Ecto.UUID.generate(), opts(ctx.s))
    receipt!(ctx, "5")

    assert {:ok, _} = Installs.uninstall("stock", Ecto.UUID.generate(), opts(ctx.s))
    assert {:ok, _} = Installs.reactivate("stock", Ecto.UUID.generate(), opts(ctx.s))

    receipt!(ctx, "2")
    report = balances(ctx)
    assert report.ledger_seq == 2
    assert [%{quantity: quantity}] = report.rows
    assert Decimal.equal?(Decimal.new(quantity), 7)
  end

  test "T-LP-10: a declared write_off hands its reason code to the core and posts", ctx do
    assert {:ok, _} = Installs.install("stock", Ecto.UUID.generate(), opts(ctx.s))
    receipt!(ctx, "5")

    side = %{org_unit: @unit_a, location: @loc}
    line = %{line_id: @line, sku: @sku, unit: "pcs", quantity: "1", from: side}

    {:ok, off} = LedgerPolicy.declare(%{cause: "write_off", lines: [line]}, ctx.registration)
    refute Map.has_key?(off, :reason_code)

    {:ok, off} =
      LedgerPolicy.declare(
        %{cause: "write_off", reason_code: "damaged", lines: [line]},
        ctx.registration
      )

    posted =
      Fx.post!(
        Fx.capability(ctx.s, "write_off", off.legs,
          ledger_id: "stock",
          registration: ctx.registration,
          ensure_storage: false,
          posting: off
        )
      )

    assert Fx.entry_row(ctx.s, posted.entry_id).reason_code == "damaged"
    assert [%{quantity: quantity}] = balances(ctx).rows
    assert Decimal.equal?(Decimal.new(quantity), 4)
  end
end
