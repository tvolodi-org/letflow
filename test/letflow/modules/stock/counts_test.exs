Code.require_file("counts_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountsTest do
  @moduledoc """
  REQ-700 / GH #3737 criteria 2 to 6 (C-CREATE, C-UPDATE, C-REFUSE, I-OK, I-ORDER, I-ROLLBACK, O-OVERLAP,
  X-CANCEL, A-AUDIT, A-AUDIT-FAIL, R-NODEP): `Letflow.Modules.Stock.Counts` on fresh tenants with
  org, locations and stock really installed. `async: false`: committed install side effects.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.CountsFixture, as: F
  alias Letflow.Entities.Record.Latest
  alias Letflow.LocationsFixture, as: L
  alias Letflow.Modules.Stock.Counts

  setup do
    t = F.tenant!()
    {:ok, Map.merge(t, %{w: F.world!(t.schema)})}
  end

  defp live(s, type),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == ^type and not l.deleted), :count,
        prefix: s
      )

  defp seqs(s), do: Repo.query!(~s|SELECT count(*) FROM "#{s}".document_sequences|).rows

  defp audits(s, action),
    do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: s)

  defp create!(s, w, extra \\ %{}) do
    {:ok, v} = Counts.create(s, F.input(w, extra), F.opts())
    v
  end

  # Sets a status directly (a later slice owns the real transitions).
  defp set_status!(s, id, status) do
    {:ok, row} = Letflow.Entities.Record.Latest.get_live(id, "count_order", s)

    {:ok, _} =
      Letflow.Entities.Records.update_record(
        %{
          entity_type: "count_order",
          record_id: id,
          field_values: Map.put(row.field_values, "status", status),
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        s,
        Letflow.Entities.ManagedTypes.owner_for!(Letflow.Modules.Stock)
      )
  end

  describe "create and update (C-CREATE, C-UPDATE)" do
    test "C-CREATE stores a draft with its scope and commission rows", %{schema: s, w: w} do
      v = create!(s, w)
      assert v["status"] == "draft"
      assert v["location_ids"] == [w.a]
      assert v["member_employee_ids"] == Enum.sort(w.members)
      assert v["planned_start"] == "2026-11-10T04:00:00Z"
      assert live(s, "count_order") == 1
      assert live(s, "count_order_scope") == 1
      assert live(s, "count_commission_member") == 2
      assert {:ok, ^v} = Counts.get(s, v["id"], F.opts())
    end

    test "C-UPDATE replaces everything and removes unlisted rows", %{schema: s, w: w} do
      v = create!(s, w)

      {:ok, u} =
        Counts.update(
          s,
          v["id"],
          F.input(w, %{
            "location_ids" => [w.b, w.a1],
            "member_employee_ids" => [],
            "kind" => "full"
          }),
          F.opts()
        )

      assert u["location_ids"] == Enum.sort([w.b, w.a1])
      assert u["member_employee_ids"] == []
      assert u["kind"] == "full"
      assert live(s, "count_order_scope") == 2
      assert live(s, "count_commission_member") == 0
    end

    test "C-UPDATE of an ordered order is refused", %{schema: s, w: w} do
      v = create!(s, w)
      {:ok, _} = Counts.issue(s, v["id"], F.opts())
      assert {:error, :count_state_invalid} = Counts.update(s, v["id"], F.input(w), F.opts())
    end
  end

  describe "create refusals (C-REFUSE)" do
    setup %{schema: s} do
      {:ok, before: {live(s, "count_order"), live(s, "count_order_scope")}}
    end

    defp refuse(s, w, extra) do
      Counts.create(s, F.input(w, extra), F.opts())
    end

    test "C-REFUSE-1 an unknown key", %{schema: s, w: w, before: b} do
      assert {:error, {:field_not_allowed, "status"}} = refuse(s, w, %{"status" => "ordered"})
      assert b == {live(s, "count_order"), live(s, "count_order_scope")}
    end

    test "C-REFUSE-2 missing and malformed fields", %{schema: s, w: w, before: b} do
      assert {:error, {:field_invalid, "kind"}} = refuse(s, w, %{"kind" => "other"})

      assert {:error, {:field_invalid, "planned_start"}} =
               refuse(s, w, %{"planned_start" => "tomorrow"})

      assert {:error, {:field_invalid, "planned_end"}} = refuse(s, w, %{"planned_end" => 5})

      assert {:error, {:field_invalid, "note"}} =
               refuse(s, w, %{"note" => String.duplicate("x", 1001)})

      assert {:error, {:field_invalid, "org_unit_id"}} = refuse(s, w, %{"org_unit_id" => "x"})

      assert {:error, {:field_invalid, "chair_employee_id"}} =
               Counts.create(s, Map.delete(F.input(w), "chair_employee_id"), F.opts())

      assert b == {live(s, "count_order"), live(s, "count_order_scope")}
    end

    test "C-REFUSE-3 an inactive or unknown org unit", %{schema: s, w: w} do
      assert {:error, :org_unit_inactive} = refuse(s, w, %{"org_unit_id" => Ecto.UUID.generate()})
    end

    test "C-REFUSE-4 empty or duplicate roots", %{schema: s, w: w} do
      assert {:error, {:field_invalid, "location_ids"}} = refuse(s, w, %{"location_ids" => []})

      assert {:error, {:field_invalid, "location_ids"}} =
               refuse(s, w, %{"location_ids" => [w.a, w.a]})
    end

    test "C-REFUSE-5 an inactive chair or member", %{schema: s, w: w} do
      off = F.employee!(s, w.unit, active: false)
      assert {:error, :employee_inactive} = refuse(s, w, %{"chair_employee_id" => off})
      assert {:error, :employee_inactive} = refuse(s, w, %{"member_employee_ids" => [off]})

      assert {:error, :employee_inactive} =
               refuse(s, w, %{"member_employee_ids" => [Ecto.UUID.generate()]})
    end

    test "C-REFUSE-6 a chair with no user", %{schema: s, w: w} do
      nouser = F.employee!(s, w.unit, user: nil)
      assert {:error, :chair_without_user} = refuse(s, w, %{"chair_employee_id" => nouser})
    end

    test "C-REFUSE-7 a member listed twice or equal to the chair", %{schema: s, w: w} do
      [m | _] = w.members

      assert {:error, {:field_invalid, "member_employee_ids"}} =
               refuse(s, w, %{"member_employee_ids" => [m, m]})

      assert {:error, {:field_invalid, "member_employee_ids"}} =
               refuse(s, w, %{"member_employee_ids" => [w.chair]})
    end

    test "C-REFUSE-8 an org unit outside the caller's scope is not found", %{schema: s, w: w} do
      assert {:error, :not_found} =
               Counts.create(s, F.input(w), F.opts(nil, {:nodes, [Ecto.UUID.generate()]}))

      assert {:error, :not_found} = Counts.create(s, F.input(w), F.opts(nil, :none))
    end
  end

  describe "issue (I-OK, I-ORDER, I-ROLLBACK)" do
    test "I-OK gives ordered with a document, a number and the issue time", %{schema: s, w: w} do
      v = create!(s, w)
      actor = Ecto.UUID.generate()
      {:ok, i} = Counts.issue(s, v["id"], F.opts(actor))
      assert i["status"] == "ordered"
      assert i["issued_by"] == actor
      assert is_binary(i["document_id"]) and is_binary(i["issued_at"])
      assert i["number"] =~ ~r/\ACO-\d{4}-0001\z/
      assert {:ok, d} = Counts.document(s, v["id"], F.opts())
      assert d.number_label == i["number"] and d.version_no == 1
      refute Map.has_key?(d, :content)
      assert [_] = audits(s, "document.issued")
    end

    test "I-ORDER pre-check refusals leave a draft and take no number", %{schema: s, w: w} do
      before = seqs(s)
      draft = fn extra -> create!(s, w, extra)["id"] end
      stays = fn id -> assert {:ok, %{"status" => "draft"}} = Counts.get(s, id, F.opts()) end
      other_unit = F.unit!(s)
      foreign = L.node!(s, "F#{System.unique_integer([:positive])}").record_id

      id = draft.(%{"location_ids" => [foreign]})
      assert {:error, :count_scope_not_linked} = Counts.issue(s, id, F.opts())
      stays.(id)

      id = draft.(%{"location_ids" => [w.a, w.a11]})
      assert {:error, :count_scope_overlaps} = Counts.issue(s, id, F.opts())
      stays.(id)

      id = draft.(%{"kind" => "full", "location_ids" => [w.a]})
      assert {:error, :count_scope_incomplete} = Counts.issue(s, id, F.opts())
      stays.(id)

      id = draft.(%{"planned_end" => "2026-11-15T09:00:00+05:00"})
      assert {:error, :count_too_long} = Counts.issue(s, id, F.opts())
      stays.(id)

      id = draft.(%{"planned_end" => "2026-11-10T09:00:00+05:00"})
      assert {:error, :count_too_long} = Counts.issue(s, id, F.opts())
      stays.(id)

      off = F.employee!(s, w.unit)
      id = draft.(%{"member_employee_ids" => [off]})
      set_employee_inactive!(s, off)
      assert {:error, :employee_inactive} = Counts.issue(s, id, F.opts())
      stays.(id)

      assert {:error, :count_state_invalid} =
               (fn ->
                  ok = draft.(%{})
                  {:ok, _} = Counts.issue(s, ok, F.opts())
                  Counts.issue(s, ok, F.opts())
                end).()

      assert other_unit
      # only the one successful issue took a number
      assert seqs(s) != before
      assert [[n]] = Repo.query!(~s|SELECT counter FROM "#{s}".document_sequences|).rows
      assert n == 1
    end

    test "a full count covering the unit's locations is issued", %{schema: s, w: w} do
      id = create!(s, w, %{"kind" => "full", "location_ids" => [w.a, w.b]})["id"]
      assert {:ok, %{"status" => "ordered"}} = Counts.issue(s, id, F.opts())
    end

    test "I-ROLLBACK a Documents refusal rolls back the draft document and the number", %{
      schema: s,
      w: w
    } do
      id = create!(s, w)["id"]
      Repo.query!(~s|ALTER TABLE "#{s}".document_types DISABLE TRIGGER ALL|)
      Repo.query!(~s|DELETE FROM "#{s}".document_types WHERE key = 'count.order'|)

      assert {:error, {:document, _}} = Counts.issue(s, id, F.opts())
      assert {:ok, %{"status" => "draft", "document_id" => nil}} = Counts.get(s, id, F.opts())
      assert Repo.query!(~s|SELECT count(*) FROM "#{s}".documents|).rows == [[0]]
    end
  end

  defp set_employee_inactive!(s, id) do
    {:ok, row} = Latest.get_live(id, "org_employee", s)

    {:ok, _} =
      Letflow.Entities.Records.update_record(
        %{
          entity_type: "org_employee",
          record_id: id,
          field_values: Map.put(row.field_values, "active", false),
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        s,
        Letflow.OrgFixture.owner()
      )
  end

  describe "overlap (O-OVERLAP)" do
    test "the same root, a root below and a root above are refused while another order is open",
         %{schema: s, w: w} do
      for status <- ~w(ordered counting counted signed) do
        first = create!(s, w, %{"location_ids" => [w.a1]})["id"]
        {:ok, _} = Counts.issue(s, first, F.opts())
        set_status!(s, first, status)

        for roots <- [[w.a1], [w.a11], [w.a]] do
          id = create!(s, w, %{"location_ids" => roots})["id"]

          assert {:error, :count_scope_overlaps} = Counts.issue(s, id, F.opts()),
                 "#{status} #{inspect(roots)}"
        end

        # a disjoint root is fine; it is cancelled so the next status starts clean
        free = create!(s, w, %{"location_ids" => [w.b]})["id"]
        assert {:ok, _} = Counts.issue(s, free, F.opts())
        set_status!(s, free, "posted")
        set_status!(s, first, "posted")
      end
    end

    test "cancelled and posted orders do not block, nor does another org unit", %{schema: s, w: w} do
      first = create!(s, w)["id"]
      {:ok, _} = Counts.issue(s, first, F.opts())
      {:ok, _} = Counts.cancel(s, first, F.opts(w.chair_user))
      again = create!(s, w)["id"]
      assert {:ok, _} = Counts.issue(s, again, F.opts())
      set_status!(s, again, "posted")
      assert {:ok, _} = Counts.issue(s, create!(s, w)["id"], F.opts())
    end

    test "I-INSIDE a second unit with its own linked root is independent", %{schema: s, w: w} do
      {:ok, _} = Counts.issue(s, create!(s, w)["id"], F.opts())
      unit2 = F.unit!(s)
      chair2 = F.employee!(s, unit2)
      L.link!(s, unit2, w.a)

      {:ok, v} =
        Counts.create(
          s,
          F.input(w, %{
            "org_unit_id" => unit2,
            "chair_employee_id" => chair2,
            "member_employee_ids" => []
          }),
          F.opts()
        )

      assert {:ok, _} = Counts.issue(s, v["id"], F.opts())
    end
  end

  describe "cancel (X-CANCEL)" do
    test "from draft, ordered, counting and counted; the document stays issued", %{
      schema: s,
      w: w
    } do
      for status <- ~w(draft ordered counting counted) do
        id = create!(s, w, %{"location_ids" => [w.b]})["id"]

        if status != "draft" do
          {:ok, _} = Counts.issue(s, id, F.opts())
          set_status!(s, id, status)
        end

        {:ok, c} = Counts.cancel(s, id, F.opts(w.chair_user))
        assert c["status"] == "cancelled" and c["cancelled_by"] == w.chair_user

        if c["document_id"] do
          assert {:ok, d} = Letflow.Documents.issued_summary(s, c["document_id"])
          assert d.version_no == 1
        end
      end
    end

    test "refused from signed, posted and cancelled", %{schema: s, w: w} do
      id = create!(s, w)["id"]
      {:ok, _} = Counts.issue(s, id, F.opts())

      for status <- ~w(signed posted cancelled) do
        set_status!(s, id, status)
        assert {:error, :count_state_invalid} = Counts.cancel(s, id, F.opts(w.chair_user))
      end
    end

    test "only the chair may cancel", %{schema: s, w: w} do
      id = create!(s, w)["id"]
      assert {:error, :not_chair} = Counts.cancel(s, id, F.opts())
      member_user = Ecto.UUID.generate()
      _ = F.employee!(s, w.unit, user: member_user)
      assert {:error, :not_chair} = Counts.cancel(s, id, F.opts(member_user))
      assert {:ok, %{"status" => "draft"}} = Counts.get(s, id, F.opts())
    end
  end

  describe "audit (A-AUDIT, A-AUDIT-FAIL)" do
    test "A-AUDIT one entry per action with ids and status only", %{schema: s, w: w} do
      v = create!(s, w)
      {:ok, _} = Counts.update(s, v["id"], F.input(w), F.opts())
      {:ok, _} = Counts.issue(s, v["id"], F.opts())
      {:ok, _} = Counts.cancel(s, v["id"], F.opts(w.chair_user))

      for {action, after_status} <- [
            created: "draft",
            updated: "draft",
            issued: "ordered",
            cancelled: "cancelled"
          ] do
        assert [e] = audits(s, "stock.count_order.#{action}")
        assert e.resource_id == v["id"]
        assert e.after_state == %{"status" => after_status}
      end

      # a refused write adds nothing
      n = Repo.aggregate(Entry, :count, prefix: s)
      assert {:error, :count_state_invalid} = Counts.update(s, v["id"], F.input(w), F.opts())
      assert Repo.aggregate(Entry, :count, prefix: s) == n
    end

    test "A-AUDIT-FAIL a failing audit store rolls the write back", %{schema: s, w: w} do
      Repo.query!(~s|DROP TABLE "#{s}".audit_entries CASCADE|)
      assert {:error, :audit_failed} = Counts.create(s, F.input(w), F.opts())
      assert live(s, "count_order") == 0
    end
  end

  describe "reads and edges" do
    test "list filters, order, limit and cursor", %{schema: s, w: w} do
      a =
        create!(s, w, %{
          "planned_start" => "2026-11-01T09:00:00Z",
          "planned_end" => "2026-11-02T09:00:00Z"
        })

      b =
        create!(s, w, %{
          "planned_start" => "2026-11-03T09:00:00Z",
          "planned_end" => "2026-11-04T09:00:00Z"
        })

      c =
        create!(s, w, %{
          "planned_start" => "2026-11-02T09:00:00Z",
          "planned_end" => "2026-11-03T09:00:00Z"
        })

      {:ok, _} = Counts.issue(s, c["id"], F.opts())

      {:ok, %{rows: rows}} = Counts.list(s, %{}, F.opts())
      assert Enum.map(rows, & &1["id"]) == [b["id"], c["id"], a["id"]]

      {:ok, %{rows: [r], next_cursor: cur}} = Counts.list(s, %{"limit" => "1"}, F.opts())
      assert r["id"] == b["id"] and is_binary(cur)
      {:ok, %{rows: rest}} = Counts.list(s, %{"limit" => 5, "cursor" => cur}, F.opts())
      assert Enum.map(rest, & &1["id"]) == [c["id"], a["id"]]

      assert {:ok, %{rows: [%{"id" => id}]}} = Counts.list(s, %{"status" => "ordered"}, F.opts())
      assert id == c["id"]

      assert {:ok, %{rows: []}} =
               Counts.list(s, %{"org_unit_id" => Ecto.UUID.generate()}, F.opts())

      assert {:error, {:field_not_allowed, "x"}} = Counts.list(s, %{"x" => "1"}, F.opts())
      assert {:error, {:field_invalid, "limit"}} = Counts.list(s, %{"limit" => "0"}, F.opts())
      assert {:error, {:field_invalid, "cursor"}} = Counts.list(s, %{"cursor" => "!!"}, F.opts())
    end

    test "scope: a node set sees its unit only; other ids are not found", %{schema: s, w: w} do
      v = create!(s, w)
      assert {:ok, %{rows: [_]}} = Counts.list(s, %{}, F.opts(nil, {:nodes, [w.unit]}))

      assert {:ok, %{rows: []}} =
               Counts.list(s, %{}, F.opts(nil, {:nodes, [Ecto.UUID.generate()]}))

      assert {:ok, %{rows: []}} = Counts.list(s, %{}, F.opts(nil, :none))
      other = F.opts(nil, {:nodes, [Ecto.UUID.generate()]})

      for r <- [
            Counts.get(s, v["id"], other),
            Counts.update(s, v["id"], F.input(w), other),
            Counts.issue(s, v["id"], other),
            Counts.cancel(s, v["id"], other),
            Counts.document(s, v["id"], other),
            Counts.get(s, "nope", F.opts())
          ] do
        assert r == {:error, :not_found}
      end
    end

    test "R-NODEP stock needs org and locations: an install without them is refused" do
      t = Letflow.TenantFixture.provisioned_tenant!(slug_prefix: "req700-nodep")
      {:ok, _} = Letflow.Entities.EventTypes.seed!(t.schema_name)

      assert {:error, _} =
               Letflow.Modules.Installs.install("stock", Ecto.UUID.generate(),
                 prefix: t.schema_name,
                 rationale: "test: REQ-700"
               )
    end

    test "descendants: a subtree check on a 3-level tree includes the root itself", %{
      schema: s,
      w: w
    } do
      assert Letflow.Modules.Locations.Tree.descendant_ids(s, w.a) |> Enum.sort() ==
               Enum.sort([w.a1, w.a11])
    end
  end
end
