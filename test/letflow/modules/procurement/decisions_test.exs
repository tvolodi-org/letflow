Code.require_file("procurement_fixture.exs", __DIR__)

defmodule Letflow.Modules.Procurement.DecisionsTest do
  @moduledoc """
  GH #3162 / REQ-544 part 2, criteria 5, 7, 8, 9 and the module half of 10 (spec:
  state/tasks/T-0746/design.md, tests D1..D5a, C1..C3, V1..V3, X1): `Decisions.record/3`,
  `approved?/3`, `status/2` and `PurchaseRequests.submit_for_bpm/3` on a real tenant.

  Dropped from the design's plan, with the reason: D5b (two concurrent first submits) and D6 (a
  lock timeout while another connection holds the row) need two database connections that
  interleave, and this file runs in the shared Sandbox mode (one connection, `async: false`), so the
  race cannot be forced. The `:no_draft` and `:busy` branches are one-line clauses over the same
  `Documents.issue/2` results the part 1 tests already cover; D5a covers the retry of a finished
  submit.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Documents
  alias Letflow.Modules.Procurement.Decision
  alias Letflow.Modules.Procurement.Decisions
  alias Letflow.Modules.Procurement.PurchaseRequests
  alias Letflow.ProcurementFixture, as: Fixture
  alias Letflow.Repo

  setup do
    ctx = Fixture.tenant!("gh3162d")
    requester = Ecto.UUID.generate()
    approver = Ecto.UUID.generate()

    Map.merge(ctx, %{
      requester: requester,
      approver: approver,
      request: Fixture.issued!(ctx, requester)
    })
  end

  defp decide(ctx, performer, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          document_id: ctx.request.id,
          version_no: ctx.request.version_no,
          content_hash: ctx.request.hash,
          decision: "approve",
          idempotency_key: "k-" <> Ecto.UUID.generate()
        },
        overrides
      )

    Decisions.record(ctx.schema, performer, params)
  end

  defp rows(ctx), do: Repo.aggregate(Decision, :count, prefix: ctx.schema)

  defp audit_count(ctx, action \\ nil) do
    query = if action, do: from(e in Entry, where: e.action == ^action), else: Entry
    Repo.aggregate(query, :count, prefix: ctx.schema)
  end

  defp revise!(ctx, justification) do
    params = Fixture.params(ctx, %{"justification" => justification})

    {:ok, %{version_no: n, content_hash: hash}} =
      PurchaseRequests.revise(ctx.schema, ctx.requester, ctx.request.id, params)

    %{version_no: n, hash: hash}
  end

  defp attach_refusals do
    id = "gh3162-refusals-" <> Ecto.UUID.generate()
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

  describe "operations (criterion 5)" do
    test "D1: record takes the five inputs and stores one decision", ctx do
      assert {:ok, result} = decide(ctx, ctx.approver, %{idempotency_key: "key-1"})
      assert result.decision == :approve
      assert result.performer == ctx.approver
      assert result.replayed == false
      assert rows(ctx) == 1
    end

    test "D2: the same key returns the first result and records one decision", ctx do
      assert {:ok, first} = decide(ctx, ctx.approver, %{idempotency_key: "key-2"})
      audits = audit_count(ctx, "procurement.decision_recorded")

      assert {:ok, again} = decide(ctx, ctx.approver, %{idempotency_key: "key-2"})
      assert again == %{first | replayed: true}
      assert rows(ctx) == 1
      assert audit_count(ctx, "procurement.decision_recorded") == audits
    end

    test "D2b: the replay survives the issue of the next version", ctx do
      assert {:ok, first} = decide(ctx, ctx.approver, %{idempotency_key: "key-2b"})
      revise!(ctx, "Needed more")

      assert {:ok, again} = decide(ctx, ctx.approver, %{idempotency_key: "key-2b"})
      assert again.decision_id == first.decision_id
      assert again.replayed == true
      assert rows(ctx) == 1
    end

    test "D3: the same key with another payload is refused and nothing is added", ctx do
      assert {:ok, _} = decide(ctx, ctx.approver, %{idempotency_key: "key-3"})

      assert {:error, :idempotency_key_reused} =
               decide(ctx, ctx.approver, %{idempotency_key: "key-3", decision: "reject"})

      assert {:error, :idempotency_key_reused} =
               decide(ctx, Ecto.UUID.generate(), %{idempotency_key: "key-3"})

      assert rows(ctx) == 1
    end

    test "D4: the module has no route, threshold, assignee or delegation logic" do
      for file <- Path.wildcard("lib/letflow/modules/procurement/{decisions,router}.ex") do
        # documentation names what is absent; only code is scanned
        code =
          file
          |> File.read!()
          |> String.replace(~r/@(moduledoc|doc) """.*?"""/s, "")
          |> String.replace(~r/#.*$/m, "")
          |> String.downcase()

        refute code =~ ~r/threshold|assignee|delegat/, file
      end
    end

    test "D5: submit_for_bpm issues the open draft and refuses a foreign requester", ctx do
      {:ok, %{document_id: id}} =
        PurchaseRequests.create(ctx.schema, ctx.requester, Fixture.params(ctx))

      args = %{document_id: id, version_no: 1, content_hash: nil, idempotency_key: "s-1"}

      assert {:error, :not_found} =
               PurchaseRequests.submit_for_bpm(ctx.schema, ctx.approver, args)

      assert {:ok, %{version_no: 1, state: :submitted, replayed: false, content_hash: hash}} =
               PurchaseRequests.submit_for_bpm(ctx.schema, ctx.requester, args)

      assert hash =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "D5a: the identical retry replays; other hashes and cancelled versions are refused",
         ctx do
      {:ok, %{document_id: id}} =
        PurchaseRequests.create(ctx.schema, ctx.requester, Fixture.params(ctx))

      args = %{document_id: id, version_no: 1, content_hash: nil, idempotency_key: "s-2"}
      assert {:ok, first} = PurchaseRequests.submit_for_bpm(ctx.schema, ctx.requester, args)

      before =
        {audit_count(ctx),
         Repo.aggregate(Letflow.Documents.DocumentVersion, :count, prefix: ctx.schema)}

      assert {:ok, again} = PurchaseRequests.submit_for_bpm(ctx.schema, ctx.requester, args)
      assert again == %{first | replayed: true}

      assert {:ok, %{replayed: true}} =
               PurchaseRequests.submit_for_bpm(ctx.schema, ctx.requester, %{
                 args
                 | content_hash: first.content_hash
               })

      assert {:error, :binding_refused} =
               PurchaseRequests.submit_for_bpm(ctx.schema, ctx.requester, %{
                 args
                 | content_hash: String.duplicate("a", 64)
               })

      assert {:error, :binding_refused} =
               PurchaseRequests.submit_for_bpm(ctx.schema, ctx.requester, %{args | version_no: 7})

      assert {:error, {:validation, [%{field: "idempotency_key"}]}} =
               PurchaseRequests.submit_for_bpm(ctx.schema, ctx.requester, %{
                 args
                 | idempotency_key: ""
               })

      assert before ==
               {audit_count(ctx),
                Repo.aggregate(Letflow.Documents.DocumentVersion, :count, prefix: ctx.schema)}

      {:ok, _} =
        Documents.cancel(
          ctx.schema,
          %{document_id: id, version_no: 1, reason: "no longer needed"},
          ctx.requester
        )

      assert {:error, :binding_refused} =
               PurchaseRequests.submit_for_bpm(ctx.schema, ctx.requester, %{
                 args
                 | content_hash: first.content_hash
               })
    end
  end

  describe "decision record (criterion 7)" do
    test "C1: an accepted decision stores the fields and writes one audit entry", ctx do
      before = DateTime.utc_now()
      assert {:ok, result} = decide(ctx, ctx.approver, %{decision: "return"})
      later = DateTime.utc_now()

      row = Repo.get!(Decision, result.decision_id, prefix: ctx.schema)
      assert row.decision == :return
      assert row.performer == ctx.approver
      assert row.document_id == ctx.request.id
      assert row.version_no == ctx.request.version_no
      assert row.content_hash == ctx.request.hash
      assert DateTime.compare(row.decided_at, before) != :lt
      assert DateTime.compare(row.decided_at, later) != :gt

      assert [entry] =
               Repo.all(from(e in Entry, where: e.action == "procurement.decision_recorded"),
                 prefix: ctx.schema
               )

      assert entry.actor_id == ctx.approver
      assert entry.resource_id == ctx.request.id

      assert entry.after_state == %{
               "decision" => "return",
               "version_no" => ctx.request.version_no,
               "content_hash" => ctx.request.hash
             }
    end

    test "C2: refusals write no row and no audit entry and are counted in telemetry", ctx do
      attach_refusals()
      audits = audit_count(ctx)

      assert {:error, {:validation, _}} = decide(ctx, ctx.approver, %{decision: "maybe"})
      assert {:error, :self_decision} = decide(ctx, ctx.requester)
      assert {:error, :binding_refused} = decide(ctx, ctx.approver, %{version_no: 5})

      assert {:error, :not_found} =
               decide(ctx, ctx.approver, %{document_id: Ecto.UUID.generate()})

      assert rows(ctx) == 0
      assert audit_count(ctx) == audits

      for reason <- [:validation, :self_decision, :binding_refused, :not_found] do
        assert_received {:refused, %{count: 1}, %{action: :decide, reason: ^reason} = meta}
        assert Map.keys(meta) |> Enum.sort() == [:action, :prefix, :reason]
      end
    end

    test "C3: a failed audit write rolls the decision back", ctx do
      Repo.query!(~s|DROP TABLE "#{ctx.schema}".audit_entries|)

      assert {:error, :audit_failed} = decide(ctx, ctx.approver)
      assert rows(ctx) == 0
    end
  end

  describe "version binding (criterion 8)" do
    test "V1: approve N, issue N+1: neither is approved and an N approval is refused", ctx do
      n = ctx.request.version_no
      assert {:ok, _} = decide(ctx, ctx.approver)
      assert Decisions.approved?(ctx.schema, ctx.request.id, n)

      next = revise!(ctx, "Changed")
      assert next.version_no == n + 1

      refute Decisions.approved?(ctx.schema, ctx.request.id, next.version_no)
      refute Decisions.approved?(ctx.schema, ctx.request.id, n)
      assert {:error, :binding_refused} = decide(ctx, ctx.approver)

      assert {:error, :binding_refused} =
               decide(ctx, ctx.approver, %{version_no: next.version_no})

      assert rows(ctx) == 1
    end

    test "V2: approving N+1 with its own hash is accepted", ctx do
      next = revise!(ctx, "Changed")

      assert {:ok, _} =
               decide(ctx, ctx.approver, %{version_no: next.version_no, content_hash: next.hash})

      assert Decisions.approved?(ctx.schema, ctx.request.id, next.version_no)
    end

    test "V3: approvals can follow each other, a rejected version takes no more", ctx do
      assert {:ok, _} = decide(ctx, ctx.approver)
      assert {:ok, _} = decide(ctx, Ecto.UUID.generate())
      assert Decisions.approved?(ctx.schema, ctx.request.id, ctx.request.version_no)

      other = Fixture.issued!(ctx, ctx.requester)
      reject = %{document_id: other.id, version_no: other.version_no, content_hash: other.hash}
      assert {:ok, _} = decide(ctx, ctx.approver, Map.put(reject, :decision, "reject"))

      assert {:error, :version_closed} =
               decide(ctx, ctx.approver, Map.put(reject, :decision, "approve"))

      refute Decisions.approved?(ctx.schema, other.id, other.version_no)
      assert {:ok, %{state: :rejected, approved: false}} = Decisions.status(ctx.schema, other.id)

      assert {:ok, %{state: :approved, approved: true}} =
               Decisions.status(ctx.schema, ctx.request.id)
    end
  end

  describe "refusal (criterion 9)" do
    test "X1: every unbound approval gives one error and records nothing", ctx do
      cancelled = Fixture.issued!(ctx, ctx.requester)

      {:ok, _} =
        Documents.cancel(
          ctx.schema,
          %{document_id: cancelled.id, version_no: 1, reason: "withdrawn"},
          ctx.requester
        )

      superseded_hash = ctx.request.hash
      revise!(ctx, "Changed")

      results = [
        decide(ctx, ctx.approver, %{content_hash: String.duplicate("b", 64)}),
        decide(ctx, ctx.approver, %{
          document_id: cancelled.id,
          version_no: 1,
          content_hash: cancelled.hash
        }),
        decide(ctx, ctx.approver, %{content_hash: superseded_hash}),
        decide(ctx, ctx.approver, %{version_no: 99})
      ]

      assert results == List.duplicate({:error, :binding_refused}, 4)
      assert rows(ctx) == 0
    end
  end
end
