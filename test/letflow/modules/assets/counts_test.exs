Code.require_file("counts_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CountsTest do
  @moduledoc """
  REQ-816 / GH #4375 (asset count K1): the count order of module `assets` through `Counts` (the
  functions) and the six routes through the full `Letflow.Router` with real OIDC bearer tokens.
  Criterion 1: K1-FLAG-1..3. Criterion 3: K1-R1..R5. Criterion 4: K1-O1, K1-O2. Criterion 5: K1-X1..X3.
  Criterion 7: K1-A1..A3. Also K1-C1 (shape), K1-L1 (list), K1-DOC1 (document type). Committed tenants,
  Sandbox `:auto`, `async: false` (the concurrent issue needs real connections).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.AssetsCountsFixture, as: F
  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Documents.DocumentType
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Assets.Counts

  setup do
    ctx = S.setup_oidc!([:a, :n])
    a = S.tenant!("ast-ck1", ctx.names.a)
    n = S.tenant!("ast-ck1n", ctx.names.n, install: false)

    {:ok,
     Map.merge(ctx, %{
       a: a,
       n: n,
       s: a.schema_name,
       tok_a: S.token(ctx, :a, ["TENANT_ADMIN"]),
       tok_n: S.token(ctx, :n, ["TENANT_ADMIN"])
     })}
  end

  defp live(s, type),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == ^type and not l.deleted), :count,
        prefix: s
      )

  defp counts(s),
    do: for(t <- ~w(assets_count_order assets_count_scope assets_count_member), do: live(s, t))

  defp audits(s, id),
    do: Repo.all(from(e in Entry, where: e.resource_id == ^id, order_by: e.timestamp), prefix: s)

  defp order!(s, w, extra \\ %{}) do
    assert {:ok, view} = Counts.create(s, F.input(w, extra), F.opts())
    view
  end

  defp issued!(s, w, extra \\ %{}) do
    view = order!(s, w, extra)
    assert {:ok, %{"status" => "ordered"} = v} = Counts.issue(s, view["id"], F.opts())
    v
  end

  defp strip(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{} = map} -> Map.delete(map, "trace_id")
      _ -> conn.resp_body
    end
  end

  describe "criterion 1: the flag" do
    # The six calls: every route answers the 404 of a tenant without the module while the flag is off.
    defp six(tok, id, w) do
      [
        D.request(:post, "/counts", tok, F.input(w)),
        D.request(:put, "/counts/#{id}", tok, F.input(w)),
        D.request(:post, "/counts/#{id}/issue", tok, %{}),
        D.request(:post, "/counts/#{id}/cancel", tok, %{}),
        D.request(:get, "/counts", tok),
        D.request(:get, "/counts/#{id}", tok)
      ]
    end

    test "K1-FLAG-1: flag absent, all six routes answer the 404 of a tenant without the module",
         ctx do
      w = F.world!(ctx.s)
      id = order!(ctx.s, w)["id"]

      mine = six(ctx.tok_a, id, w)
      theirs = six(ctx.tok_n, id, w)

      for {m, t} <- Enum.zip(mine, theirs) do
        assert m.status == 404, m.resp_body
        assert t.status == 404
        assert strip(m) == strip(t)
      end

      assert live(ctx.s, "assets_count_order") == 1
    end

    test "K1-FLAG-2: flag false, the same six 404s", ctx do
      w = F.world!(ctx.s)
      id = order!(ctx.s, w)["id"]
      F.enable!(ctx.s, false)

      for {m, t} <- Enum.zip(six(ctx.tok_a, id, w), six(ctx.tok_n, id, w)) do
        assert m.status == 404
        assert strip(m) == strip(t)
      end
    end

    test "K1-FLAG-3: flag on, POST /counts creates a draft", ctx do
      F.enable!(ctx.s)
      w = F.world!(ctx.s)
      body = D.request(:post, "/counts", ctx.tok_a, F.input(w)) |> D.status!(201)
      assert body["status"] == "draft"
      assert body["kinds"] == ["fixed"]
    end

    test "K1-FLAG-4: the flag turns the data visible again, nothing is lost", ctx do
      w = F.world!(ctx.s)
      id = order!(ctx.s, w)["id"]
      F.enable!(ctx.s)
      assert D.request(:get, "/counts/#{id}", ctx.tok_a) |> D.status!(200) |> Map.get("id") == id
      F.disable!(ctx.s)
      assert D.request(:get, "/counts/#{id}", ctx.tok_a).status == 404
    end
  end

  describe "create and read" do
    test "K1-C1: a draft with one scope row and two members; update replaces them", ctx do
      s = ctx.s
      w = F.world!(s)
      view = order!(s, w, %{"kinds" => ["intangible", "fixed"]})

      assert counts(s) == [1, 1, 2]
      assert view["status"] == "draft"
      assert view["kinds"] == ["fixed", "intangible"]
      assert view["location_ids"] == [w.a]
      assert view["member_employee_ids"] == Enum.sort(w.members)
      assert {:ok, ^view} = Counts.get(s, view["id"], F.opts())

      input = F.input(w, %{"location_ids" => [w.b], "member_employee_ids" => [hd(w.members)]})
      assert {:ok, updated} = Counts.update(s, view["id"], input, F.opts())
      assert updated["location_ids"] == [w.b]
      assert updated["member_employee_ids"] == [hd(w.members)]
      assert counts(s) == [1, 1, 1]
    end

    test "K1-C2: an empty location list is the whole unit and is accepted", ctx do
      w = F.world!(ctx.s)
      assert %{"location_ids" => []} = order!(ctx.s, w, %{"location_ids" => []})
    end

    test "K1-L1: list order, limit and cursor, status filter, unknown key", ctx do
      s = ctx.s
      w = F.world!(s)

      ids =
        for d <- ["20", "21", "22"] do
          start = "2026-11-#{d}T09:00:00+05:00"
          stop = "2026-11-#{d}T18:00:00+05:00"
          order!(s, w, %{"planned_start" => start, "planned_end" => stop})["id"]
        end

      assert {:ok, %{rows: rows, next_cursor: nil}} = Counts.list(s, %{}, F.opts())
      assert Enum.map(rows, & &1["id"]) == Enum.reverse(ids)

      assert {:ok, %{rows: [first], next_cursor: cursor}} =
               Counts.list(s, %{"limit" => "1"}, F.opts())

      assert first["id"] == List.last(ids) and is_binary(cursor)

      assert {:ok, %{rows: [second]}} =
               Counts.list(s, %{"limit" => 1, "cursor" => cursor}, F.opts())

      assert second["id"] == Enum.at(ids, 1)

      assert {:ok, %{rows: []}} = Counts.list(s, %{"status" => "ordered"}, F.opts())
      assert {:ok, %{rows: [_, _, _]}} = Counts.list(s, %{"status" => "draft"}, F.opts())
      assert {:error, {:field_not_allowed, "x"}} = Counts.list(s, %{"x" => "1"}, F.opts())
      assert {:error, {:field_invalid, "status"}} = Counts.list(s, %{"status" => "no"}, F.opts())
    end

    test "K1-NF: unknown and malformed ids are not_found", ctx do
      assert {:error, :not_found} = Counts.get(ctx.s, Ecto.UUID.generate(), F.opts())
      assert {:error, :not_found} = Counts.get(ctx.s, "nope", F.opts())
      assert {:error, :not_found} = Counts.issue(ctx.s, "nope", F.opts())
    end
  end

  describe "criterion 3: refusals store nothing" do
    test "K1-R1: kinds", ctx do
      w = F.world!(ctx.s)

      for bad <- [[], ["building"], ["fixed", "fixed"], "fixed", nil] do
        assert {:error, {:field_invalid, "kinds"}} =
                 Counts.create(ctx.s, F.input(w, %{"kinds" => bad}), F.opts())
      end

      assert counts(ctx.s) == [0, 0, 0]
    end

    test "K1-R2: 96 hours and one second", ctx do
      w = F.world!(ctx.s)
      long = %{"planned_end" => "2026-11-24T09:00:01+05:00"}

      assert {:error, :count_too_long} = Counts.create(ctx.s, F.input(w, long), F.opts())
      assert counts(ctx.s) == [0, 0, 0]

      exact = %{"planned_end" => "2026-11-24T09:00:00+05:00"}
      assert {:ok, _} = Counts.create(ctx.s, F.input(w, exact), F.opts())

      back = %{"planned_end" => "2026-11-20T09:00:00+05:00"}
      assert {:error, :count_too_long} = Counts.create(ctx.s, F.input(w, back), F.opts())
    end

    test "K1-R3: a chair without a user", ctx do
      w = F.world!(ctx.s)
      chair = F.employee!(ctx.s, w.unit, nil)

      assert {:error, :chair_without_user} =
               Counts.create(ctx.s, F.input(w, %{"chair_employee_id" => chair}), F.opts())

      assert counts(ctx.s) == [0, 0, 0]
    end

    test "K1-R4: a location that is not linked, and a root inside another root", ctx do
      w = F.world!(ctx.s)

      assert {:error, :count_scope_not_linked} =
               Counts.create(ctx.s, F.input(w, %{"location_ids" => [w.c]}), F.opts())

      assert {:error, :count_scope_overlaps} =
               Counts.create(ctx.s, F.input(w, %{"location_ids" => [w.a, w.a1]}), F.opts())

      assert counts(ctx.s) == [0, 0, 0]
    end

    test "K1-R5: unknown key, bad uuid, chair among members, bad note", ctx do
      w = F.world!(ctx.s)

      assert {:error, {:field_not_allowed, "status"}} =
               Counts.create(ctx.s, F.input(w, %{"status" => "ordered"}), F.opts())

      assert {:error, {:field_invalid, "org_unit_id"}} =
               Counts.create(ctx.s, F.input(w, %{"org_unit_id" => "x"}), F.opts())

      assert {:error, {:field_invalid, "member_employee_ids"}} =
               Counts.create(ctx.s, F.input(w, %{"member_employee_ids" => [w.chair]}), F.opts())

      assert {:error, {:field_invalid, "note"}} =
               Counts.create(
                 ctx.s,
                 F.input(w, %{"note" => String.duplicate("x", 1001)}),
                 F.opts()
               )

      assert {:error, {:field_invalid, "body"}} = Counts.create(ctx.s, "x", F.opts())
      assert counts(ctx.s) == [0, 0, 0]
    end

    test "K1-R6: an inactive unit and an inactive employee", ctx do
      w = F.world!(ctx.s)

      assert {:error, :org_unit_inactive} =
               Counts.create(
                 ctx.s,
                 F.input(w, %{"org_unit_id" => Ecto.UUID.generate()}),
                 F.opts()
               )

      assert {:error, :employee_inactive} =
               Counts.create(
                 ctx.s,
                 F.input(w, %{"member_employee_ids" => [Ecto.UUID.generate()]}),
                 F.opts()
               )
    end

    test "K1-U1: update and issue of a non-draft order are refused", ctx do
      w = F.world!(ctx.s)
      v = issued!(ctx.s, w)

      assert {:error, :count_state_invalid} = Counts.update(ctx.s, v["id"], F.input(w), F.opts())
      assert {:error, :count_state_invalid} = Counts.issue(ctx.s, v["id"], F.opts())
    end
  end

  describe "criterion 4: overlap" do
    test "K1-O1: two overlapping drafts issued at once, exactly one wins", ctx do
      s = ctx.s
      w = F.world!(s)
      one = order!(s, w, %{"location_ids" => [w.a]})["id"]
      two = order!(s, w, %{"location_ids" => [w.a1]})["id"]

      results =
        [one, two]
        |> Enum.map(fn id -> Task.async(fn -> Counts.issue(s, id, F.opts()) end) end)
        |> Task.await_many(30_000)

      assert [{:error, :count_scope_overlaps}] = Enum.filter(results, &match?({:error, _}, &1))
      assert [{:ok, %{"status" => "ordered"}}] = Enum.filter(results, &match?({:ok, _}, &1))

      other = F.world!(s)
      assert %{"status" => "ordered"} = issued!(s, other)
    end

    test "K1-O2: the rule, sequentially", ctx do
      s = ctx.s
      w = F.world!(s)
      first = issued!(s, w, %{"location_ids" => [w.a]})

      whole = order!(s, w, %{"location_ids" => []})
      below = order!(s, w, %{"location_ids" => [w.a1]})
      apart = order!(s, w, %{"location_ids" => [w.b]})

      assert {:error, :count_scope_overlaps} = Counts.issue(s, whole["id"], F.opts())
      assert {:error, :count_scope_overlaps} = Counts.issue(s, below["id"], F.opts())
      assert {:ok, %{"status" => "ordered"}} = Counts.issue(s, apart["id"], F.opts())

      # a cancelled order no longer blocks
      assert {:ok, _} = Counts.cancel(s, first["id"], F.opts(w.chair_user))
      assert {:ok, %{"status" => "ordered"}} = Counts.issue(s, below["id"], F.opts())
    end

    test "K1-O3: two orders that both include intangible overlap, even on other roots", ctx do
      s = ctx.s
      w = F.world!(s)
      kinds = %{"kinds" => ["fixed", "intangible"]}
      _ = issued!(s, w, Map.put(kinds, "location_ids", [w.a]))
      second = order!(s, w, Map.put(kinds, "location_ids", [w.b]))
      assert {:error, :count_scope_overlaps} = Counts.issue(s, second["id"], F.opts())

      fixed_only = order!(s, w, %{"location_ids" => [w.b]})
      assert {:ok, _} = Counts.issue(s, fixed_only["id"], F.opts())
    end
  end

  describe "criterion 5: cancel" do
    test "K1-X1: cancel from every open status, by the chair", ctx do
      s = ctx.s

      for status <- ~w(draft ordered counting counted sheet_signed) do
        w = F.world!(s)
        id = if status == "draft", do: order!(s, w)["id"], else: issued!(s, w)["id"]
        if status not in ["draft", "ordered"], do: F.set_status!(s, id, status)

        assert {:ok, %{"status" => "cancelled", "cancelled_by" => by}} =
                 Counts.cancel(s, id, F.opts(w.chair_user)),
               status

        assert by == w.chair_user
      end
    end

    test "K1-X2: signed and cancelled orders are refused and keep their status", ctx do
      s = ctx.s
      w = F.world!(s)
      id = issued!(s, w)["id"]
      F.set_status!(s, id, "signed")

      assert {:error, :count_state_invalid} = Counts.cancel(s, id, F.opts(w.chair_user))
      assert {:ok, %{"status" => "signed"}} = Counts.get(s, id, F.opts())

      w2 = F.world!(s)
      id2 = order!(s, w2)["id"]
      assert {:ok, _} = Counts.cancel(s, id2, F.opts(w2.chair_user))
      assert {:error, :count_state_invalid} = Counts.cancel(s, id2, F.opts(w2.chair_user))
    end

    test "K1-X3: only the chair cancels", ctx do
      w = F.world!(ctx.s)
      id = order!(ctx.s, w)["id"]
      assert {:error, :not_chair} = Counts.cancel(ctx.s, id, F.opts())
      assert {:ok, %{"status" => "draft"}} = Counts.get(ctx.s, id, F.opts())
    end
  end

  describe "criterion 7: audit" do
    test "K1-A1: one entry per action, ids and status only", ctx do
      s = ctx.s
      w = F.world!(s)
      id = order!(s, w)["id"]
      {:ok, _} = Counts.update(s, id, F.input(w), F.opts())
      {:ok, _} = Counts.issue(s, id, F.opts())
      {:ok, _} = Counts.cancel(s, id, F.opts(w.chair_user))

      entries = audits(s, id)

      assert Enum.map(entries, & &1.action) ==
               ~w(assets_count.created assets_count.updated assets_count.issued assets_count.cancelled)

      assert Enum.map(entries, & &1.after_state) ==
               Enum.map(~w(draft draft ordered cancelled), &%{"status" => &1})

      for e <- entries do
        assert e.resource_type == "assets_count_order"
        refute inspect(e.before_state) =~ "year end"
        refute inspect(e.after_state) =~ "year end"
        refute Map.has_key?(e.after_state, "quantity")
      end
    end

    test "K1-A2: refusals write no audit entry", ctx do
      s = ctx.s
      w = F.world!(s)
      v = issued!(s, w)
      before = Repo.aggregate(Entry, :count, prefix: s)

      assert {:error, :count_state_invalid} = Counts.update(s, v["id"], F.input(w), F.opts())

      assert {:error, {:field_invalid, "kinds"}} =
               Counts.create(s, F.input(w, %{"kinds" => []}), F.opts())

      assert Repo.aggregate(Entry, :count, prefix: s) == before
    end

    test "K1-A3: an audit failure rolls the write back", ctx do
      s = ctx.s
      w = F.world!(s)
      Repo.query!(~s|DROP TABLE "#{s}".audit_entries CASCADE|)

      assert {:error, :audit_failed} = Counts.create(s, F.input(w), F.opts())
      assert counts(s) == [0, 0, 0]
    end
  end

  describe "documents" do
    test "K1-DOC1: the order document type and number", ctx do
      v = issued!(ctx.s, F.world!(ctx.s))
      assert String.starts_with?(v["number"], "ACO")
      assert is_binary(v["document_id"]) and is_binary(v["issued_at"])

      type = Repo.get!(DocumentType, "assets_count.order", prefix: ctx.s)
      assert {type.owner_module, type.number_prefix, type.number_pad} == {"assets", "ACO", 6}
      assert type.numbering_scope == :year

      for {key, prefix} <- [{"assets_count.sheet", "ACS"}, {"assets_count.result", "ACR"}] do
        assert %{number_prefix: ^prefix} = Repo.get!(DocumentType, key, prefix: ctx.s)
      end
    end
  end
end
