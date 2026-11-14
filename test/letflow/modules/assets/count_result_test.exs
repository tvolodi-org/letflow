Code.require_file("counts_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CountResultTest do
  @moduledoc """
  REQ-819 / GH #4372 (asset count K4) through `Letflow.Modules.Assets.CountResult` and `CountSigner`, over a
  real posted register. Criterion 1: R1, R1b, R1c. Criterion 2: R2. Criterion 3: S1..S5. Criterion 4: G1, G2.
  Criterion 5: F1, F2. Criterion 6: D1..D3. Criterion 7: P1. Also A1, A2 (audit, INV-8) and Z1 (the freeze
  ends). Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.AssetsCountsFixture, as: F
  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Modules.Assets.CountResult
  alias Letflow.Modules.Assets.CountSigner
  alias Letflow.Modules.Assets.Counts
  alias Letflow.Modules.Assets.Documents, as: AssetDocuments
  alias Letflow.Modules.ReadApi

  @moduletag timeout: 300_000

  setup do
    ctx = D.setup!([:a])
    s = ctx.schema
    sw = F.sheet_world!(s, ctx.ma)
    ctx = Map.put(ctx, :sw, sw)
    signer = F.user!(ctx)
    F.signer!(s, signer, "accountant")
    {:ok, Map.merge(ctx, %{signer: signer, auth: F.authorized!(ctx)})}
  end

  # --- helpers ----------------------------------------------------------------------------------

  defp opts(ctx, who \\ nil), do: %{actor_id: who || ctx.signer, authorized: ctx.auth}

  defp read!(ctx, id) do
    assert {:ok, view} = CountResult.result(ctx.schema, id, opts(ctx))
    view
  end

  defp by_no(view), do: Map.new(view["lines"], &{&1["line_no"], &1})

  defp decide(ctx, id, no, body, who \\ nil),
    do: CountResult.decide(ctx.schema, id, no, body, opts(ctx, who))

  defp sign(ctx, id, who \\ nil), do: CountResult.sign(ctx.schema, id, opts(ctx, who))

  defp order(ctx, id) do
    {:ok, h} = ReadApi.lookup(ctx.schema, id, ["assets_count_order"])
    h
  end

  defp audits(s, id),
    do: Repo.all(from(e in Entry, where: e.resource_id == ^id, order_by: e.timestamp), prefix: s)

  defp docs_count(s), do: Repo.aggregate(Letflow.Documents.Document, :count, prefix: s)

  defp doc!(ctx, id) do
    assert {:ok, doc} = AssetDocuments.fetch(ctx.schema, id)
    doc
  end

  defp at(text) do
    {:ok, dt, _} = DateTime.from_iso8601(text)
    dt
  end

  # A live line record edited behind the sheet (criterion 2).
  defp edit_line!(ctx, order_id, asset, changes) do
    row =
      Repo.one!(
        from(l in Latest,
          where:
            l.entity_type == "assets_count_line" and l.deleted == false and
              fragment("?->>'count_order_id' = ?", l.field_values, ^order_id) and
              fragment("?->>'asset_id' = ?", l.field_values, ^asset)
        ),
        prefix: ctx.schema
      )

    attrs = %{
      entity_type: "assets_count_line",
      record_id: row.record_id,
      field_values: Map.merge(row.field_values, changes),
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (test fixture, the owner path of the assets module)
    {:ok, _} =
      Records.update_record(attrs, ctx.schema, ManagedTypes.owner_for!(Letflow.Modules.Assets))
  end

  defp forged_lines(n) do
    for no <- 1..n do
      %{
        "line_no" => no,
        "kind" => "book",
        "asset_id" => Ecto.UUID.generate(),
        "asset_kind" => "fixed",
        "book_material_responsible_id" => Ecto.UUID.generate(),
        "book_quantity" => "1",
        "counted_quantity" => "0"
      }
    end
  end

  # --- criterion 1, 2, 6: the differences, the live edit, the decisions --------------------------

  describe "the differences and the decisions" do
    test "R1/R2/D1/D2/D3: seven kinds, the sheet content only, decisions validated", ctx do
      s = ctx.schema
      w = F.world7!(ctx)
      n = w.no
      c = w.cards
      m = ctx.ma
      view = read!(ctx, w.id)
      lines = by_no(view)

      assert view["status"] == "sheet_signed" and view["line_count"] == 7
      assert view["too_large"] == false and length(view["lines"]) == 7

      assert view["signer_role"] == %{
               "name" => "accountant",
               "configured" => true,
               "held" => true
             }

      assert Enum.sort(Map.keys(lines)) ==
               Enum.sort(for k <- [:f1, :f2, :f3, :f4, :f5, :f6, :nc], do: n[k])

      refute Map.has_key?(lines, n.f7)

      expect = [
        {:f1, "shortage", "writeoff"},
        {:f2, "location_mismatch", "handover"},
        {:f3, "responsible_mismatch", "change"},
        {:f4, "surplus_registered_elsewhere", "handover"},
        {:f5, "surplus_unregistered", "commission"},
        {:nc, "surplus_no_card", "no_register_change"},
        {:f6, "condition", "no_register_change"}
      ]

      for {k, diff, proposed} <- expect do
        l = lines[n[k]]

        assert {l["difference"], l["proposed_decision"], l["decision"]} ==
                 {diff, proposed, proposed},
               "#{k}"

        assert l["document_id"] == nil and l["document_state"] == nil
      end

      f4 = lines[n.f4]
      assert f4["from"]["location_id"] == w.loc3 and f4["quantity"] == "1"
      assert f4["to"]["location_id"] == m.location
      f2 = lines[n.f2]
      assert f2["from"]["location_id"] == m.location and f2["to"]["location_id"] == ctx.sw.loc2
      assert lines[n.f3]["to"]["material_responsible_id"] == ctx.sw.other

      assert lines[n.f1]["quantity"] == "1" and
               lines[n.f5]["to"]["material_responsible_id"] == m.employee

      assert c.f7 not in Enum.map(view["lines"], & &1["asset_id"])

      # R2: edits of the live line records after the sheet was signed change nothing
      edit_line!(ctx, w.id, c.f1, %{"counted_quantity" => "1"})
      edit_line!(ctx, w.id, c.f7, %{"observed_location_id" => ctx.sw.loc2})
      assert read!(ctx, w.id) == view

      # D1: a decision the difference does not allow
      for bad <- ["handover", "bogus", 42, nil] do
        assert {:error, :decision_invalid} = decide(ctx, w.id, n.f1, %{"decision" => bad})
      end

      assert {:error, :decision_invalid} = decide(ctx, w.id, n.nc, %{"decision" => "commission"})
      assert {:error, :decision_invalid} = decide(ctx, w.id, n.f1, %{})

      # D2: the reason of no_register_change
      nrc = %{"decision" => "no_register_change"}

      for bad <- [nil, "", "   ", String.duplicate("x", 501), 5] do
        assert {:error, {:field_invalid, "reason_text"}} =
                 decide(ctx, w.id, n.f1, Map.put(nrc, "reason_text", bad))
      end

      assert {:error, {:field_invalid, "reason_text"}} = decide(ctx, w.id, n.f1, nrc)
      long = String.duplicate("я", 500)
      assert {:ok, l} = decide(ctx, w.id, n.f1, Map.put(nrc, "reason_text", long))
      assert l["decision"] == "no_register_change" and l["reason_text"] == long
      assert l["decided_by"] == ctx.signer and is_binary(l["decided_at"])
      assert by_no(read!(ctx, w.id))[n.f1]["reason_text"] == long

      assert {:error, {:field_not_allowed, "reason_text"}} =
               decide(ctx, w.id, n.f1, %{"decision" => "writeoff", "reason_text" => "x"})

      assert {:error, {:field_not_allowed, "x"}} =
               decide(ctx, w.id, n.f1, %{"decision" => "writeoff", "x" => 1})

      assert {:error, {:field_invalid, "body"}} = decide(ctx, w.id, n.f1, "writeoff")

      # D3: a line without a difference and a line that does not exist
      assert {:error, :line_not_found} = decide(ctx, w.id, n.f7, %{"decision" => "writeoff"})
      assert {:error, :line_not_found} = decide(ctx, w.id, 9999, %{"decision" => "writeoff"})
      assert {:error, :line_not_found} = decide(ctx, w.id, "abc", %{"decision" => "writeoff"})

      assert {:error, :not_found} =
               decide(ctx, Ecto.UUID.generate(), 1, %{"decision" => "writeoff"})

      assert {:error, :not_found} = CountResult.result(s, "not-a-uuid", opts(ctx))

      assert {:error, :not_found} =
               CountResult.result(s, w.id, %{actor_id: ctx.signer, authorized: nil})
    end

    test "R1b/R1c: one location_mismatch carries both; low-value quantities", ctx do
      s = ctx.schema
      m = ctx.ma
      sw = ctx.sw
      both = D.card!(s, "fixed", m.unit)
      low1 = D.card!(s, "low_value", m.unit)
      low2 = D.card!(s, "low_value", m.unit)

      D.commission!(ctx, D.body(m, %{"lines" => [%{"asset_id" => both, "quantity" => "1"}]}))

      D.commission!(
        ctx,
        D.body(m, %{
          "lines" => [
            %{"asset_id" => low1, "quantity" => "5"},
            %{"asset_id" => low2, "quantity" => "5"}
          ]
        })
      )

      id =
        F.ordered!(ctx, %{
          "kinds" => ["fixed", "low_value"],
          "location_ids" => [m.location, sw.loc2]
        })

      F.open!(ctx, id)

      F.record!(ctx, id, both, %{
        "found" => true,
        "observed_location_id" => sw.loc2,
        "observed_material_responsible_id" => sw.other
      })

      F.record!(ctx, id, low1, %{"counted_quantity" => "3"})
      F.record!(ctx, id, low2, %{"counted_quantity" => "8"})
      F.finish!(ctx, id)

      lines = Map.new(read!(ctx, id)["lines"], &{&1["asset_id"], &1})
      assert map_size(lines) == 3

      b = lines[both]
      assert b["difference"] == "location_mismatch" and b["proposed_decision"] == "handover"
      assert b["to"]["location_id"] == sw.loc2 and b["to"]["material_responsible_id"] == sw.other

      assert %{"difference" => "shortage", "proposed_decision" => "writeoff", "quantity" => "2"} =
               lines[low1]

      assert %{
               "difference" => "surplus_unregistered",
               "proposed_decision" => "commission",
               "quantity" => "3"
             } =
               lines[low2]
    end
  end

  # --- criterion 3: who signs --------------------------------------------------------------------

  describe "the signer role" do
    setup ctx do
      id = F.forged_sheet!(ctx, forged_lines(1))
      {:ok, id: id, admin: F.user!(ctx)}
    end

    test "S1: the configured role signs", ctx do
      s = ctx.schema
      F.put_setting!(s, "count_signer_role", "chief-accountant")
      other = F.user!(ctx)
      F.signer!(s, other, "chief-accountant")

      assert %{"name" => "chief-accountant", "configured" => true, "held" => true} =
               read_as(ctx, other)["signer_role"]

      # the default signer does not hold the configured role
      assert {:error, :signer_role_not_held} = sign(ctx, ctx.id)
      assert {:ok, %{"status" => "signed", "signed_by" => ^other}} = sign(ctx, ctx.id, other)
    end

    test "S2: an administrator outside the group is refused, nothing changes", ctx do
      assert {:error, :signer_role_not_held} =
               decide(ctx, ctx.id, 1, %{"decision" => "writeoff"}, ctx.admin)

      assert {:error, :signer_role_not_held} = sign(ctx, ctx.id, ctx.admin)
      assert order(ctx, ctx.id)["status"] == "sheet_signed"
      assert order(ctx, ctx.id)["result_decisions"] == nil
      assert %{"held" => false, "configured" => true} = read_as(ctx, ctx.admin)["signer_role"]
    end

    test "S3: without a setting the role is accountant", ctx do
      assert read!(ctx, ctx.id)["signer_role"]["name"] == "accountant"
      assert {:ok, %{"status" => "signed", "signed_by" => by}} = sign(ctx, ctx.id)
      assert by == ctx.signer
    end

    test "S4: a role that is not set up is refused and shown as not configured", ctx do
      F.put_setting!(ctx.schema, "count_signer_role", "nobody")

      assert %{"configured" => false, "held" => false, "name" => "nobody"} =
               read!(ctx, ctx.id)["signer_role"]

      assert {:error, :signer_role_not_configured} =
               decide(ctx, ctx.id, 1, %{"decision" => "writeoff"})

      assert {:error, :signer_role_not_configured} = sign(ctx, ctx.id)
      assert CountSigner.check(ctx.schema, ctx.signer) == {:error, :signer_role_not_configured}
    end

    test "S5: a platform role row of that name does not count", ctx do
      s = ctx.schema
      F.put_setting!(s, "count_signer_role", "TENANT_AUDITOR")
      F.platform_row!(s, ctx.admin, "TENANT_AUDITOR")

      assert %{"configured" => false, "held" => false} = read_as(ctx, ctx.admin)["signer_role"]
      assert {:error, :signer_role_not_configured} = sign(ctx, ctx.id, ctx.admin)
    end
  end

  defp read_as(ctx, who) do
    assert {:ok, v} = CountResult.result(ctx.schema, ctx.id, opts(ctx, who))
    v
  end

  # --- criterion 4, 7, audit: signing ------------------------------------------------------------

  describe "signing" do
    test "G1/G2/P1/A1: drafts per decision, nothing posted, then the register moves by posting",
         ctx do
      s = ctx.schema
      w = F.world7!(ctx)
      n = w.no
      c = w.cards
      m = ctx.ma
      before = for {_k, a} <- c, do: D.balances(ctx, a)

      assert {:ok, _} = decide(ctx, w.id, n.f6, %{"decision" => "writeoff"})

      assert {:ok, _} =
               decide(ctx, w.id, n.nc, %{
                 "decision" => "no_register_change",
                 "reason_text" => "create the card"
               })

      assert {:ok, _} = decide(ctx, w.id, n.f6, %{"decision" => "writeoff"})

      assert {:ok, %{"status" => "signed"} = view} = sign(ctx, w.id)
      lines = by_no(view)
      signed_at = view["signed_at"]

      assert is_binary(view["result_document_id"]) and
               String.starts_with?(view["result_number"], "ACR")

      drafts = for {_no, l} <- lines, l["document_id"], do: l
      assert length(drafts) == 6
      assert lines[n.nc]["document_id"] == nil and lines[n.nc]["reason_text"] == "create the card"
      assert lines[n.nc]["decision"] == "no_register_change"
      assert view["too_large"] == false and view["line_count"] == 7

      note = fn no -> "count #{view["sheet_number"]} line #{no}" end

      wo = doc!(ctx, lines[n.f1]["document_id"])
      assert wo.kind == "writeoff" and wo.state == "draft" and wo.number == nil
      assert wo.reason_code == "lost" and wo.reason_text == "count " <> view["sheet_number"]
      assert wo.org_unit_id == m.unit and wo.location_id == m.location
      assert wo.material_responsible_id == m.employee and wo.actual_user_id == m.employee2
      assert wo.note == note.(n.f1)
      assert DateTime.compare(at(wo.event_time), at(signed_at)) == :eq
      assert [%{asset_id: a1, quantity: "1.000000000"}] = wo.lines
      assert a1 == c.f1

      ho = doc!(ctx, lines[n.f2]["document_id"])
      assert ho.kind == "handover" and ho.state == "draft"
      assert ho.from_location_id == m.location and ho.to_location_id == ctx.sw.loc2

      assert ho.from_material_responsible_id == m.employee and
               ho.to_material_responsible_id == m.employee

      assert ho.org_unit_id == m.unit and ho.to_org_unit_id == m.unit

      ch = doc!(ctx, lines[n.f3]["document_id"])
      assert ch.kind == "change" and ch.location_id == m.location
      assert ch.from_material_responsible_id == m.employee
      assert ch.to_material_responsible_id == ctx.sw.other

      ho4 = doc!(ctx, lines[n.f4]["document_id"])
      assert ho4.kind == "handover" and ho4.from_location_id == w.loc3
      assert ho4.to_location_id == m.location and ho4.to_material_responsible_id == m.employee

      cm = doc!(ctx, lines[n.f5]["document_id"])
      assert cm.kind == "commission" and cm.location_id == m.location
      assert cm.material_responsible_id == m.employee and cm.org_unit_id == m.unit
      assert [%{asset_id: a5}] = cm.lines
      assert a5 == c.f5

      wo6 = doc!(ctx, lines[n.f6]["document_id"])
      assert wo6.kind == "writeoff" and wo6.reason_code == "broken"

      # nothing posted: every draft is a draft and the register is unchanged
      for l <- drafts, do: assert(doc!(ctx, l["document_id"]).state == "draft")
      assert for({_k, a} <- c, do: D.balances(ctx, a)) == before

      h = order(ctx, w.id)
      assert h["status"] == "signed" and h["signed_by"] == ctx.signer
      assert h["result_document_id"] == view["result_document_id"]

      # the issued result document is what a later read shows
      again = read!(ctx, w.id)

      assert again["lines"] |> Enum.map(& &1["document_id"]) ==
               Enum.map(view["lines"], & &1["document_id"])

      assert Enum.all?(again["lines"], &(&1["document_state"] in [nil, "draft"]))

      # G2: a second sign and a decision after the sign are refused
      assert {:error, :count_state_invalid} = sign(ctx, w.id)

      assert {:error, :count_state_invalid} =
               decide(ctx, w.id, n.f1, %{"decision" => "no_register_change", "reason_text" => "x"})

      # P1: an AssetsPost holder issues and posts one draft; another draft is discarded
      id3 = lines[n.f3]["document_id"]
      D.request(:post, "/documents/#{id3}/issue", ctx.tok_a, %{}) |> D.status!(200)
      D.run_task!(ctx, id3)
      id5 = lines[n.f5]["document_id"]
      D.request(:delete, "/documents/#{id5}", ctx.tok_a) |> D.status!(204)

      states = by_no(read!(ctx, w.id))
      assert states[n.f3]["document_state"] == "posted"
      assert states[n.f5]["document_state"] == "discarded"
      assert states[n.f1]["document_state"] == "draft"

      # A1: audit entries carry ids, status and the line number only
      entries =
        audits(s, w.id)
        |> Enum.filter(
          &(&1.action in ["assets_count.decision_recorded", "assets_count.result_signed"])
        )

      assert Enum.map(entries, & &1.action) ==
               List.duplicate("assets_count.decision_recorded", 3) ++
                 ["assets_count.result_signed"]

      assert Enum.at(entries, 0).after_state == %{"status" => "sheet_signed", "line_no" => n.f6}
      signed = List.last(entries)
      assert signed.before_state == %{"status" => "sheet_signed"}

      assert %{
               "status" => "signed",
               "signer_id" => by,
               "draft_ids" => ids,
               "signer_in_commission" => false
             } =
               signed.after_state

      assert by == ctx.signer
      assert Enum.sort(ids) == Enum.sort(Enum.map(drafts, & &1["document_id"]))
      refute inspect(Enum.map(entries, &{&1.before_state, &1.after_state})) =~ "create the card"
      refute inspect(Enum.map(entries, & &1.after_state)) =~ "quantity"
    end

    test "F1: a refused draft rolls everything back and names the line", ctx do
      s = ctx.schema
      m = ctx.ma
      a = D.card!(s, "fixed", m.unit)
      b = D.card!(s, "fixed", m.unit)
      D.commission!(ctx, D.body(m, %{"lines" => [%{"asset_id" => a, "quantity" => "1"}]}))
      id = F.ordered!(ctx)
      F.open!(ctx, id)
      F.record!(ctx, id, a, %{"found" => false})
      no = F.surplus!(ctx, id, %{"asset_id" => b, "observed_location_id" => m.location})
      F.finish!(ctx, id)

      docs = docs_count(s)

      assert {:error,
              {:line_refused, "field_required", %{"field" => "material_responsible_id"}, ^no}} =
               sign(ctx, id)

      assert docs_count(s) == docs
      assert order(ctx, id)["status"] == "sheet_signed"
      refute Enum.any?(audits(s, id), &(&1.action == "assets_count.result_signed"))

      # the same call after the line is decided away works: the writeoff draft was not kept
      assert {:ok, _} =
               decide(ctx, id, no, %{"decision" => "no_register_change", "reason_text" => "later"})

      assert {:ok, %{"status" => "signed"}} = sign(ctx, id)
    end

    test "F2: more than 200 lines is result_too_large and stores nothing", ctx do
      s = ctx.schema
      id = F.forged_sheet!(ctx, forged_lines(201))
      docs = docs_count(s)

      view = read!(ctx, id)
      assert view["too_large"] == true and view["line_count"] == 201

      assert {:error, :result_too_large} = sign(ctx, id)
      assert {:error, :result_too_large} = decide(ctx, id, 1, %{"decision" => "writeoff"})
      assert docs_count(s) == docs
      assert order(ctx, id)["status"] == "sheet_signed"
    end

    test "Z1: a signed freeze order is no longer frozen", ctx do
      m = ctx.ma
      a = D.card!(ctx.schema, "fixed", m.unit)
      D.commission!(ctx, D.body(m, %{"lines" => [%{"asset_id" => a, "quantity" => "1"}]}))
      id = F.ordered!(ctx, %{"freeze_locations" => true})
      F.open!(ctx, id)
      F.record!(ctx, id, a, %{"found" => true})

      assert {:ok, %{"freeze_state" => "active"}} = Counts.get(ctx.schema, id, F.chair_opts(ctx))
      F.finish!(ctx, id)
      assert {:ok, %{"status" => "signed"}} = sign(ctx, id)

      assert {:ok, %{"freeze_state" => "ended", "status" => "signed"}} =
               Counts.get(ctx.schema, id, F.chair_opts(ctx))
    end
  end

  describe "INV-8" do
    test "A2: an audit failure on decide rolls the decision back", ctx do
      s = ctx.schema
      id = F.forged_sheet!(ctx, forged_lines(1))
      Repo.query!(~s|DROP TABLE "#{s}".audit_entries CASCADE|)

      assert {:error, :audit_failed} = decide(ctx, id, 1, %{"decision" => "writeoff"})
      assert order(ctx, id)["result_decisions"] == nil
    end
  end
end
