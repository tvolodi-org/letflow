defmodule Letflow.Scripts.PurchaseRequestExampleTest do
  @moduledoc """
  GH 2534 PR 7c-1 AC20 (design `lib/letflow/design/gh2534-7c-script-handler.md` section 12): the
  worked example `purchase_request_pricing` v1 publishes through the REAL registry path (all
  six stored cases pass, which also proves the lua 1.0.2 `math.floor`/`math.tointeger` and `#`
  behaviour the fixture relies on, residual R7) and, run end to end through `run_tick/2`, sets
  the four output variables and routes by `approval_tier`. The restricted-enum variable-schema
  variant is refused `variable_schema_rejected`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Scripts
  alias Letflow.Support.ScriptTaskFixture, as: F

  @dir "test/support/fixtures/scripts"
  @key "purchase_request_pricing"

  defp fixture(name), do: File.read!(Path.join(@dir, name))
  defp json_fixture(name), do: Jason.decode!(fixture(name))

  defp actor, do: %{user_id: Ecto.UUID.generate(), credential: :oidc, trace_id: "gh2534-7c"}

  defp publish!(schema) do
    body = %{
      "hook_kind" => "service_task",
      "source" => fixture("purchase_request_pricing.lua"),
      "manifest" => json_fixture("purchase_request_pricing.manifest.json"),
      "test_cases" => json_fixture("purchase_request_pricing.test_cases.json")
    }

    assert {:ok, draft} = Scripts.create_draft(schema, @key, body, actor())

    assert {:ok, published} =
             Scripts.publish(schema, @key, draft.version, draft.sha256, actor(), false)

    published
  end

  defp schemas(tier_enum) do
    ints =
      for key <- ~w(tax_rate_bp subtotal_cents tax_cents total_cents),
          do: {key, %{"type" => "integer"}}

    [
      {"line_items", %{"type" => "array"}},
      {"approval_tier", %{"type" => "string", "enum" => tier_enum}}
    ]
    |> Kernel.++(ints)
    |> Enum.map(fn {key, schema} -> %{variable_key: key, json_schema: schema} end)
  end

  defp start!(schema, definition, items, rate) do
    F.start!(
      schema,
      definition,
      %{"line_items" => items, "tax_rate_bp" => rate},
      Ecto.UUID.generate()
    )
  end

  defp item(sku, qty, price), do: %{"sku" => sku, "qty" => qty, "unit_price_cents" => price}

  setup do
    %{t: F.tenant!("gh2534-7c-pr")}
  end

  test "publishes", %{t: t} do
    published = publish!(t.schema_name)
    assert published.status == "published"
    assert published.version == 1
    assert length(published.test_cases) == 6
  end

  test "end to end routes by tier", %{t: t} do
    publish!(t.schema_name)

    definition =
      F.definition!(
        t.schema_name,
        json_fixture("purchase_request_definition.json"),
        schemas(["auto", "manager", "director", "board"])
      )

    auto = start!(t.schema_name, definition, [item("C-3", 3, 333)], 1250)

    manager =
      start!(t.schema_name, definition, [item("A-1", 2, 125_000), item("B-2", 1, 50_000)], 1200)

    {summary, _} = ScriptTaskDispatcher.run_tick([t.schema_name], 0)
    assert summary.applied == 2

    auto_projection = F.projection(t.schema_name, auto)
    assert auto_projection.status == :completed

    assert Map.take(
             auto_projection.variables,
             ~w(subtotal_cents tax_cents total_cents approval_tier)
           ) ==
             %{
               "subtotal_cents" => 999,
               "tax_cents" => 125,
               "total_cents" => 1124,
               "approval_tier" => "auto"
             }

    manager_projection = F.projection(t.schema_name, manager)
    assert manager_projection.status == :active
    assert manager_projection.current_nodes == ["approve"]
    assert manager_projection.variables["approval_tier"] == "manager"
    assert manager_projection.variables["total_cents"] == 336_000

    assert [%{node_id: "approve"}] =
             Repo.all(
               from(x in Letflow.Engine.Task,
                 where: x.instance_id == ^manager and x.status == :pending
               ),
               prefix: t.schema_name
             )
  end

  test "the restricted-enum variant refuses board: variable_schema_rejected", %{t: t} do
    publish!(t.schema_name)

    definition =
      F.definition!(
        t.schema_name,
        json_fixture("purchase_request_definition.json"),
        schemas(["auto", "manager", "director"])
      )

    board = start!(t.schema_name, definition, [item("D-4", 10, 1_000_000)], 0)
    {_row, {:ok, :failed}} = F.run_next!(t.schema_name)

    row = F.row!(t.schema_name, board)
    assert {row.outcome, row.outcome_detail} == {"output_invalid", "variable_schema_rejected"}
    projection = F.projection(t.schema_name, board)
    assert projection.status == :error
    refute Map.has_key?(projection.variables, "approval_tier")
  end
end
