Code.require_file("stock_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.PostingRefusalLogTest do
  @moduledoc """
  T-2991: `Posting.ensure_active/3` logs ONE structured warning on each refusal branch (foreign,
  no-row, rescue), with ids and statuses only; the answer (`:error`) is unchanged.
  Sandbox `:auto`, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.Repo
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.TokenMintFixture

  setup do
    ctx = S.setup_oidc!([:a])
    tenant = S.tenant!("stk-plog", ctx.names.a)
    %{schema: tenant.schema_name}
  end

  defp warnings(log),
    do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "definition_not_active"))

  test "LOG-1 foreign branch: an active row with another owner stamp", ctx do
    import Ecto.Query, only: [from: 2]

    Repo.delete_all(from(d in ProcessDefinition, where: d.name == "stock_receipt"),
      prefix: ctx.schema
    )

    graph = %{
      "nodes" => [%{"id" => "s", "node_type" => "START"}, %{"id" => "e", "node_type" => "END"}],
      "edges" => [%{"id" => "edge", "source" => "s", "target" => "e"}]
    }

    assert {:ok, custom} =
             Definitions.create(
               %{
                 name: "stock_receipt",
                 version: "9.0.0",
                 graph: graph,
                 created_by: Ecto.UUID.generate()
               },
               prefix: ctx.schema
             )

    admin = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])
    authority = Activator.from_auth_context(%{user_id: admin.id, roles: ["TENANT_ADMIN"]}, false)

    assert {:ok, _} = Definitions.activate(custom.id, prefix: ctx.schema, activator: authority)

    log =
      capture_log([level: :warning], fn ->
        assert Posting.ensure_active(ctx.schema, "stock_receipt", nil) == :error
      end)

    assert [line] = warnings(log)
    assert line =~ "reason=foreign"
    assert line =~ "definition=stock_receipt"
    assert line =~ "tenant=#{ctx.schema}"
    assert line =~ "activated=true"
    refute line =~ "graph"
  end

  test "LOG-2 no-row branch: no definition row for the name", ctx do
    import Ecto.Query, only: [from: 2]

    Repo.delete_all(from(d in ProcessDefinition, where: d.name == "stock_receipt"),
      prefix: ctx.schema
    )

    log =
      capture_log([level: :warning], fn ->
        assert Posting.ensure_active(ctx.schema, "stock_receipt", nil) == :error
      end)

    assert [line] = warnings(log)
    assert line =~ "reason=no_row"
    assert line =~ "definition=stock_receipt"
    assert line =~ "tenant=#{ctx.schema}"
    assert line =~ "rows=0"
  end

  test "LOG-3 rescue branch: an exception becomes the refusal, only its module is logged", _ctx do
    log =
      capture_log([level: :warning], fn ->
        assert Posting.ensure_active("no_such_schema_t2991", "stock_receipt", nil) == :error
      end)

    assert [line] = warnings(log)
    assert line =~ "reason=rescued"
    assert line =~ "definition=stock_receipt"
    assert line =~ "tenant=no_such_schema_t2991"
    assert line =~ "exception="
    refute line =~ "does not exist"
  end
end
