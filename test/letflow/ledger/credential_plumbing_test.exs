defmodule Letflow.Ledger.CredentialPlumbingTest do
  @moduledoc """
  REQ-685 criterion 5: `Engine.complete_task/3` carries the `:credential` option to the handler
  context; only `:oidc` posts, `:api_token` and an absent option are refused (fail closed) and
  nothing is written; a completion without a posting line is unchanged by the option.
  """

  use Letflow.DataCase, async: false
  @moduletag :integration

  alias Letflow.Entities.HandlerContext
  alias Letflow.LedgerPostFixture, as: Fx

  defp posting_case(slug) do
    Fx.case!(slug, [Fx.line("post_alpha", %{"posting" => Fx.posting("receipt", "a", "5")})])
  end

  test "CP-1 credential :oidc posts" do
    ctx = posting_case("req685-cp1")
    assert {:ok, _} = Fx.complete(ctx)
    assert {1, 1, 1, 1} = Fx.ledger_counts(ctx.schema)
  end

  test "CP-2 credential :api_token is refused and nothing is written" do
    ctx = posting_case("req685-cp2")

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
             Fx.complete(ctx, credential: :api_token)

    assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
  end

  test "CP-3 no credential option is refused and nothing is written" do
    ctx = posting_case("req685-cp3")

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
             Letflow.Engine.complete_task(
               ctx.task.id,
               %{
                 output_variables: %{},
                 actor_id: ctx.completer.id,
                 idempotency_key: Fx.__info__(:module) |> to_string()
               },
               prefix: ctx.schema
             )

    assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
  end

  test "CP-4 a completion with no posting line is unchanged by the option" do
    for opts <- [[credential: :oidc], [credential: :api_token], [credential: nil]] do
      ctx = Fx.case!("req685-cp4", [Fx.line("plain")])
      assert {:ok, _} = Fx.complete(ctx, opts)
      assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
    end
  end

  test "CP-5 the context field defaults to nil" do
    assert %HandlerContext{
             prefix: "p",
             instance_id: "i",
             origin: {:task, "t"},
             node_id: "n",
             definition_id: "d",
             definition_version: "1",
             line_index: 0,
             actor_id: "a",
             subject_id: "s",
             activator_id: "x",
             handler: %{}
           }.credential == nil
  end
end
