Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountPostingTest do
  @moduledoc """
  REQ-718 / GH #3763 (R3, P1..P7, V1..V3, T1..T3): the posting of a signed count to the stock ledger, the
  posting record, the posting check on read and the reversal of the whole count, through the full
  `Letflow.Router` with real OIDC bearer tokens. A task is completed through `Letflow.Engine.complete_task/3`
  with the OIDC credential (the path the ledger authority step checks). The count freeze is NOT built
  (assumption, owner may change at GATE B, D-086): P3 pins that postings during counting stay valid.
  Committed tenants in Sandbox `:auto` mode, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CountsFixture, as: F
  alias Letflow.Engine.Task
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.User
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Stock.Counts
  alias Letflow.Modules.Stock.Handlers
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture

  setup do
    ctx = S.setup_oidc!([:a, :b, :s])
    Map.put(ctx, :tok_a, S.token(ctx, :a, ["TENANT_ADMIN"]))
  end

  # --- helpers ----------------------------------------------------------------------------------

  defp call(method, path, token, body \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, S.base() <> path)
        b -> Plug.Test.conn(method, S.base() <> path, Jason.encode!(b))
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp strip(conn), do: M.strip_conn(conn)

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    S.json(conn)
  end

  defp reason!(conn, status), do: status!(conn, status)["reason"]

  defp window do
    now = DateTime.utc_now()

    %{
      "planned_start" => DateTime.to_iso8601(DateTime.add(now, -3600)),
      "planned_end" => DateTime.to_iso8601(DateTime.add(now, 20 * 3600))
    }
  end

  # A tenant with a world, a chair and a member who are real users, and a task completer.
  defp world!(ctx, name) do
    t = S.tenant!("cpost", Map.fetch!(ctx.names, name))
    s = t.schema_name
    w = F.world!(s)
    chair_tok = S.token(ctx, name, ["TENANT_ADMIN"], sub: "chair-#{name}")
    member_tok = S.token(ctx, name, ["TENANT_ADMIN"], sub: "member-#{name}")
    status!(call(:get, "/counts", chair_tok), 200)
    status!(call(:get, "/counts", member_tok), 200)
    chair_user = Repo.one!(from(u in User, where: u.username == ^"chair-#{name}"), prefix: s)
    member_user = Repo.one!(from(u in User, where: u.username == ^"member-#{name}"), prefix: s)
    chair = F.employee!(s, w.unit, user: chair_user.id)
    member = F.employee!(s, w.unit, user: member_user.id)
    w = %{w | chair: chair, members: [member]}

    %{
      t: t,
      s: s,
      schema: s,
      w: w,
      chair_tok: chair_tok,
      member_tok: member_tok,
      chair_user: chair_user,
      holder: TokenMintFixture.role_holder!(s, ["TENANT_ADMIN"]),
      m: D.masters!(s)
    }
  end

  defp book!(x) do
    sku1 = S.uuid()
    sku2 = S.uuid()
    S.post!(x.s, "receipt", %{lines: [S.line(sku1, "10", %{to: S.side(x.w.unit, x.w.a)})]})
    S.post!(x.s, "receipt", %{lines: [S.line(sku2, "4", %{to: S.side(x.w.unit, x.w.a1)})]})
    {sku1, sku2}
  end

  # Counted lines: line 1 (book 10) counted 3 = shortage 7; line 2 (book 4) counted 3 = shortage 1;
  # `surplus?` adds a surplus line of 2. `exact?` counts the books exactly (no difference).
  defp counted!(x, opts \\ []) do
    {_sku1, _sku2} = book!(x)
    created = status!(call(:post, "/counts", x.chair_tok, F.input(x.w, window())), 201)
    id = created["id"]
    status!(call(:post, "/counts/#{id}/issue", x.chair_tok, %{}), 200)
    status!(call(:post, "/counts/#{id}/open", x.chair_tok, %{}), 200)
    exact? = Keyword.get(opts, :exact, false)
    lines = status!(call(:get, "/counts/#{id}/lines", x.chair_tok), 200)["rows"]

    for l <- lines do
      qty = if exact?, do: l["book_quantity"], else: "3"

      status!(
        call(:put, "/counts/#{id}/lines/#{l["line_no"]}/count", x.member_tok, %{
          "counted_quantity" => qty
        }),
        200
      )
    end

    if Keyword.get(opts, :surplus, true) and not exact? do
      status!(
        call(:post, "/counts/#{id}/surplus-lines", x.member_tok, %{
          "location_id" => x.w.a1,
          "catalog_item_id" => x.m.item,
          "unit_ref" => x.m.uom,
          "counted_quantity" => "2"
        }),
        201
      )
    end

    assert status!(call(:post, "/counts/#{id}/close", x.chair_tok, %{}), 200)["status"] ==
             "counted"

    id
  end

  # A `signed` count: the sheet and the differences sheet signed by the chair. `now` goes through the
  # function (a test hook), so that the signing time can be old.
  defp signed!(x, opts \\ []) do
    id = counted!(x, opts)
    ids = [x.w.chair | x.w.members]
    status!(call(:post, "/counts/#{id}/sheet-signatures", x.chair_tok, sids(ids)), 200)
    status!(call(:post, "/counts/#{id}/differences", x.chair_tok, %{}), 200)

    case Keyword.get(opts, :now) do
      nil ->
        done =
          status!(
            call(:post, "/counts/#{id}/differences-signatures", x.chair_tok, sids(ids)),
            200
          )

        assert done["status"] == "signed"

      now ->
        assert {:ok, %{"status" => "signed"}} =
                 Counts.mark_differences_signed(x.s, id, ids, %{
                   actor_id: x.chair_user.id,
                   scope: :all,
                   now: now
                 })
    end

    id
  end

  defp sids(ids), do: %{"signer_employee_ids" => ids}

  defp count(x, id), do: status!(call(:get, "/counts/#{id}", x.chair_tok), 200)

  defp diff_id(x, id), do: count(x, id)["differences_document_id"]

  defp post!(x, id), do: status!(call(:post, "/counts/#{id}/post", x.chair_tok, %{}), 200)

  defp task!(x, id, node) do
    P.pending_task(x, diff_id(x, id), node) || flunk("no pending #{node} task")
  end

  defp complete!(x, id, node \\ "post") do
    assert {:ok, _} = P.complete(x, task!(x, id, node))
  end

  defp posted!(x, opts \\ []) do
    id = signed!(x, opts)
    post!(x, id)
    complete!(x, id)
    id
  end

  defp shortage_sku!(x) do
    Repo.one!(
      from(l in Letflow.Entities.Record.Latest,
        where:
          l.entity_type == "count_sheet_line" and
            fragment("?->>'location_id' = ?", l.field_values, ^x.w.a),
        select: fragment("?->>'catalog_item_id'", l.field_values),
        limit: 1
      ),
      prefix: x.s
    )
  end

  defp movements(x, id) do
    S.get("/movements?document_id=#{diff_id(x, id)}", x.chair_tok)
    |> status!(200)
    |> Map.fetch!("rows")
  end

  defp balance(x, sku) do
    S.get("/balances?sku=#{sku}", x.chair_tok)
    |> status!(200)
    |> Map.fetch!("rows")
    |> Enum.reduce(Decimal.new(0), &Decimal.add(Decimal.new(&1["quantity"]), &2))
  end

  defp skus(x) do
    rows = S.get("/balances", x.chair_tok) |> status!(200) |> Map.fetch!("rows")
    rows |> Enum.map(& &1["sku"]) |> Enum.uniq()
  end

  defp total(x),
    do: Enum.reduce(skus(x), Decimal.new(0), fn sku, acc -> Decimal.add(acc, balance(x, sku)) end)

  defp marks(x, id) do
    %{rows: [[n]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{x.s}".entity_record_latest WHERE entity_type = 'stock_posting_mark' AND NOT deleted AND field_values->>'document_id' = $1|,
        [diff_id(x, id)]
      )

    n
  end

  # --- R3: the handler contract -----------------------------------------------------------------

  describe "R3 handler contract" do
    test "post_document refuses the count cause and post_count refuses every other document" do
      args = fn type, cause ->
        %{
          "document_id" => "d",
          "document_type" => type,
          "version_no" => 1,
          "org_unit_id" => "u",
          "mark" => "posted",
          "posting" => %{"cause" => cause, "lines" => []}
        }
      end

      multi = Ecto.Multi.new()

      assert Handlers.post_document(multi, nil, args.("count.differences", "count_difference")) ==
               {:error, :invalid_arguments}

      assert Handlers.post_count(multi, nil, args.("stock_receipt", "count_difference")) ==
               {:error, :invalid_arguments}

      assert Handlers.post_count(multi, nil, args.("count.differences", "receipt")) ==
               {:error, :invalid_arguments}

      assert Handlers.post_count(multi, nil, %{}) == {:error, :invalid_arguments}
    end
  end

  # --- P: the posting ---------------------------------------------------------------------------

  describe "P1 start" do
    test "post starts one instance with a pending task; refusals", ctx do
      x = world!(ctx, :a)
      counted = counted!(x)

      assert reason!(call(:post, "/counts/#{counted}/post", x.chair_tok, %{}), 422) ==
               "count_state_invalid"

      assert reason!(
               call(:post, "/counts/#{counted}/reverse", x.chair_tok, %{
                 "reason_code" => "other",
                 "reason_text" => "x"
               }),
               409
             ) ==
               "count_not_posted"

      # a second count of the same locations needs the first one out of the way
      status!(call(:post, "/counts/#{counted}/cancel", x.chair_tok, %{}), 200)

      id = signed!(x)
      before_post = count(x, id)
      assert before_post["posting_state"] == "none" and before_post["post_pending"] == false
      assert before_post["posting_check"] == nil

      assert reason!(call(:post, "/counts/#{id}/post", x.chair_tok, %{"x" => 1}), 422) ==
               "field_not_allowed"

      pending = post!(x, id)
      assert pending["posting_state"] == "pending" and pending["post_pending"] == true
      assert pending["status"] == "signed"

      assert reason!(call(:post, "/counts/#{id}/post", x.chair_tok, %{}), 409) ==
               "posting_pending"

      instances =
        Repo.aggregate(
          from(p in InstanceProjection,
            where: fragment("?->>'document_id' = ?", p.variables, ^diff_id(x, id))
          ),
          :count,
          prefix: x.s
        )

      assert instances == 1
      assert marks(x, id) == 0
    end
  end

  describe "P2 P5 completion and the posting record" do
    test "one entry, one mark, balances move by the differences, record issued", ctx do
      x = world!(ctx, :a)
      id = signed!(x)
      view = count(x, id)
      all_before = total(x)
      post!(x, id)

      assert reason!(call(:post, "/counts/#{id}/posting-record", x.chair_tok, %{}), 409) ==
               "count_not_posted"

      complete!(x, id)

      [entry] = movements(x, id)
      assert entry["cause"] == "count_difference" and entry["reason_code"] == "count"
      assert entry["document_type"] == "count.differences"
      assert entry["document_id"] == view["differences_document_id"]
      assert entry["related_document_id"] == view["document_id"]
      assert entry["correlation_id"] == id
      assert length(entry["legs"]) == 3

      {:ok, signed_at, _} = DateTime.from_iso8601(view["differences_signed_at"])
      {:ok, event_time, _} = DateTime.from_iso8601(entry["event_time"])
      assert DateTime.compare(signed_at, event_time) == :eq

      signed =
        entry["legs"]
        |> Enum.map(
          &(&1["quantity"]
            |> Decimal.new()
            |> Decimal.normalize()
            |> Decimal.to_string())
        )
        |> Enum.sort()

      assert signed == ["-1", "-7", "2"]
      # the Balances figure moves by the sum of the differences: -7 - 1 + 2
      assert Decimal.equal?(total(x), Decimal.add(all_before, Decimal.new(-6)))
      assert marks(x, id) == 1

      read = count(x, id)
      assert read["posting_state"] == "posted" and read["posting_check"] == "ok"
      assert read["entry_id"] == entry["entry_id"] and is_binary(read["posted_at"])
      assert read["posted_by"] == x.holder.id and read["status"] == "signed"
      assert reason!(call(:post, "/counts/#{id}/post", x.chair_tok, %{}), 409) == "count_posted"

      # the record: the chair only, once
      assert reason!(call(:post, "/counts/#{id}/posting-record", x.member_tok, %{}), 422) ==
               "not_chair"

      done = status!(call(:post, "/counts/#{id}/posting-record", x.chair_tok, %{}), 200)
      assert done["status"] == "posted" and is_binary(done["posting_document_id"])
      assert done["posting_number"] =~ ~r/\ACP-\d{4}-0001\z/

      assert reason!(call(:post, "/counts/#{id}/posting-record", x.chair_tok, %{}), 409) ==
               "posting_record_exists"

      doc = status!(call(:get, "/counts/#{id}/posting-document", x.member_tok), 200)
      assert doc["number_label"] =~ ~r/\ACP-/
      assert doc["version_no"] == 1 and is_binary(doc["content_hash"])
      refute Map.has_key?(doc, "content")

      # old fields survive the whole-document replace
      assert done["differences_document_id"] == view["differences_document_id"]
      assert done["differences_signed_at"] == view["differences_signed_at"]
    end

    test "P3 postings during counting stay valid; the correction is a delta (no freeze)", ctx do
      x = world!(ctx, :a)
      id = signed!(x)

      sku =
        Repo.one!(
          from(l in Letflow.Entities.Record.Latest,
            where:
              l.entity_type == "count_sheet_line" and
                fragment("?->>'location_id' = ?", l.field_values, ^x.w.a),
            select: fragment("?->>'catalog_item_id'", l.field_values),
            limit: 1
          ),
          prefix: x.s
        )

      assert Decimal.equal?(balance(x, sku), Decimal.new(10))

      # goods arrive after the cut-off and before the posting
      S.post!(x.s, "receipt", %{lines: [S.line(sku, "5", %{to: S.side(x.w.unit, x.w.a)})]})
      post!(x, id)
      complete!(x, id)
      # balance now + delta (-7), not "counted = balance"
      assert Decimal.equal?(balance(x, sku), Decimal.new(8))
    end
  end

  describe "P4 refused completions write nothing" do
    test "insufficient stock keeps the task pending and the count signed", ctx do
      x = world!(ctx, :a)
      id = signed!(x)
      sku = shortage_sku!(x)
      # the post starts while the balance is enough; then goods leave: 9 of 10, the shortage of 7
      # now exceeds the balance (the race the early check cannot see)
      post!(x, id)
      S.post!(x.s, "issue", %{lines: [S.line(sku, "9", %{from: S.side(x.w.unit, x.w.a)})]})
      task = task!(x, id, "post")
      assert {:error, _} = P.complete(x, task)
      assert Repo.get!(Task, task.id, prefix: x.s).status == :pending
      assert marks(x, id) == 0
      assert movements(x, id) == []
      assert count(x, id)["posting_state"] == "pending"
    end

    test "T2 a shortage above the balance is named at post time and nothing is written", ctx do
      x = world!(ctx, :a)
      id = signed!(x)
      sku = shortage_sku!(x)
      S.post!(x.s, "issue", %{lines: [S.line(sku, "9", %{from: S.side(x.w.unit, x.w.a)})]})
      body = status!(call(:post, "/counts/#{id}/post", x.chair_tok, %{}), 422)
      assert body["reason"] == "shortage_exceeds_balance"
      ext = body["extensions"] || body
      assert ext["catalog_item_id"] == sku
      assert ext["location_id"] == x.w.a
      assert is_integer(ext["line_no"])
      refute inspect(body) =~ "quantity"
      assert P.pending_task(x, diff_id(x, id), "post") == nil
      assert marks(x, id) == 0
      assert count(x, id)["posting_state"] == "none"
    end

    test "T3 without a ledger read the early check is skipped", ctx do
      x = world!(ctx, :a)
      id = signed!(x)
      sku = shortage_sku!(x)
      S.post!(x.s, "issue", %{lines: [S.line(sku, "9", %{from: S.side(x.w.unit, x.w.a)})]})
      opts = %{actor_id: x.chair_user.id, scope: :all}

      # no activator here, so the call stops at the definition step, i.e. after the early check
      assert {:error, :definition_not_active} =
               Letflow.Modules.Stock.CountPosting.post(x.s, id, Map.put(opts, :authorized, nil))
    end

    test "an old signing time is refused at completion (96 hours)", ctx do
      x = world!(ctx, :a)
      id = signed!(x, now: DateTime.add(DateTime.utc_now(), -97 * 3600))
      post!(x, id)
      task = task!(x, id, "post")
      assert {:error, _} = P.complete(x, task)
      assert marks(x, id) == 0 and movements(x, id) == []
      assert count(x, id)["status"] == "signed"
    end

    test "a TASK_WORKER cannot complete the post task", ctx do
      x = world!(ctx, :a)
      id = signed!(x)
      post!(x, id)
      worker = TokenMintFixture.role_holder!(x.s, ["TASK_WORKER"])
      task = task!(x, id, "post")
      assert {:error, _} = P.complete(x, task, user: worker)
      assert {:error, _} = P.complete(x, task, credential: :api_token)
      assert marks(x, id) == 0 and movements(x, id) == []
    end
  end

  describe "P6 an empty differences sheet" do
    test "no ledger call; the record is issued without an entry", ctx do
      x = world!(ctx, :a)
      id = signed!(x, exact: true)
      assert reason!(call(:post, "/counts/#{id}/post", x.chair_tok, %{}), 422) == "no_differences"
      done = status!(call(:post, "/counts/#{id}/posting-record", x.chair_tok, %{}), 200)
      assert done["status"] == "posted" and done["posting_state"] == "none"
      assert movements(x, id) == [] and marks(x, id) == 0
    end

    test "T1 differences_empty is true only for a signed empty sheet", ctx do
      x = world!(ctx, :a)
      empty = signed!(x, exact: true)
      assert count(x, empty)["differences_empty"] == true
      assert count(x, empty)["posting_state"] == "none"

      xb = world!(ctx, :b)
      full = signed!(xb)
      assert count(xb, full)["differences_empty"] == false

      xs = world!(ctx, :s)
      posted = posted!(xs)
      assert count(xs, posted)["differences_empty"] == false
    end
  end

  describe "P7 the posting check" do
    test "a changed quantity gives posted + mismatch and no detail", ctx do
      x = world!(ctx, :a)
      id = signed!(x)
      post!(x, id)
      task = task!(x, id, "post")
      instance = Repo.get!(InstanceProjection, task.instance_id, prefix: x.s)
      posting = instance.variables["posting"]
      lines = List.update_at(posting["lines"], 0, &Map.put(&1, "quantity", "1.5"))

      assert {:ok, _} =
               P.complete(x, task, output: %{"posting" => Map.put(posting, "lines", lines)})

      read = count(x, id)
      assert read["posting_state"] == "posted"
      assert read["posting_check"] == "mismatch"
      refute inspect(read) =~ "mismatch_detail"
    end
  end

  # --- V: the reversal --------------------------------------------------------------------------

  describe "V1 V2 V3 reversal of the whole count" do
    test "reverse restores the balances; the count documents stay", ctx do
      x = world!(ctx, :a)
      id = signed!(x)
      before_total = total(x)
      post!(x, id)
      complete!(x, id)
      assert not Decimal.equal?(total(x), before_total)

      for body <- [%{}, %{"reason_code" => "nope"}, %{"reason_code" => "other"}] do
        assert reason!(call(:post, "/counts/#{id}/reverse", x.chair_tok, body), 422) ==
                 "reason_invalid"
      end

      pending =
        status!(
          call(:post, "/counts/#{id}/reverse", x.chair_tok, %{"reason_code" => "wrong_quantity"}),
          200
        )

      assert pending["reverse_pending"] == true and pending["posting_state"] == "posted"

      assert reason!(
               call(:post, "/counts/#{id}/reverse", x.chair_tok, %{
                 "reason_code" => "wrong_quantity"
               }),
               409
             ) ==
               "reversal_pending"

      complete!(x, id, "reverse")

      assert Decimal.equal?(total(x), before_total)
      rows = movements(x, id)
      assert Enum.sort(Enum.map(rows, & &1["cause"])) == ["count_difference", "reversal"]
      original = Enum.find(rows, &(&1["cause"] == "count_difference"))
      reversal = Enum.find(rows, &(&1["cause"] == "reversal"))
      assert reversal["reverses_entry_id"] == original["entry_id"]
      # R4: the reversal carries the same related document
      assert reversal["related_document_id"] == original["related_document_id"]
      assert length(reversal["legs"]) == 3
      assert marks(x, id) == 2

      read = count(x, id)
      assert read["posting_state"] == "reversed" and read["posting_check"] == "ok"
      assert read["reversed_by"] == x.holder.id and is_binary(read["reversed_at"])
      assert read["status"] == "signed"

      assert reason!(
               call(:post, "/counts/#{id}/reverse", x.chair_tok, %{
                 "reason_code" => "wrong_quantity"
               }),
               409
             ) ==
               "count_reversed"

      # V3: the record is refused after a reversal; the status stays signed
      assert reason!(call(:post, "/counts/#{id}/posting-record", x.chair_tok, %{}), 409) ==
               "count_reversed"

      assert reason!(call(:post, "/counts/#{id}/post", x.chair_tok, %{}), 409) == "count_posted"

      assert reason!(call(:get, "/counts/#{id}/posting-document", x.chair_tok), 422) ==
               "count_not_posted"

      # the issued count documents are untouched
      for field <- ~w(document_id sheet_document_id differences_document_id) do
        assert is_binary(read[field])
      end
    end

    test "reversal after the record keeps status posted and restores balances", ctx do
      x = world!(ctx, :a)
      id = posted!(x)
      status!(call(:post, "/counts/#{id}/posting-record", x.chair_tok, %{}), 200)
      before_total = total(x)

      status!(
        call(:post, "/counts/#{id}/reverse", x.chair_tok, %{"reason_code" => "wrong_document"}),
        200
      )

      complete!(x, id, "reverse")
      assert not Decimal.equal?(total(x), before_total)
      read = count(x, id)
      assert read["status"] == "posted" and read["posting_state"] == "reversed"
    end
  end

  # --- T: tenancy and permissions ---------------------------------------------------------------

  @routes [
    {:post, "/post", %{}},
    {:post, "/reverse", %{"reason_code" => "wrong_document"}},
    {:post, "/posting-record", %{}},
    {:get, "/posting-document", nil}
  ]

  describe "T2 another tenant's count" do
    test "a plain 404 identical to an unknown id on all four routes", ctx do
      _a = world!(ctx, :a)
      b = world!(ctx, :b)
      id = signed!(b)
      unknown = Ecto.UUID.generate()

      for {m, p, body} <- @routes do
        got = call(m, "/counts/#{id}#{p}", ctx.tok_a, body)
        want = call(m, "/counts/#{unknown}#{p}", ctx.tok_a, body)
        assert got.status == 404, "#{m} #{p}"
        assert strip(got) == strip(want)
      end

      assert marks(b, id) == 0 and movements(b, id) == []
    end
  end

  describe "T3 scope and permissions" do
    test "a unit-scoped admin gets 404 on another unit's count", ctx do
      t = S.tenant!("cpost-s", Map.fetch!(ctx.names, :s))
      s = t.schema_name
      wx = F.world!(s)
      wy = F.world!(s)

      {:ok, oy} =
        Counts.create(s, F.input(wy, window()), %{actor_id: Ecto.UUID.generate(), scope: :all})

      tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-cpost")
      status!(call(:get, "/counts", tok), 200)
      user = Repo.one!(from(u in User, where: u.username == "scoped-cpost"), prefix: s)
      group = RSG.group_of!(s, "TENANT_ADMIN")
      _ = RSG.raw_delete_rows!(s, group, "TENANT_ADMIN")
      :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", wx.unit)
      unknown = Ecto.UUID.generate()

      for {m, p, body} <- @routes do
        got = call(m, "/counts/#{oy["id"]}#{p}", tok, body)
        want = call(m, "/counts/#{unknown}#{p}", tok, body)
        assert got.status == 404, "#{m} #{p}"
        assert strip(got) == strip(want)
      end
    end

    test "a role without the permission is forbidden on every route; only STOREKEEPER is granted stock",
         ctx do
      x = world!(ctx, :a)
      id = signed!(x)
      tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-cpost")

      for {m, p, body} <- @routes do
        assert call(m, "/counts/#{id}#{p}", tok, body).status == 403, "#{m} #{p}"
      end

      assert Map.keys(Letflow.Modules.Stock.manifest().role_grants) == [:STOREKEEPER]
    end
  end
end
