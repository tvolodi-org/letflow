Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.ReversalTest do
  @moduledoc """
  REQ-713 / GH #3748 criteria 7 and 8: the reverse and cancel routes. Committed tenant, Sandbox
  `:auto`, `async: false`; requests through the full `Letflow.Router`.
  Tests: B-REV-1..3, B-REV-7, B-CAN-1..6.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.Support.TokenMintFixture

  setup do
    P.setup!()
  end

  defp reason(conn, status), do: conn |> P.status!(status) |> Map.fetch!("reason")

  defp posted!(ctx) do
    doc = P.issue!(ctx)
    P.post_and_complete!(ctx, doc["id"])
  end

  defp reverse(ctx, id, code \\ "wrong_document", text \\ nil) do
    body =
      if text, do: %{"reason_code" => code, "reason_text" => text}, else: %{"reason_code" => code}

    P.req(ctx, :post, id, "reverse", body)
  end

  defp reversed!(ctx) do
    doc = posted!(ctx)
    reverse(ctx, doc["id"]) |> P.status!(200)
    task = P.pending_task(ctx, doc["id"], "reverse")
    assert {:ok, _} = P.complete(ctx, task)
    doc["id"]
  end

  defp balance_total(ctx) do
    rows =
      S.get("/balances?sku=#{ctx.ma.item}", ctx.tok_a) |> P.status!(200) |> Map.fetch!("rows")

    Enum.reduce(rows, Decimal.new(0), &Decimal.add(Decimal.new(&1["quantity"]), &2))
  end

  describe "reverse" do
    test "B-REV-1 the refusals: states and reasons", ctx do
      draft = P.save!(ctx)
      assert reason(reverse(ctx, draft["id"]), 409) == "document_not_posted"

      issued = P.issue!(ctx)
      assert reason(reverse(ctx, issued["id"]), 409) == "document_not_posted"

      for {code, text} <- [
            {"nope", nil},
            {"other", nil},
            {"other", "   "},
            {"wrong_quantity", String.duplicate("x", 501)}
          ] do
        assert reason(reverse(ctx, issued["id"], code, text), 422) == "reason_invalid", code
      end

      assert reason(P.req(ctx, :post, issued["id"], "reverse", %{}), 422) == "reason_invalid"

      posted = P.post_and_complete!(ctx, issued["id"])
      assert posted["state"] == "posted"
      # 500 characters and a code with no text are accepted
      assert reverse(ctx, issued["id"], "other", String.duplicate("y", 500)).status == 200
      assert reason(reverse(ctx, issued["id"]), 409) == "reversal_pending"
    end

    test "B-REV-2 completion posts one reversal and one reversed mark; balances return", ctx do
      doc = posted!(ctx)
      id = doc["id"]
      assert Decimal.equal?(balance_total(ctx), Decimal.new("12.5"))

      # the reversal definition is activated lazily by the reverse route
      stamped = fn ->
        Repo.one!(from(d in ProcessDefinition, where: d.name == "stock_reversal"),
          prefix: ctx.schema
        )
      end

      assert stamped.().status == :draft
      still_posted = reverse(ctx, id, "other", "wrong supplier") |> P.status!(200)
      assert stamped.().status == :active
      assert still_posted["state"] == "posted"
      assert reason(reverse(ctx, id), 409) == "reversal_pending"

      assert reason(P.req(ctx, :post, id, "cancel", %{"reason" => "x"}), 409) ==
               "reversal_pending"

      task = P.pending_task(ctx, id, "reverse")
      assert {:ok, _} = P.complete(ctx, task)

      read = P.get!(ctx, id)
      assert read["state"] == "reversed" and read["posting_check"] == "ok"
      assert read["reversed_by"] == ctx.holder.id and is_binary(read["reversed_at"])
      assert P.counts(ctx, id) == %{entries: %{"receipt" => 1, "reversal" => 1}, marks: 2}
      assert Decimal.equal?(balance_total(ctx), Decimal.new(0))

      rows = P.movements(ctx, id)
      receipt = Enum.find(rows, &(&1["cause"] == "receipt"))
      reversal = Enum.find(rows, &(&1["cause"] == "reversal"))
      assert reversal["reverses_entry_id"] == receipt["entry_id"]
      assert reversal["reason_code"] == "other"
      assert length(reversal["legs"]) == length(receipt["legs"])

      assert Enum.map(reversal["legs"], &Decimal.negate(Decimal.new(&1["quantity"])))
             |> Enum.sort(Decimal) ==
               Enum.map(receipt["legs"], &Decimal.new(&1["quantity"])) |> Enum.sort(Decimal)

      # a reversal is posted online: its event time is its posting time
      assert reversal["event_time"] == reversal["posting_time"]
      assert reason(reverse(ctx, id), 409) == "document_reversed"

      assert D.request(:get, "/documents?state=reversed", ctx.tok_a)
             |> P.status!(200)
             |> Map.get("rows")
             |> length() == 1
    end

    test "B-REV-3 a TASK_WORKER cannot complete the reverse task; nothing is written", ctx do
      doc = posted!(ctx)
      reverse(ctx, doc["id"]) |> P.status!(200)
      task = P.pending_task(ctx, doc["id"], "reverse")
      worker = TokenMintFixture.role_holder!(ctx.schema, ["TASK_WORKER"])

      assert {:error, _} = P.complete(ctx, task, user: worker)
      assert {:error, _} = P.complete(ctx, task, credential: :api_token)
      assert P.counts(ctx, doc["id"]) == %{entries: %{"receipt" => 1}, marks: 1}
    end

    test "B-REV-7 two receipt entries for the document: 409 posting_inconsistent, nothing started",
         ctx do
      doc = posted!(ctx)
      id = doc["id"]
      other = ctx.ma

      # a second receipt entry written around the stock handler (the gap case of the runbook)
      S.post!(ctx.schema, "receipt", %{
        document_type: "stock_receipt",
        document_id: id,
        lines: [
          S.line(other.item, "1", %{
            to: S.side(other.unit, other.location, %{responsible: other.employee}),
            unit: other.uom
          })
        ]
      })

      assert reason(reverse(ctx, id), 409) == "posting_inconsistent"
      assert P.pending_task(ctx, id, "reverse") == nil
      assert P.get!(ctx, id)["posting_check"] == "mismatch"
    end
  end

  describe "cancel" do
    test "B-CAN-1 cancel after the reversal", ctx do
      id = reversed!(ctx)

      cancelled =
        P.req(ctx, :post, id, "cancel", %{"reason" => "duplicate document"}) |> P.status!(200)

      assert cancelled["state"] == "cancelled" and cancelled["posting_check"] == "ok"

      assert reason(P.req(ctx, :post, id, "cancel", %{"reason" => "again"}), 409) ==
               "document_not_issued"
    end

    test "B-CAN-2 B-CAN-3 cancel of an issued document with nothing posted; the refusals", ctx do
      draft = P.save!(ctx)

      assert reason(P.req(ctx, :post, draft["id"], "cancel", %{"reason" => "x"}), 409) ==
               "document_not_issued"

      Application.put_env(:letflow, :stock_post_start_fail?, true)
      issued = P.issue!(ctx)
      Application.delete_env(:letflow, :stock_post_start_fail?)

      assert P.req(ctx, :post, issued["id"], "cancel", %{"reason" => "   "})
             |> P.status!(422)
             |> Map.get("reason") == "reason_required"

      assert P.req(ctx, :post, issued["id"], "cancel", %{"reason" => String.duplicate("z", 501)})
             |> P.status!(422)
             |> Map.get("reason") == "reason_too_long"

      assert P.req(ctx, :post, issued["id"], "cancel", %{}) |> P.status!(422) |> Map.get("reason") ==
               "reason_required"

      assert P.req(ctx, :post, issued["id"], "cancel", []) |> P.status!(422) |> Map.get("reason") ==
               "reason_invalid"

      cancelled =
        P.req(ctx, :post, issued["id"], "cancel", %{"reason" => "not needed"}) |> P.status!(200)

      assert cancelled["state"] == "cancelled" and cancelled["posting_check"] == "ok"

      pending = P.issue!(ctx)

      assert reason(P.req(ctx, :post, pending["id"], "cancel", %{"reason" => "x"}), 409) ==
               "posting_pending"

      posted = posted!(ctx)

      assert reason(P.req(ctx, :post, posted["id"], "cancel", %{"reason" => "x"}), 409) ==
               "document_posted"

      assert P.get!(ctx, posted["id"])["state"] == "posted"
    end

    test "B-CAN-6 a posting that reaches a cancelled document is detected on read", ctx do
      Application.put_env(:letflow, :stock_post_start_fail?, true)
      issued = P.issue!(ctx)
      Application.delete_env(:letflow, :stock_post_start_fail?)
      id = issued["id"]
      P.req(ctx, :post, id, "cancel", %{"reason" => "cancelled first"}) |> P.status!(200)

      # a second document supplies the posting variables; the generic start names the cancelled one
      other = P.issue!(ctx)
      task = P.pending_task(ctx, other["id"], "post")

      instance =
        Repo.get!(Letflow.EventStore.InstanceProjection, task.instance_id, prefix: ctx.schema)

      posting =
        Map.merge(instance.variables["posting"], %{
          "document_id" => id,
          "client_op_id" => Ecto.UUID.generate()
        })

      vars = Map.merge(instance.variables, %{"document_id" => id, "posting" => posting})

      assert {:ok, _} =
               Letflow.Engine.create(
                 %{
                   definition_name: "stock_receipt",
                   initial_variables: vars,
                   actor_id: ctx.holder.id,
                   idempotency_key: "gen-#{Ecto.UUID.generate()}"
                 },
                 prefix: ctx.schema
               )

      late =
        Repo.one!(
          from(t in Letflow.Engine.Task,
            join: p in Letflow.EventStore.InstanceProjection,
            on: p.instance_id == t.instance_id,
            where: t.status == :pending and fragment("?->>'document_id' = ?", p.variables, ^id)
          ),
          prefix: ctx.schema
        )

      assert {:ok, _} = P.complete(ctx, late)

      read = P.get!(ctx, id)
      assert read["state"] == "cancelled" and read["posting_check"] == "mismatch"
    end
  end
end
