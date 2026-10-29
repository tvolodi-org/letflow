Code.require_file("procurement_fixture.exs", __DIR__)

defmodule Letflow.Modules.Procurement.LineEventsTest do
  @moduledoc """
  GH #3188 / REQ-558 part 1, criteria 1-5, 9 and 10 (init) (spec: state/tasks/T-0763/design.md, tests
  LE-1..LE-12, LE-15, LE-16, LE-18): `LineEvents.record_officer/3`, `record_supplier/3`,
  `record_reference/3` and `line_view/3` on a real tenant.

  Dropped from the design's plan, with the reason: the `unique_violation` replay branch is
  unreachable under the document row lock (as in `Decisions`), and this file runs in the shared
  Sandbox mode (one connection, `async: false`), so no race can be forced.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Documents
  alias Letflow.Modules.Procurement.Decisions
  alias Letflow.Modules.Procurement.LineEvent
  alias Letflow.Modules.Procurement.LineEvents
  alias Letflow.Modules.Procurement.PurchaseRequests
  alias Letflow.ProcurementFixture, as: Fixture
  alias Letflow.Repo

  setup do
    ctx = Fixture.tenant!("gh3188e")
    requester = Ecto.UUID.generate()
    approver = Ecto.UUID.generate()
    clerk = Fixture.user!(ctx, ["TENANT_ADMIN"])
    other_clerk = Fixture.user!(ctx, ["TENANT_ADMIN"])
    request = two_line_request!(ctx, requester)

    Map.merge(ctx, %{
      requester: requester,
      approver: approver,
      clerk: clerk.user_id,
      other_clerk: other_clerk.user_id,
      request: request
    })
  end

  defp two_line_request!(ctx, requester) do
    line = hd(Fixture.params(ctx)["lines"])
    params = Fixture.params(ctx, %{"lines" => [line, %{line | "description" => "Nuts"}]})
    {:ok, %{document_id: id}} = PurchaseRequests.create(ctx.schema, requester, params)

    {:ok, %{version_no: n, content_hash: hash}} =
      PurchaseRequests.submit_for_bpm(ctx.schema, requester, %{
        document_id: id,
        version_no: 1,
        content_hash: nil,
        idempotency_key: "submit-" <> Ecto.UUID.generate()
      })

    %{id: id, version_no: n, hash: hash}
  end

  defp decide!(ctx, decision \\ "approve") do
    {:ok, _} =
      Decisions.record(ctx.schema, ctx.approver, %{
        document_id: ctx.request.id,
        version_no: ctx.request.version_no,
        content_hash: ctx.request.hash,
        decision: decision,
        idempotency_key: "d-" <> Ecto.UUID.generate()
      })
  end

  defp approved(ctx) do
    decide!(ctx)
    ctx
  end

  defp key, do: "k-" <> Ecto.UUID.generate()

  defp officer(ctx, user, overrides \\ %{}, line_no \\ 1, performer \\ nil) do
    params =
      Map.merge(
        %{
          document_id: ctx.request.id,
          line_no: line_no,
          officer_id: user,
          idempotency_key: key()
        },
        overrides
      )

    LineEvents.record_officer(ctx.schema, performer || ctx.clerk, params)
  end

  defp supplier(ctx, id, overrides \\ %{}, line_no \\ 1) do
    params =
      Map.merge(
        %{
          document_id: ctx.request.id,
          line_no: line_no,
          source_system: "erp",
          identifier: id,
          display_name: "Supplier " <> id,
          idempotency_key: key()
        },
        overrides
      )

    LineEvents.record_supplier(ctx.schema, ctx.clerk, params)
  end

  defp reference(ctx, overrides \\ %{}, line_no \\ 1) do
    params =
      Map.merge(
        %{
          document_id: ctx.request.id,
          line_no: line_no,
          source_system: "erp",
          identifier: "PO-1",
          kind: "purchase_order",
          idempotency_key: key()
        },
        overrides
      )

    LineEvents.record_reference(ctx.schema, ctx.clerk, params)
  end

  defp rows(ctx), do: Repo.aggregate(LineEvent, :count, prefix: ctx.schema)

  defp audit_count(ctx, action \\ nil) do
    query = if action, do: from(e in Entry, where: e.action == ^action), else: Entry
    Repo.aggregate(query, :count, prefix: ctx.schema)
  end

  defp view!(ctx, line_no \\ 1) do
    {:ok, view} = LineEvents.line_view(ctx.schema, ctx.request.id, line_no)
    view
  end

  defp attach_refusals do
    id = "gh3188-refusals-" <> Ecto.UUID.generate()
    test = self()

    :telemetry.attach(
      id,
      [:letflow, :procurement, :refused],
      fn _event, measurements, metadata, _config ->
        send(test, {:refused, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "officer assignment (criterion 1)" do
    test "LE-1: one event with officer, performer, server time and key; replay writes nothing",
         ctx do
      ctx = approved(ctx)
      before_time = DateTime.utc_now()

      assert {:ok, first} = officer(ctx, ctx.clerk, %{idempotency_key: "o-1"})
      assert first.user_id == ctx.clerk
      assert first.performer == ctx.clerk
      assert first.replayed == false
      assert DateTime.compare(first.recorded_at, before_time) in [:gt, :eq]
      assert rows(ctx) == 1
      assert audit_count(ctx, "procurement.line_officer_recorded") == 1

      assert {:ok, again} = officer(ctx, ctx.clerk, %{idempotency_key: "o-1"})
      assert again == %{first | replayed: true}
      assert rows(ctx) == 1
      assert audit_count(ctx, "procurement.line_officer_recorded") == 1
    end

    test "LE-2: the same key with another officer is refused and nothing is added", ctx do
      ctx = approved(ctx)
      assert {:ok, _} = officer(ctx, ctx.clerk, %{idempotency_key: "o-2"})

      assert {:error, :idempotency_key_reused} =
               officer(ctx, ctx.other_clerk, %{idempotency_key: "o-2"})

      assert {:error, :idempotency_key_reused} =
               officer(ctx, ctx.clerk, %{idempotency_key: "o-2"}, 2)

      assert rows(ctx) == 1
    end

    test "LE-3: two different users in turn both succeed; the view shows the second", ctx do
      ctx = approved(ctx)
      assert {:ok, _} = officer(ctx, ctx.clerk)
      assert {:ok, _} = officer(ctx, ctx.other_clerk, %{}, 1, ctx.other_clerk)

      view = view!(ctx)
      assert view.officer.user_id == ctx.other_clerk
      assert view.officer.performer == ctx.other_clerk
      assert Enum.map(view.history.officer, & &1.user_id) == [ctx.clerk, ctx.other_clerk]

      source = File.read!("lib/letflow/modules/procurement/line_events.ex")

      refute strip_doc(source) =~ ~r/escalat|queue|delegat|Enum.random/i
    end

    test "LE-4: an unknown officer id is a validation error and nothing is stored", ctx do
      ctx = approved(ctx)

      assert {:error, {:validation, [%{field: "officer_id", code: "unknown"}]}} =
               officer(ctx, Ecto.UUID.generate())

      assert {:error, {:validation, [%{field: "officer_id", code: "invalid"}]}} =
               officer(ctx, "not-a-uuid")

      assert rows(ctx) == 0
    end
  end

  # the moduledoc legitimately says "no chooser, queue, escalation or delegation logic"
  defp strip_doc(source) do
    [_doc, rest] = String.split(source, ~s|  """\n\n  import Ecto.Query|, parts: 2)
    rest
  end

  describe "supplier and reference (criterion 2)" do
    test "LE-5: supplier first, then reference; each is its own event", ctx do
      ctx = approved(ctx)
      assert {:ok, s} = supplier(ctx, "S1")
      assert s.event_kind == :supplier
      view = view!(ctx)
      assert view.supplier.identifier == "S1"
      assert view.procurement_document == nil

      assert {:ok, r} = reference(ctx)
      assert r.event_kind == :reference
      view = view!(ctx)
      assert view.supplier.identifier == "S1"
      assert %{identifier: "PO-1", kind: "purchase_order"} = view.procurement_document
      assert rows(ctx) == 2
    end

    test "LE-6: a reference before any supplier is accepted and shown", ctx do
      ctx = approved(ctx)
      assert {:ok, _} = reference(ctx, %{kind: "contract", identifier: "C-9"})
      view = view!(ctx)
      assert view.supplier == nil
      assert %{identifier: "C-9", kind: "contract"} = view.procurement_document
    end

    test "LE-7: each operation writes one event and one audit entry; a failed audit rolls back",
         ctx do
      ctx = approved(ctx)
      assert {:ok, _} = officer(ctx, ctx.clerk)
      assert {:ok, _} = supplier(ctx, "S1")
      assert {:ok, _} = reference(ctx)

      for action <- ~w(officer supplier reference) do
        assert audit_count(ctx, "procurement.line_#{action}_recorded") == 1
      end

      assert rows(ctx) == 3

      Repo.query!(~s|DROP TABLE "#{ctx.schema}".audit_entries|)
      assert {:error, :audit_failed} = supplier(ctx, "S2")
      assert rows(ctx) == 3
    end
  end

  describe "reference shape (criterion 3)" do
    test "LE-8: the error names each missing field and nothing is stored", ctx do
      ctx = approved(ctx)

      assert {:error, {:validation, errors}} =
               LineEvents.record_supplier(ctx.schema, ctx.clerk, %{
                 document_id: ctx.request.id,
                 line_no: 1,
                 source_system: " ",
                 idempotency_key: key()
               })

      assert errors == [
               %{field: "source_system", code: "required"},
               %{field: "identifier", code: "required"},
               %{field: "display_name", code: "required"}
             ]

      assert {:error, {:validation, [%{field: "kind", code: "required"}]}} =
               reference(ctx, %{kind: nil})

      assert {:error, {:validation, [%{field: "kind", code: "invalid"}]}} =
               reference(ctx, %{kind: "invoice"})

      assert {:error, {:validation, [%{field: "idempotency_key", code: "required"}]}} =
               reference(ctx, %{idempotency_key: nil})

      assert {:error, {:validation, [%{field: "identifier", code: "invalid"}]}} =
               reference(ctx, %{identifier: String.duplicate("x", 129)})

      assert {:error, {:validation, [%{field: "display_name", code: "invalid"}]}} =
               supplier(ctx, "S1", %{display_name: String.duplicate("x", 201)})

      assert rows(ctx) == 0

      %{rows: tables} =
        Repo.query!(
          "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 " <>
            "AND (table_name LIKE '%supplier%' OR table_name LIKE '%purchase_order%')",
          [ctx.schema]
        )

      assert tables == []
    end
  end

  describe "line view (criterion 4)" do
    test "LE-9: a fresh line has nothing but absent values, not empty strings", ctx do
      ctx = approved(ctx)

      assert %{officer: nil, supplier: nil, procurement_document: nil} = view = view!(ctx)
      assert view.history == %{officer: [], supplier: [], procurement_document: []}
      assert view.fulfilled_quantity == "0"
    end

    test "LE-10: supplier A then B shows B and lists both in order", ctx do
      ctx = approved(ctx)
      assert {:ok, _} = supplier(ctx, "A")
      assert {:ok, _} = supplier(ctx, "B")

      view = view!(ctx)
      assert view.supplier.identifier == "B"
      assert Enum.map(view.history.supplier, & &1.identifier) == ["A", "B"]
      assert Enum.all?(view.history.supplier, &(&1.performer == ctx.clerk and &1.recorded_at))
      assert view!(ctx, 2).supplier == nil
    end
  end

  describe "approval precondition (criterion 5)" do
    defp all_three(ctx) do
      [officer(ctx, ctx.clerk), supplier(ctx, "S1"), reference(ctx)]
    end

    test "LE-11: not approved, rejected, returned, revised or cancelled: all refused", ctx do
      assert all_three(ctx) == List.duplicate({:error, :not_approved}, 3)

      decide!(ctx, "reject")
      assert all_three(ctx) == List.duplicate({:error, :not_approved}, 3)
      assert rows(ctx) == 0
    end

    test "LE-11b: returned, revised after approval and cancelled", ctx do
      decide!(ctx, "return")
      assert all_three(ctx) == List.duplicate({:error, :not_approved}, 3)

      other = %{ctx | request: two_line_request!(ctx, ctx.requester)}
      decide!(other)
      assert {:ok, _} = supplier(other, "S1")

      {:ok, _} =
        PurchaseRequests.revise(
          ctx.schema,
          ctx.requester,
          other.request.id,
          Fixture.params(ctx, %{"justification" => "More"})
        )

      assert all_three(other) == List.duplicate({:error, :not_approved}, 3)
      assert rows(other) == 1

      third = %{ctx | request: two_line_request!(ctx, ctx.requester)}
      decide!(third)

      {:ok, _} =
        Documents.cancel(
          ctx.schema,
          %{document_id: third.request.id, version_no: third.request.version_no, reason: "no"},
          ctx.requester
        )

      assert all_three(third) == List.duplicate({:error, :not_approved}, 3)
    end

    test "LE-12: after approval all three succeed", ctx do
      ctx = approved(ctx)
      assert [{:ok, _}, {:ok, _}, {:ok, _}] = all_three(ctx)
    end
  end

  describe "refusals and not-found (criterion 9)" do
    test "LE-15: refusals write no audit row and are counted without ids", ctx do
      ctx = approved(ctx)
      attach_refusals()
      assert {:ok, _} = supplier(ctx, "S1", %{idempotency_key: "r-1"})
      unapproved = %{ctx | request: two_line_request!(ctx, ctx.requester)}
      audits = audit_count(ctx)
      events = rows(ctx)

      assert {:error, {:validation, _}} = supplier(ctx, "S1", %{identifier: nil})
      assert {:error, :idempotency_key_reused} = supplier(ctx, "S2", %{idempotency_key: "r-1"})
      assert {:error, :not_approved} = supplier(unapproved, "S1")

      assert audit_count(ctx) == audits
      assert rows(ctx) == events

      for reason <- [:validation, :idempotency_key_reused, :not_approved] do
        assert_received {:refused, %{count: 1},
                         %{action: :record_supplier, reason: ^reason} = meta}

        assert Map.keys(meta) |> Enum.sort() == [:action, :prefix, :reason]
      end
    end

    test "LE-16: absent, malformed, foreign and other-type documents answer alike", ctx do
      ctx = approved(ctx)
      base = %{officer_id: ctx.clerk, idempotency_key: "n-1"}
      audits = audit_count(ctx)

      for {id, line} <- [
            {Ecto.UUID.generate(), 1},
            {"nope", 1},
            {ctx.request.id, 3},
            {ctx.request.id, 0},
            {ctx.request.id, "x"},
            {ctx.request.id, nil}
          ] do
        assert {:error, :not_found} =
                 LineEvents.record_officer(
                   ctx.schema,
                   ctx.clerk,
                   Map.merge(base, %{document_id: id, line_no: line})
                 )

        assert {:error, :not_found} = LineEvents.line_view(ctx.schema, id, line)
      end

      assert rows(ctx) == 0
      assert audit_count(ctx) == audits
      assert {:error, :not_found} = LineEvents.record_officer("no_such_schema", ctx.clerk, base)
    end
  end

  describe "fulfilled quantity (criterion 10, init)" do
    test "LE-18: the field is 0 with and without events and only read", ctx do
      ctx = approved(ctx)
      assert view!(ctx).fulfilled_quantity == "0"
      assert {:ok, _} = supplier(ctx, "S1")

      %{rows: [[quantity]]} =
        Repo.query!(
          ~s|SELECT fulfilled_quantity::text FROM "#{ctx.schema}".procurement_lines WHERE document_id = $1 AND line_no = 1|,
          [Ecto.UUID.dump!(ctx.request.id)]
        )

      assert Decimal.equal?(Decimal.new(quantity), 0)
      assert view!(ctx).fulfilled_quantity == "0"
      assert {:ok, _} = supplier(ctx, "S2")
      assert Repo.aggregate(Letflow.Modules.Procurement.Line, :count, prefix: ctx.schema) == 1

      sources =
        for file <- Path.wildcard("lib/**/*.ex"),
            File.read!(file) =~ "fulfilled_quantity",
            do: file

      # the schema, the reader and nothing else mentions the column; no assignment anywhere
      assert Enum.sort(sources) == [
               "lib/letflow/modules/procurement/line.ex",
               "lib/letflow/modules/procurement/line_events.ex"
             ]

      # the only write that touches procurement_lines leaves the column to its default; the one
      # "fulfilled_quantity:" in the module is the view key that reads it
      source = File.read!("lib/letflow/modules/procurement/line_events.ex")
      refute source =~ ~r/\[%\{[^}]*fulfilled_quantity/
      refute source =~ ~r/set:\s*\[[^\]]*fulfilled_quantity/
      refute source =~ "Ledger"
    end
  end
end
