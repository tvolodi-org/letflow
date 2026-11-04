Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountDifferencesTest do
  @moduledoc """
  REQ-717 / GH #3764 criteria 2 to 5 (S1..S2, D1..D6, G1..G3, A1): the signing of the count sheet, the
  differences sheet and its signing, through the `Counts` delegates, on a committed fresh tenant with
  real ledger postings. `async: false`, Sandbox `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.CountsFixture, as: F
  alias Letflow.Documents
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Ledger
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.ReadApi
  alias Letflow.Modules.Stock.Counts
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S

  setup do
    ctx = S.setup_oidc!([:a])
    t = S.tenant!("cdf", ctx.names.a)
    s = t.schema_name
    w = F.world!(s)
    fx = %{tenant_id: t.tenant_id, schema_name: s}

    chair_user = Fx.user!(fx, ["TENANT_ADMIN"])
    member_user = Fx.user!(fx, ["TENANT_ADMIN"])
    chair = F.employee!(s, w.unit, user: chair_user.id)
    member = F.employee!(s, w.unit, user: member_user.id)
    # a member and a responsible person without a user link sign on paper too
    paper_member = F.employee!(s, w.unit, user: nil)
    resp = F.employee!(s, w.unit, user: nil)
    w = %{w | chair: chair, members: [member, paper_member], chair_user: chair_user.id}

    {:ok,
     %{
       fx: fx,
       s: s,
       w: w,
       chair_user: chair_user,
       member_user: member_user,
       chair: chair,
       member: member,
       paper_member: paper_member,
       resp: resp
     }}
  end

  # --- helpers ----------------------------------------------------------------------------------

  defp opts(user, extra \\ %{}), do: Map.merge(%{actor_id: user.id, scope: :all}, extra)

  defp window do
    now = DateTime.utc_now()

    %{
      "planned_start" => DateTime.to_iso8601(DateTime.add(now, -3600)),
      "planned_end" => DateTime.to_iso8601(DateTime.add(now, 20 * 3600))
    }
  end

  defp receipt!(c, sku, qty, loc),
    do: S.post!(c.s, "receipt", %{lines: [S.line(sku, qty, %{to: S.side(c.w.unit, loc)})]})

  defp live(s, type),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == ^type and not l.deleted), :count,
        prefix: s
      )

  defp audits(s, action), do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: s)

  defp view(c, id) do
    {:ok, v} = Counts.get(c.s, id, opts(c.chair_user))
    v
  end

  defp signatures(c, id) do
    {:ok, %{"rows" => rows}} = Counts.signatures(c.s, id, opts(c.chair_user))
    rows
  end

  # A `counted` count: sku1 10 at a counted 7 (shortage 3), sku2 4 at a1 counted 4 (no difference),
  # a surplus line of 2 with a paper-only responsible person. Returns the id.
  defp counted!(c, surplus \\ true, short \\ true) do
    sku1 = S.uuid()
    sku2 = S.uuid()
    receipt!(c, sku1, "10", c.w.a)
    receipt!(c, sku2, "4", c.w.a1)
    {:ok, v} = Counts.create(c.s, F.input(c.w, window()), opts(c.chair_user))
    {:ok, i} = Counts.issue(c.s, v["id"], opts(c.chair_user))
    id = i["id"]

    {:ok, auth} =
      Ledger.authorize(Fx.conn_for(c.fx, c.chair_user, ["TENANT_ADMIN"]), "stock", :read)

    {:ok, _} = Counts.open(c.s, id, opts(c.chair_user, %{authorized: auth}))

    {:ok, page} = Counts.lines(c.s, id, %{"limit" => 200}, opts(c.chair_user))

    for l <- page.rows do
      qty = if short and l["catalog_item_id"] == sku1, do: "7", else: l["book_quantity"]
      {:ok, _} = Counts.record_count(c.s, id, l["line_no"], qty, opts(c.chair_user))
    end

    if surplus do
      m = D.masters!(c.s)

      {:ok, _} =
        Counts.add_surplus_line(
          c.s,
          id,
          %{
            "location_id" => c.w.a1,
            "catalog_item_id" => m.item,
            "unit_ref" => m.uom,
            "counted_quantity" => "2",
            "responsible_employee_id" => c.resp
          },
          opts(c.member_user)
        )
    end

    {:ok, %{"status" => "counted"}} = Counts.close_counting(c.s, id, opts(c.chair_user))
    id
  end

  defp everyone(c), do: [c.chair, c.member, c.paper_member, c.resp]

  defp sheet_signed!(c, id) do
    {:ok, v} = Counts.mark_sheet_signed(c.s, id, everyone(c), opts(c.chair_user))
    v
  end

  defp issued!(c, id) do
    sheet_signed!(c, id)
    {:ok, v} = Counts.issue_differences(c.s, id, opts(c.chair_user))
    v
  end

  defp doc_content(c, doc_id) do
    Repo.one(
      from(dv in Letflow.Documents.DocumentVersion,
        where: dv.document_id == ^doc_id,
        select: dv.content
      ),
      prefix: c.s
    )
  end

  # --- sheet signing (criterion 2) --------------------------------------------------------------

  describe "mark_sheet_signed" do
    test "S1 the chair marks the exact set: one row per signer, count stays counted", c do
      id = counted!(c)

      assert {:ok, v} =
               Counts.mark_sheet_signed(c.s, id, Enum.reverse(everyone(c)), opts(c.chair_user))

      assert v["status"] == "counted" and is_binary(v["sheet_signed_at"])

      rows = signatures(c, id)
      assert Enum.sort(Enum.map(rows, & &1["employee_id"])) == Enum.sort(everyone(c))

      assert Enum.all?(
               rows,
               &(&1["document_kind"] == "sheet" and &1["marked_by"] == c.chair_user.id)
             )

      assert Enum.all?(
               rows,
               &(&1["document_id"] == v["sheet_document_id"] and &1["version_no"] == 1)
             )

      role = fn e -> Enum.find(rows, &(&1["employee_id"] == e))["signer_role"] end

      assert {role.(c.chair), role.(c.member), role.(c.paper_member), role.(c.resp)} ==
               {"chair", "member", "member", "responsible"}

      assert [e] = audits(c.s, "stock.count.sheet_signed")
      assert e.resource_id == id and e.after_state["status"] == "counted"
      assert Enum.sort(e.after_state["signer_employee_ids"]) == Enum.sort(everyone(c))
      refute inspect(e.after_state) =~ "quantity"
    end

    test "S2 refusals store nothing", c do
      id = counted!(c)
      mark = &Counts.mark_sheet_signed(c.s, id, &1, opts(&2))

      assert {:error, :not_chair} = mark.(everyone(c), c.member_user)
      assert {:error, :signers_incomplete} = mark.(tl(everyone(c)), c.chair_user)
      assert {:error, :signers_incomplete} = mark.([], c.chair_user)
      stranger = Ecto.UUID.generate()

      assert {:error, {:field_invalid, "signer_employee_ids"}} =
               mark.([stranger | everyone(c)], c.chair_user)

      assert {:error, {:field_invalid, "signer_employee_ids"}} =
               mark.([c.chair | everyone(c)], c.chair_user)

      assert {:error, {:field_invalid, "signer_employee_ids"}} = mark.(["nope"], c.chair_user)
      assert {:error, {:field_invalid, "signer_employee_ids"}} = mark.("x", c.chair_user)

      assert {:error, :not_found} =
               Counts.mark_sheet_signed(c.s, Ecto.UUID.generate(), [], opts(c.chair_user))

      assert live(c.s, "count_signature") == 0
      assert audits(c.s, "stock.count.sheet_signed") == []
      assert is_nil(view(c, id)["sheet_signed_at"])

      sheet_signed!(c, id)
      assert {:error, :sheet_already_signed} = mark.(everyone(c), c.chair_user)
      assert live(c.s, "count_signature") == 4

      {:ok, v} = Counts.create(c.s, F.input(c.w, window()), opts(c.chair_user))

      assert {:error, :count_state_invalid} =
               Counts.mark_sheet_signed(c.s, v["id"], [], opts(c.chair_user))
    end
  end

  # --- differences (criterion 3) ----------------------------------------------------------------

  describe "issue_differences" do
    test "D1 D2 lines from the issued sheet content, header fields, document issued", c do
      id = counted!(c)
      sheet = sheet_signed!(c, id)

      # D2: a change of the live line record after the close does not reach the differences
      {:ok, page} = Counts.lines(c.s, id, %{"limit" => 200}, opts(c.chair_user))

      equal =
        Enum.find(
          page.rows,
          &(&1["kind"] == "stock" and &1["counted_quantity"] == &1["book_quantity"])
        )

      live_line =
        Repo.one(
          from(l in Latest,
            where:
              l.entity_type == "count_sheet_line" and
                fragment("?->>'line_no' = ?", l.field_values, ^to_string(equal["line_no"]))
          ),
          prefix: c.s
        )

      fv = live_line.field_values |> Map.put("counted_quantity", "999")
      owner = ManagedTypes.owner_for!(Letflow.Modules.Stock)

      # scope-all: SEC-518-R1 (test fixture edit of a live line)
      {:ok, _} =
        Records.update_record(
          %{
            entity_type: "count_sheet_line",
            record_id: live_line.record_id,
            field_values: fv,
            actor_id: c.chair_user.id,
            idempotency_key: "t:" <> Ecto.UUID.generate()
          },
          c.s,
          owner
        )

      assert {:ok, v} = Counts.issue_differences(c.s, id, opts(c.chair_user))
      assert v["status"] == "counted" and is_binary(v["differences_document_id"])

      assert v["differences_number"] =~ ~r/\ACD-\d{4}-0001\z/ and
               is_binary(v["differences_issued_at"])

      content = doc_content(c, v["differences_document_id"])
      assert content["sheet_document_id"] == sheet["sheet_document_id"]
      assert content["sheet_version_no"] == 1
      assert content["cut_off_at"] == v["cut_off_at"] and content["cutoff_seq"] == v["cutoff_seq"]
      assert content["count_order_id"] == id

      assert [short, plus] = content["lines"]
      assert {short["direction"], short["difference"]} == {"shortage", "-3.000000000"}
      assert short["book_quantity"] =~ "10" and short["counted_quantity"] =~ "7"

      assert {plus["direction"], plus["difference"], plus["kind"]} ==
               {"surplus", "2.000000000", "surplus"}

      assert plus["responsible_employee_id"] == c.resp
      refute Map.has_key?(short, "responsible_employee_id")

      assert {:ok, read} = Counts.differences(c.s, id, opts(c.chair_user))
      assert read["lines"] == content["lines"] and read["number"] == v["differences_number"]
      assert is_binary(read["content_hash"]) and read["version_no"] == 1
      assert [_] = audits(c.s, "stock.count.differences_issued")
    end

    test "D3 state refusals", c do
      id = counted!(c)
      assert {:error, :differences_not_issued} = Counts.differences(c.s, id, opts(c.chair_user))
      assert {:error, :sheet_not_signed} = Counts.issue_differences(c.s, id, opts(c.chair_user))
      sheet_signed!(c, id)
      assert {:error, :not_chair} = Counts.issue_differences(c.s, id, opts(c.member_user))
      {:ok, _} = Counts.issue_differences(c.s, id, opts(c.chair_user))

      assert {:error, :differences_already_issued} =
               Counts.issue_differences(c.s, id, opts(c.chair_user))

      {:ok, v} = Counts.create(c.s, F.input(c.w, window()), opts(c.chair_user))

      assert {:error, :count_state_invalid} =
               Counts.issue_differences(c.s, v["id"], opts(c.chair_user))
    end

    test "D4 more than 200 difference lines are refused before any document call", c do
      id = counted!(c, false)

      {:ok, _} =
        Counts.mark_sheet_signed(c.s, id, [c.chair, c.member, c.paper_member], opts(c.chair_user))

      header = ReadApi.lookup(c.s, id, ["count_order"]) |> elem(1)

      big =
        for n <- 1..201 do
          %{
            "line_no" => n,
            "kind" => "stock",
            "location_id" => c.w.a,
            "catalog_item_id" => Ecto.UUID.generate(),
            "unit_ref" => "pcs",
            "book_quantity" => "1",
            "counted_quantity" => "2"
          }
        end

      # The fixture is built directly: a counted order whose issued sheet carries 201 differing lines.
      {:ok, %{document: doc}} =
        Documents.create_draft(
          c.s,
          %{type_key: "count.sheet", issuing_org_unit_id: c.w.unit, content: %{"lines" => big}},
          c.chair_user.id
        )

      {:ok, _} = Documents.issue(c.s, %{document_id: doc.id, actor_id: c.chair_user.id})

      fv =
        header |> Map.drop(["record_id", "entity_type"]) |> Map.put("sheet_document_id", doc.id)

      # scope-all: SEC-518-R1 (test fixture edit of the header)
      {:ok, _} =
        Records.update_record(
          %{
            entity_type: "count_order",
            record_id: id,
            field_values: fv,
            actor_id: c.chair_user.id,
            idempotency_key: "t:" <> Ecto.UUID.generate()
          },
          c.s,
          ManagedTypes.owner_for!(Letflow.Modules.Stock)
        )

      before = Repo.query!(~s|SELECT count(*) FROM "#{c.s}".documents|).rows

      assert {:error, :differences_too_many} =
               Counts.issue_differences(c.s, id, opts(c.chair_user))

      assert Repo.query!(~s|SELECT count(*) FROM "#{c.s}".documents|).rows == before
      assert is_nil(view(c, id)["differences_document_id"])
    end

    test "D5 no difference: an issued document with no lines", c do
      id = counted!(c, false, false)

      {:ok, _} =
        Counts.mark_sheet_signed(c.s, id, [c.chair, c.member, c.paper_member], opts(c.chair_user))

      {:ok, v} = Counts.issue_differences(c.s, id, opts(c.chair_user))
      assert doc_content(c, v["differences_document_id"])["lines"] == []
      assert {:ok, %{"lines" => []}} = Counts.differences(c.s, id, opts(c.chair_user))

      assert {:ok, %{"status" => "signed"}} =
               Counts.mark_differences_signed(
                 c.s,
                 id,
                 [c.chair, c.member, c.paper_member],
                 opts(c.chair_user)
               )
    end

    test "D6 a failed document step or audit leaves nothing", c do
      id = counted!(c)
      sheet_signed!(c, id)
      Repo.query!(~s|ALTER TABLE "#{c.s}".document_types DISABLE TRIGGER ALL|)
      Repo.query!(~s|DELETE FROM "#{c.s}".document_types WHERE key = 'count.differences'|)
      assert {:error, {:document, _}} = Counts.issue_differences(c.s, id, opts(c.chair_user))
      assert is_nil(view(c, id)["differences_document_id"])
    end

    test "D6b a failing audit store rolls a mark back", c do
      id = counted!(c)
      Repo.query!(~s|DROP TABLE "#{c.s}".audit_entries CASCADE|)

      assert {:error, :audit_failed} =
               Counts.mark_sheet_signed(c.s, id, everyone(c), opts(c.chair_user))

      assert live(c.s, "count_signature") == 0
      assert is_nil(view(c, id)["sheet_signed_at"])
    end
  end

  # --- differences signing (criterion 4) --------------------------------------------------------

  describe "mark_differences_signed" do
    test "G1 G2 the exact set signs: rows, signed_at, status signed; no way back", c do
      id = counted!(c)
      issued!(c, id)
      mark = &Counts.mark_differences_signed(c.s, id, &1, opts(&2))

      assert {:error, :not_chair} = mark.(everyone(c), c.member_user)
      assert {:error, :signers_incomplete} = mark.([c.chair], c.chair_user)

      assert {:error, {:field_invalid, "signer_employee_ids"}} =
               mark.([Ecto.UUID.generate() | everyone(c)], c.chair_user)

      assert Enum.count(signatures(c, id)) == 4

      assert {:ok, v} = mark.(everyone(c), c.chair_user)
      assert v["status"] == "signed" and is_binary(v["differences_signed_at"])
      rows = Enum.filter(signatures(c, id), &(&1["document_kind"] == "differences"))

      assert length(rows) == 4 and
               Enum.all?(rows, &(&1["document_id"] == v["differences_document_id"]))

      assert [e] = audits(c.s, "stock.count.differences_signed")
      assert e.before_state["status"] == "counted" and e.after_state["status"] == "signed"

      assert {:error, :count_state_invalid} = mark.(everyone(c), c.chair_user)

      assert {:error, :count_state_invalid} =
               Counts.mark_sheet_signed(c.s, id, everyone(c), opts(c.chair_user))

      assert {:error, :count_state_invalid} =
               Counts.issue_differences(c.s, id, opts(c.chair_user))

      assert {:error, :count_state_invalid} = Counts.cancel(c.s, id, opts(c.chair_user))
    end

    test "G2b before the differences are issued", c do
      id = counted!(c)
      sheet_signed!(c, id)

      assert {:error, :differences_not_issued} =
               Counts.mark_differences_signed(c.s, id, everyone(c), opts(c.chair_user))
    end

    test "G3 the 96 hour window after the cut-off", c do
      id = counted!(c)
      v = issued!(c, id)
      {:ok, cut, _} = DateTime.from_iso8601(v["cut_off_at"])
      late = DateTime.add(cut, 96 * 3600 + 1)

      assert {:error, :count_window_expired} =
               Counts.mark_differences_signed(
                 c.s,
                 id,
                 everyone(c),
                 opts(c.chair_user, %{now: late})
               )

      assert view(c, id)["status"] == "counted"
      assert Enum.count(signatures(c, id)) == 4

      exact = DateTime.add(cut, 96 * 3600)

      assert {:ok, %{"status" => "signed"}} =
               Counts.mark_differences_signed(
                 c.s,
                 id,
                 everyone(c),
                 opts(c.chair_user, %{now: exact})
               )
    end

    test "G3b an expired count can still be cancelled", c do
      id = counted!(c)
      v = issued!(c, id)
      {:ok, cut, _} = DateTime.from_iso8601(v["cut_off_at"])

      assert {:error, :count_window_expired} =
               Counts.mark_differences_signed(
                 c.s,
                 id,
                 everyone(c),
                 opts(c.chair_user, %{now: DateTime.add(cut, 97 * 3600)})
               )

      assert {:ok, %{"status" => "cancelled"}} = Counts.cancel(c.s, id, opts(c.chair_user))
    end
  end

  # --- no ledger, no document change (criterion 5, 8) -------------------------------------------

  describe "audit and immutability" do
    test "A1 later calls change no signature row and no issued version; no ledger call", c do
      id = counted!(c)
      issued!(c, id)
      before = signatures(c, id)
      doc = view(c, id)["differences_document_id"]
      content = doc_content(c, doc)
      {:ok, _} = Counts.mark_differences_signed(c.s, id, everyone(c), opts(c.chair_user))
      assert Enum.take(signatures(c, id), length(before)) |> Enum.sort() == Enum.sort(before)
      assert doc_content(c, doc) == content

      src = File.read!("lib/letflow/modules/stock/count_differences.ex")
      refute src =~ "delete_record"
      refute src =~ "alias Letflow.Ledger"
      refute Regex.match?(~r/update_record\([^)]*count_signature/, src)
    end
  end
end
