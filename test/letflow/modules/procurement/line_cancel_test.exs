Code.require_file("procurement_fixture.exs", __DIR__)

defmodule Letflow.Modules.Procurement.LineCancelTest do
  @moduledoc """
  GH #3188 / REQ-558 part 2, criteria 7 and 8 (design tests C7-D1, C7-D2, C6-D1, C8-1..C8-8, C9-1, C9-2,
  C8-R1, C7-R1): `LineEvents.cancel_line/3`, `request_status/2`, the closed-request refusal and the
  routes, on a real tenant. Fulfilled quantity has no writer in this slice, so tests set it with SQL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit.Entry
  alias Letflow.Modules.Procurement.Decisions
  alias Letflow.Modules.Procurement.LineEvent
  alias Letflow.Modules.Procurement.LineEvents
  alias Letflow.Modules.Procurement.PurchaseRequests
  alias Letflow.ProcurementFixture, as: Fixture
  alias Letflow.Repo

  @base "/api/v1/modules/procurement/purchase-requests"

  setup do
    ctx = Fixture.tenant!("gh3188c")
    other = Fixture.tenant!("gh3188d")
    requester = Ecto.UUID.generate()
    approver = Ecto.UUID.generate()
    clerk = Fixture.user!(ctx, ["TENANT_ADMIN"])
    outsider = Fixture.user!(other, ["TENANT_ADMIN"])

    Map.merge(ctx, %{
      requester: requester,
      approver: approver,
      clerk: clerk.user_id,
      admin: clerk,
      outsider: outsider,
      request: three_line_request!(ctx, requester)
    })
  end

  defp three_line_request!(ctx, requester) do
    line = hd(Fixture.params(ctx)["lines"])

    lines = [
      line,
      %{line | "description" => "Nuts"},
      %{line | "description" => "Washers"}
    ]

    {:ok, %{document_id: id}} =
      PurchaseRequests.create(ctx.schema, requester, Fixture.params(ctx, %{"lines" => lines}))

    {:ok, %{version_no: n, content_hash: hash}} =
      PurchaseRequests.submit_for_bpm(ctx.schema, requester, %{
        document_id: id,
        version_no: 1,
        content_hash: nil,
        idempotency_key: "submit-" <> Ecto.UUID.generate()
      })

    %{id: id, version_no: n, hash: hash}
  end

  defp approved(ctx) do
    {:ok, _} =
      Decisions.record(ctx.schema, ctx.approver, %{
        document_id: ctx.request.id,
        version_no: ctx.request.version_no,
        content_hash: ctx.request.hash,
        decision: "approve",
        idempotency_key: "d-" <> Ecto.UUID.generate()
      })

    ctx
  end

  defp key, do: "k-" <> Ecto.UUID.generate()

  defp cancel(ctx, line_no, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          document_id: ctx.request.id,
          line_no: line_no,
          reason: "no longer needed",
          idempotency_key: key()
        },
        overrides
      )

    LineEvents.cancel_line(ctx.schema, ctx.clerk, params)
  end

  defp supplier(ctx, line_no) do
    LineEvents.record_supplier(ctx.schema, ctx.clerk, %{
      document_id: ctx.request.id,
      line_no: line_no,
      source_system: "erp",
      identifier: "S1",
      display_name: "Supplier",
      idempotency_key: key()
    })
  end

  defp reference(ctx, line_no) do
    LineEvents.record_reference(ctx.schema, ctx.clerk, %{
      document_id: ctx.request.id,
      line_no: line_no,
      source_system: "erp",
      identifier: "PO-1",
      kind: "purchase_order",
      idempotency_key: key()
    })
  end

  defp officer(ctx, line_no) do
    LineEvents.record_officer(ctx.schema, ctx.clerk, %{
      document_id: ctx.request.id,
      line_no: line_no,
      officer_id: ctx.clerk,
      idempotency_key: key()
    })
  end

  # No writer of fulfilled_quantity exists in this slice (criterion 10): set it directly.
  defp fulfil!(ctx, line_no, quantity) do
    Repo.query!(
      ~s|INSERT INTO "#{ctx.schema}".procurement_lines (document_id, line_no, fulfilled_quantity, inserted_at) VALUES ($1, $2, $3, now()) ON CONFLICT (document_id, line_no) DO UPDATE SET fulfilled_quantity = EXCLUDED.fulfilled_quantity|,
      [Ecto.UUID.dump!(ctx.request.id), line_no, Decimal.new(quantity)]
    )
  end

  defp rows(ctx), do: Repo.aggregate(LineEvent, :count, prefix: ctx.schema)

  defp audits(ctx, action),
    do: Repo.aggregate(from(e in Entry, where: e.action == ^action), :count, prefix: ctx.schema)

  defp status(ctx), do: LineEvents.request_status(ctx.schema, ctx.request.id)

  describe "derived status (criteria 6 and 7)" do
    test "C7-D1: nothing, partial, closed and cancelled over the real operations", ctx0 do
      ctx = approved(ctx0)
      assert status(ctx) == nil

      fulfil!(ctx, 1, "0.001")
      assert status(ctx) == :partial

      fulfil!(ctx, 1, "3")
      assert {:ok, _} = cancel(ctx, 2)
      assert status(ctx) == :partial
      assert {:ok, _} = cancel(ctx, 3)
      assert status(ctx) == :closed
    end

    test "C7-D1b: all three lines cancelled is Cancelled", ctx0 do
      ctx = approved(ctx0)
      for n <- 1..3, do: assert({:ok, _} = cancel(ctx, n))
      assert status(ctx) == :cancelled
    end

    test "C7-D2: a request without an approved version has no fulfilment status", ctx0 do
      ctx = ctx0
      assert status(ctx) == nil
      assert LineEvents.request_status(ctx.schema, "nope") == nil
    end

    test "C6-D1: the line view shows status, quantity and the cancelled mark; none before approval",
         ctx0 do
      ctx = ctx0
      assert {:ok, %{status: nil, quantity: "3"}} = view(ctx, 1)

      ctx = approved(ctx)
      assert {:ok, %{status: :open, cancelled: nil}} = view(ctx, 1)
      fulfil!(ctx, 1, "1")
      assert {:ok, %{status: :partial}} = view(ctx, 1)
      assert {:ok, _} = cancel(ctx, 2, %{reason: "dropped"})

      assert {:ok, %{status: :cancelled, cancelled: %{reason: "dropped", performer: performer}}} =
               view(ctx, 2)

      assert performer == ctx.clerk
      fulfil!(ctx, 2, "3")
      assert {:ok, %{status: :fulfilled}} = view(ctx, 2)
    end
  end

  describe "cancel_line (criterion 8)" do
    test "C8-1: one event, one audit entry, reason, performer and server time", ctx0 do
      ctx = approved(ctx0)
      assert {:ok, result} = cancel(ctx, 1, %{reason: "  not needed  "})
      assert %{replayed: false, reason: "not needed", performer: performer} = result
      assert performer == ctx.clerk
      assert %DateTime{} = result.recorded_at
      assert rows(ctx) == 1
      assert audits(ctx, "procurement.line_cancel_recorded") == 1
    end

    test "C8-2: the same key replays the first result, one row", ctx0 do
      ctx = approved(ctx0)
      k = key()
      assert {:ok, %{event_id: id}} = cancel(ctx, 1, %{idempotency_key: k})
      assert {:ok, %{replayed: true, event_id: ^id}} = cancel(ctx, 1, %{idempotency_key: k})
      assert rows(ctx) == 1
      assert audits(ctx, "procurement.line_cancel_recorded") == 1
    end

    test "C8-3: another key on an already cancelled line returns the first result", ctx0 do
      ctx = approved(ctx0)
      assert {:ok, %{event_id: id}} = cancel(ctx, 1, %{reason: "first"})

      assert {:ok, %{replayed: true, event_id: ^id, reason: "first"}} =
               cancel(ctx, 1, %{reason: "second"})

      assert rows(ctx) == 1
    end

    test "C8-4: the same key with another reason is refused", ctx0 do
      ctx = approved(ctx0)
      k = key()
      assert {:ok, _} = cancel(ctx, 1, %{idempotency_key: k})

      assert {:error, :idempotency_key_reused} =
               cancel(ctx, 2, %{idempotency_key: k, reason: "other"})

      assert rows(ctx) == 1
    end

    test "C8-5: an unapproved request and a cancelled version refuse, nothing stored", ctx0 do
      ctx = ctx0
      assert {:error, :not_approved} = cancel(ctx, 1)
      assert rows(ctx) == 0

      ctx = approved(ctx)

      {:ok, _} =
        Letflow.Documents.cancel(
          ctx.schema,
          %{document_id: ctx.request.id, version_no: ctx.request.version_no, reason: "withdrawn"},
          ctx.requester
        )

      assert {:error, :not_approved} = cancel(ctx, 1)
      assert rows(ctx) == 0
    end

    test "C8-6: the reason is required, not blank and at most 500 characters", ctx0 do
      ctx = approved(ctx0)

      for reason <- [nil, "", "   ", String.duplicate("x", 501), 5] do
        assert {:error, {:validation, [%{field: "reason"}]}} = cancel(ctx, 1, %{reason: reason})
      end

      assert {:ok, _} = cancel(ctx, 1, %{reason: String.duplicate("x", 500)})
      assert rows(ctx) == 1
    end

    test "C8-7: a Cancelled and a Closed request refuse officer, supplier, reference and cancel",
         ctx0 do
      cancelled = approved(ctx0)
      for n <- 1..3, do: assert({:ok, _} = cancel(cancelled, n))
      assert status(cancelled) == :cancelled
      refused_everywhere(cancelled)

      closed = approved(ctx0)
      fulfil!(closed, 1, "3")
      assert {:ok, _} = cancel(closed, 2)
      assert {:ok, _} = cancel(closed, 3)
      assert status(closed) == :closed
      refused_everywhere(closed)
    end

    test "C8-8: an audit failure rolls the event back", ctx0 do
      ctx = approved(ctx0)
      Repo.query!(~s|ALTER TABLE "#{ctx.schema}".audit_entries RENAME TO audit_entries_gone|)
      assert {:error, :audit_failed} = cancel(ctx, 1)
      Repo.query!(~s|ALTER TABLE "#{ctx.schema}".audit_entries_gone RENAME TO audit_entries|)
      assert rows(ctx) == 0
    end

    test "C9-1: a refusal is counted for :cancel_line and writes no audit entry", ctx0 do
      id = "gh3188-cancel-" <> Ecto.UUID.generate()
      test = self()

      :telemetry.attach(
        id,
        [:letflow, :procurement, :refused],
        fn _e, _m, meta, _c -> send(test, {:refused, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
      ctx = ctx0
      assert {:error, :not_approved} = cancel(ctx, 1)
      assert_receive {:refused, %{action: :cancel_line, reason: :not_approved}}
      assert audits(ctx, "procurement.line_cancel_recorded") == 0
    end

    test "C9-2: another tenant cannot cancel or see tenant A's line", ctx_in do
      ctx = approved(ctx_in)
      other = Fixture.tenant!("gh3188e")

      assert {:error, :not_found} =
               LineEvents.cancel_line(other.schema, Ecto.UUID.generate(), %{
                 document_id: ctx.request.id,
                 line_no: 1,
                 reason: "x",
                 idempotency_key: key()
               })

      assert {:error, :not_found} = LineEvents.line_view(other.schema, ctx.request.id, 1)
      assert LineEvents.request_status(other.schema, ctx.request.id) == nil
      assert rows(ctx) == 0
    end
  end

  describe "routes" do
    test "C8-R1: 201, replay 200, 409 request_closed has the not_approved shape, 403, 404",
         ctx0 do
      ctx = approved(ctx0)
      path = fn n -> "#{@base}/#{ctx.request.id}/lines/#{n}/cancel" end
      body = %{"reason" => "gone", "idempotency_key" => "r-1"}

      conn = call(:post, path.(1), ctx.admin, body)
      assert conn.status == 201
      assert %{"replayed" => false, "reason" => "gone"} = json(conn)
      conn = call(:post, path.(1), ctx.admin, body)
      assert conn.status == 200
      assert %{"replayed" => true} = json(conn)

      for n <- [2, 3],
          do:
            assert(
              call(:post, path.(n), ctx.admin, %{body | "idempotency_key" => "r-#{n}"}).status ==
                201
            )

      closed =
        call(:post, "#{@base}/#{ctx.request.id}/lines/1/supplier", ctx.admin, %{
          "source_system" => "erp",
          "identifier" => "S",
          "display_name" => "S",
          "idempotency_key" => "c-1"
        })

      assert closed.status == 409
      assert %{"reason" => "request_closed", "title" => title} = json(closed)

      unapproved = three_line_request!(ctx, ctx.requester)

      conn =
        call(:post, "#{@base}/#{unapproved.id}/lines/1/cancel", ctx.admin, %{
          body
          | "idempotency_key" => "u-1"
        })

      assert conn.status == 409
      assert %{"reason" => "not_approved", "title" => ^title} = json(conn)

      worker = Fixture.user!(ctx, ["TASK_WORKER"])
      assert call(:post, path.(1), worker, body).status == 403
      assert call(:post, path.(1), ctx.outsider, body).status == 404
    end

    test "C7-R1: GET request shows fulfilment_status", ctx0 do
      ctx = approved(ctx0)
      conn = call(:get, "#{@base}/#{ctx.request.id}", ctx.admin)
      assert conn.status == 200
      assert %{"fulfilment_status" => nil} = json(conn)
      for n <- 1..3, do: assert({:ok, _} = cancel(ctx, n))

      assert %{"fulfilment_status" => "cancelled"} =
               call(:get, "#{@base}/#{ctx.request.id}", ctx.admin) |> json()
    end
  end

  defp refused_everywhere(ctx) do
    before = rows(ctx)
    audits_before = Repo.aggregate(Entry, :count, prefix: ctx.schema)
    assert {:error, :request_closed} = officer(ctx, 1)
    assert {:error, :request_closed} = supplier(ctx, 1)
    assert {:error, :request_closed} = reference(ctx, 1)
    assert {:error, :request_closed} = cancel(ctx, 1, %{reason: "again"}) |> closed_or_replay()
    assert rows(ctx) == before
    assert Repo.aggregate(Entry, :count, prefix: ctx.schema) == audits_before
  end

  # Line 1 of a Cancelled request is already cancelled, so a repeat is a replay; in the Closed
  # request line 1 is Fulfilled and the cancel is refused.
  defp closed_or_replay({:ok, %{replayed: true}}), do: {:error, :request_closed}
  defp closed_or_replay(other), do: other

  defp view(ctx, n), do: LineEvents.line_view(ctx.schema, ctx.request.id, n)

  defp call(method, path, user, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> user.plaintext)
    |> put_req_header("x-tenant-slug", user.slug)
    |> put_req_header("x-trace-id", "t-3188c")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
end
