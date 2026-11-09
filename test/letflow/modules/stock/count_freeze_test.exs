Code.require_file("count_freeze_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountFreezeTest do
  @moduledoc """
  REQ-765 / GH #3906 (K9b, owner decision D-094), criteria 1 to 5 and 9: the freeze locations mode of a
  count order. Order flag and setting (F1, F3), freeze start (F5, F6), the guard per document kind
  (F7, F8, F9, F10, F11), the count's own posting (F12 to F14), the end by posting, cancel and limit
  (F15 to F19), audit without quantities (F28, F29). Committed tenants in Sandbox `:auto` mode,
  `async: false`, through the full `Letflow.Router` with real OIDC bearer tokens; a task is completed
  through `Letflow.Engine.complete_task/3` with the OIDC credential.
  """

  use Letflow.DataCase, async: false

  alias Letflow.CountFreezeFixture, as: C
  alias Letflow.CountsFixture, as: F
  alias Letflow.Modules.Installs
  alias Letflow.Modules.Stock.Counts
  alias Letflow.Modules.Stock.FreezeState
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockTwoSideFixture, as: T

  setup do
    ctx = S.setup_oidc!([:a, :b])
    Map.put(ctx, :tok_a, S.token(ctx, :a, ["TENANT_ADMIN"]))
  end

  defp rows_of(x, type) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT field_values::text FROM "#{x.s}".entity_record_latest WHERE entity_type = $1 AND NOT deleted|,
        [type]
      )

    Enum.map(rows, fn [t] -> Jason.decode!(t) end)
  end

  defp stored(x, id) do
    {:ok, h} = Counts.header(x.s, id, :all)
    h
  end

  defp set_until!(x, id, iso) do
    h = stored(x, id)

    attrs = %{
      entity_type: "count_order",
      record_id: id,
      field_values: Map.drop(h, ["record_id", "entity_type"]) |> Map.put("freeze_until", iso),
      actor_id: x.chair_user.id,
      idempotency_key: "test:" <> Ecto.UUID.generate()
    }

    owner = Letflow.Entities.ManagedTypes.owner_for!(Letflow.Modules.Stock)
    # scope-all: SEC-518-R1 (test setup: moves the stored limit into the past)
    assert {:ok, _} = Letflow.Entities.Records.update_record(attrs, x.s, owner)
  end

  # Books 100 of the plain item at `a1` and at `b` before any freeze.
  defp stock!(x) do
    C.receive!(x, x.ma, "100")
    C.receive!(x, C.at(x, x.w.b), "100")
    :ok
  end

  # --- criterion 1 ------------------------------------------------------------------------------

  test "F1 the flag: true/false accepted, default false, anything else field_invalid; the issued content carries it",
       ctx do
    x = C.world!(ctx, :a)
    base = F.input(x.w, C.window())

    for v <- [true, false] do
      created =
        C.status!(
          C.call(:post, "/counts", x.chair_tok, Map.put(base, "freeze_locations", v)),
          201
        )

      assert created["freeze_locations"] == v and created["freeze_state"] == "none"
    end

    absent = C.status!(C.call(:post, "/counts", x.chair_tok, base), 201)
    assert absent["freeze_locations"] == false

    for bad <- ["yes", 1, nil, "true"] do
      conn = C.call(:post, "/counts", x.chair_tok, Map.put(base, "freeze_locations", bad))
      assert conn.status == 422 or conn.status == 400, conn.resp_body
      assert conn.resp_body =~ "freeze_locations"
    end

    put =
      C.status!(
        C.call(
          :put,
          "/counts/#{absent["id"]}",
          x.chair_tok,
          Map.put(base, "freeze_locations", true)
        ),
        200
      )

    assert put["freeze_locations"] == true
    C.status!(C.call(:post, "/counts/#{absent["id"]}/issue", x.chair_tok, %{}), 200)
    doc = C.status!(C.call(:get, "/counts/#{absent["id"]}/document", x.chair_tok), 200)
    content = Letflow.Modules.Stock.Documents.Posting.issued(x.s, doc["document_id"]).content
    assert content["freeze_locations"] == true
  end

  test "F3 the setting count_freeze_limit_minutes: 120 accepted; 0, 5761 and a string refused",
       ctx do
    x = C.world!(ctx, :a)

    assert {:ok, _} =
             Installs.put_settings("stock", %{"count_freeze_limit_minutes" => 120}, prefix: x.s)

    assert FreezeState.limit_minutes(x.s) == 120

    for bad <- [0, 5761, "x", %{"other" => 1}] do
      settings = if is_map(bad), do: bad, else: %{"count_freeze_limit_minutes" => bad}

      assert {:error, {:settings_validation_failed, _}} =
               Installs.put_settings("stock", settings, prefix: x.s)
    end

    assert {:ok, _} =
             Installs.put_settings("stock", %{"count_freeze_limit_minutes" => 5760}, prefix: x.s)

    assert FreezeState.limit_minutes(x.s) == 5760
  end

  # --- criterion 2 ------------------------------------------------------------------------------

  test "F5 open: freeze active, started = cut-off, until = +120 (absent) / +30 (set), rows for the subtree, one audit",
       ctx do
    x = C.world!(ctx, :a)
    id = C.ordered!(x, %{"freeze_locations" => true})
    assert C.count(x, id)["freeze_state"] == "none"
    opened = C.status!(C.call(:post, "/counts/#{id}/open", x.chair_tok, %{}), 200)

    assert opened["freeze_state"] == "active" and
             opened["freeze_started_at"] == opened["cut_off_at"]

    {:ok, from, _} = DateTime.from_iso8601(opened["freeze_started_at"])
    {:ok, until, _} = DateTime.from_iso8601(opened["freeze_until"])
    assert DateTime.diff(until, from) == 120 * 60

    locations =
      rows_of(x, "count_freeze_location") |> Enum.map(& &1["location_id"]) |> Enum.sort()

    assert locations == Enum.sort([x.w.a, x.w.a1, x.w.a11])

    assert Enum.all?(
             rows_of(x, "count_freeze_location"),
             &(&1["count_order_id"] == id and &1["org_unit_id"] == x.w.unit)
           )

    assert [{^id, after_state}] = C.audits(x.s, "stock.count.freeze_started")
    state = Jason.decode!(after_state)
    assert state["locations"] == 3 and state["freeze_until"] == opened["freeze_until"]
    refute after_state =~ "quantity"

    # a second tenant of the test world with the setting at 30
    y = C.world!(ctx, :b)

    assert {:ok, _} =
             Installs.put_settings("stock", %{"count_freeze_limit_minutes" => 30}, prefix: y.s)

    id2 = C.frozen!(y)
    o2 = C.count(y, id2)
    {:ok, f2, _} = DateTime.from_iso8601(o2["freeze_started_at"])
    {:ok, u2, _} = DateTime.from_iso8601(o2["freeze_until"])
    assert DateTime.diff(u2, f2) == 30 * 60
  end

  test "F6 a refused open writes nothing (not the chair, count not due)", ctx do
    x = C.world!(ctx, :a)
    id = C.ordered!(x, %{"freeze_locations" => true})
    conn = C.call(:post, "/counts/#{id}/open", x.member_tok, %{})
    assert conn.status in 400..499
    assert rows_of(x, "count_freeze_location") == []
    assert C.audits(x.s, "stock.count.freeze_started") == []
    assert C.count(x, id)["status"] == "ordered"
  end

  # --- criterion 3 ------------------------------------------------------------------------------

  defp issue_body(x, kind) do
    m = x.ma

    case kind do
      k when k in ["issue", "write_off"] ->
        D.body(m, nil, %{"kind" => k, "lines" => [C.plain_line(m, "1")]})
        |> Map.delete("counterparty_id")
        |> then(&if(k == "write_off", do: Map.put(&1, "reason_code", "damaged"), else: &1))

      k when k in ["transfer", "hand_over", "return"] ->
        :two_side

      "receipt" ->
        D.body(m, nil, %{"lines" => [C.plain_line(m, "1")]})
    end
  end

  defp two_side(x, kind, from, to),
    do: T.body(kind, x.ma, from, to, %{"lines" => T.plain(x.ma, "1")})

  defp pending_post!(x, doc) do
    P.pending_task(x, doc["id"], "post") || flunk("no pending post task")
  end

  test "F7/F8/F10/F11 each kind is refused on a frozen key, the task stays pending, others post, all post after cancel",
       ctx do
    x = C.world!(ctx, :a)
    stock!(x)
    from = C.at(x, x.w.a1)
    outside = C.at(x, x.w.b)
    id = C.frozen!(x)
    number = C.count(x, id)["number"]
    assert is_binary(number)

    bodies =
      for kind <- ~w(receipt issue write_off), do: {kind, issue_body(x, kind)}

    bodies =
      bodies ++
        for kind <- ~w(transfer hand_over return),
            {side, f, t} <- [{"from", from, outside}, {"to", outside, from}] do
          {"#{kind}/#{side}", two_side(x, kind, f, t)}
        end

    docs =
      for {label, body} <- bodies do
        doc = P.issue!(x, body)
        task = pending_post!(x, doc)
        assert C.held_by!(P.complete(x, task)) == number, "#{label} was not refused"
        assert P.counts(x, doc["id"]) == %{entries: %{}, marks: 0}
        assert pending_post!(x, doc).id == task.id
        doc
      end

    # F7h opening: the approver is refused
    op = O.issue!(x, O.body(x.ma))
    approver = O.second_admin!(x)
    assert C.held_by!(O.approve(x, op["id"], approver)) == number
    assert P.counts(x, op["id"]) == %{entries: %{}, marks: 0}

    # F11 another org unit at the same location, and a location outside the set, post during the freeze
    other = %{x.m | location: x.w.a1}
    other_doc = P.issue!(x, D.body(other, nil, %{"lines" => [C.plain_line(other, "2")]}))
    assert %{"state" => "posted"} = P.post_and_complete!(x, other_doc["id"])
    out_doc = P.issue!(x, D.body(outside, nil, %{"lines" => [C.plain_line(outside, "2")]}))
    assert %{"state" => "posted"} = P.post_and_complete!(x, out_doc["id"])

    # F10 cancel ends the freeze at once; the same documents post now
    cancelled = C.cancel!(x, id)
    assert cancelled["freeze_state"] == "ended" and cancelled["freeze_end_reason"] == "cancelled"

    for doc <- docs do
      assert {:ok, _} = P.complete(x, pending_post!(x, doc))
      assert P.counts(x, doc["id"]).marks == 1
    end

    assert {:ok, _} = O.approve(x, op["id"], approver)
    assert P.counts(x, op["id"]).marks == 1
  end

  test "F9 the reversal of a posted receipt on a frozen key is refused, and posts after the freeze",
       ctx do
    x = C.world!(ctx, :a)
    posted = C.receive!(x, x.ma, "10")
    id = C.frozen!(x)
    number = C.count(x, id)["number"]

    P.req(x, :post, posted["id"], "reverse", %{"reason_code" => "wrong_document"})
    |> P.status!(200)

    task = P.pending_task(x, posted["id"], "reverse") || flunk("no reverse task")
    assert C.held_by!(P.complete(x, task)) == number
    assert P.counts(x, posted["id"]).entries == %{"receipt" => 1}

    C.cancel!(x, id)
    assert {:ok, _} = P.complete(x, task)
    assert P.counts(x, posted["id"]).entries["receipt"] == 1
  end

  # --- criterion 4 and 5 (own posting, end by posting) ------------------------------------------

  # The count with a shortage on a1 (book 100, counted 40) and a surplus line, signed, ready to post.
  defp signed!(x, opts \\ []) do
    C.receive!(x, x.ma, "100")
    id = C.frozen!(x)
    refused = P.issue!(x, D.body(x.ma, nil, %{"lines" => [C.plain_line(x.ma, "5")]}))
    assert C.held_by!(P.complete(x, pending_post!(x, refused))) == C.count(x, id)["number"]

    [line] = C.status!(C.call(:get, "/counts/#{id}/lines", x.chair_tok), 200)["rows"]

    C.status!(
      C.call(:put, "/counts/#{id}/lines/#{line["line_no"]}/count", x.member_tok, %{
        "counted_quantity" => "40"
      }),
      200
    )

    C.status!(
      C.call(:post, "/counts/#{id}/surplus-lines", x.member_tok, %{
        "location_id" => x.w.a1,
        "catalog_item_id" => x.m.lot_item,
        "unit_ref" => x.m.uom,
        "counted_quantity" => "2"
      }),
      201
    )

    C.status!(C.call(:post, "/counts/#{id}/close", x.chair_tok, %{}), 200)
    ids = [x.w.chair | x.w.members] ++ [x.m.employee]
    sig = %{"signer_employee_ids" => ids}
    C.status!(C.call(:post, "/counts/#{id}/sheet-signatures", x.chair_tok, sig), 200)
    C.status!(C.call(:post, "/counts/#{id}/differences", x.chair_tok, %{}), 200)

    if Keyword.get(opts, :sign, true),
      do: C.status!(C.call(:post, "/counts/#{id}/differences-signatures", x.chair_tok, sig), 200)

    {id, refused}
  end

  defp diff_task!(x, id), do: P.pending_task(x, C.count(x, id)["differences_document_id"], "post")

  test "F12/F13/F14/F15 the count's own posting passes, balances end at the counted quantity, the end by posting",
       ctx do
    x = C.world!(ctx, :a)
    {id, refused} = signed!(x)
    assert C.count(x, id)["freeze_state"] == "active"

    C.status!(C.call(:post, "/counts/#{id}/post", x.chair_tok, %{}), 200)
    task = diff_task!(x, id) || flunk("no count post task")
    assert {:ok, _} = P.complete(x, task)

    # F12 each counted key ends exactly at its counted quantity (nothing else posted in between)
    assert C.balance(x, x.m.item, x.w.a1) == "40"
    assert C.balance(x, x.m.lot_item, x.w.a1) == "2"

    # F15 the order reads ended/posted; a receipt into the scope posts now; the end audit is written once
    ended = C.count(x, id)
    assert ended["freeze_state"] == "ended" and ended["freeze_end_reason"] == "posted"
    assert {:ok, _} = P.complete(x, pending_post!(x, refused))
    assert C.audits(x.s, "stock.count.freeze_ended") == []

    C.status!(C.call(:post, "/counts/#{id}/posting-record", x.chair_tok, %{}), 200)
    assert [{^id, state}] = C.audits(x.s, "stock.count.freeze_ended")
    assert Jason.decode!(state)["reason"] == "posted"
    after_write = stored(x, id)
    assert after_write["freeze_state"] == "ended" and after_write["freeze_end_reason"] == "posted"
    assert is_binary(after_write["freeze_ended_at"])
  end

  test "F14 another count's differences document on a frozen key is refused location_frozen",
       ctx do
    x = C.world!(ctx, :a)
    {id, _refused} = signed!(x)
    number = C.count(x, id)["number"]

    other_diff = Ecto.UUID.generate()

    # the guard itself: a summary of another count's differences document is held, the order's own is not
    own = C.count(x, id)["differences_document_id"]
    key = %{"sku" => x.m.item, "location" => x.w.a1, "org_unit" => x.w.unit}

    summary = %{
      ledger_id: "stock",
      cause: "count_difference",
      keys: [key],
      document_type: "count.differences"
    }

    guard = &Letflow.Modules.Stock.FreezeGuard.check(x.s, Map.put(summary, :document_id, &1))
    assert guard.(other_diff) == {:held, number}
    assert guard.(own) == :ok
  end

  # --- criterion 5 ------------------------------------------------------------------------------

  test "F16/F17 cancel of a counting order ends the freeze at once; a signed one is refused and stays frozen",
       ctx do
    x = C.world!(ctx, :a)
    id = C.frozen!(x)
    cancelled = C.cancel!(x, id)
    assert cancelled["freeze_state"] == "ended" and cancelled["freeze_end_reason"] == "cancelled"

    assert is_binary(cancelled["freeze_ended_at"]) and
             cancelled["freeze_ended_at"] == stored(x, id)["cancelled_at"]

    assert [{^id, state}] = C.audits(x.s, "stock.count.freeze_ended")
    assert Jason.decode!(state)["reason"] == "cancelled"

    y = C.world!(ctx, :b)
    {sid, _} = signed!(y)
    conn = C.call(:post, "/counts/#{sid}/cancel", y.chair_tok, %{})
    assert conn.status == 422 and conn.resp_body =~ "count_state_invalid"
    assert C.count(y, sid)["freeze_state"] == "active"
  end

  test "F18/F19 past freeze_until: read expired, a receipt posts, the next count write stores it with one audit, the posting is the plain delta",
       ctx do
    x = C.world!(ctx, :a)
    C.receive!(x, x.ma, "100")
    id = C.frozen!(x)
    number = C.count(x, id)["number"]
    held = P.issue!(x, D.body(x.ma, nil, %{"lines" => [C.plain_line(x.ma, "7")]}))
    assert C.held_by!(P.complete(x, pending_post!(x, held))) == number

    set_until!(x, id, DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60)))
    view = C.count(x, id)
    assert view["freeze_state"] == "expired" and view["freeze_end_reason"] == "expired"
    assert stored(x, id)["freeze_state"] == "active"
    assert C.audits(x.s, "stock.count.freeze_expired") == []

    # the receipt that was refused now posts: 100 + 7
    assert {:ok, _} = P.complete(x, pending_post!(x, held))
    assert C.balance(x, x.m.item, x.w.a1) == "107"

    # the next count write stores the end and audits once; a second write audits nothing more
    [line] = C.status!(C.call(:get, "/counts/#{id}/lines", x.chair_tok), 200)["rows"]
    count_line = "/counts/#{id}/lines/#{line["line_no"]}/count"
    C.status!(C.call(:put, count_line, x.member_tok, %{"counted_quantity" => "90"}), 200)
    assert [{^id, _}] = C.audits(x.s, "stock.count.freeze_expired")
    after_write = stored(x, id)

    assert after_write["freeze_state"] == "expired" and
             after_write["freeze_end_reason"] == "expired"

    C.status!(C.call(:put, count_line, x.member_tok, %{"counted_quantity" => "91"}), 200)
    assert [{^id, _}] = C.audits(x.s, "stock.count.freeze_expired")
  end

  test "F19 the pure state function: cancelled beats posted beats expired, an unreadable limit never freezes for ever" do
    now = ~U[2026-11-10 10:00:00Z]

    base = %{
      "freeze_locations" => true,
      "freeze_started_at" => "2026-11-10T08:00:00Z",
      "freeze_until" => "2026-11-10T10:00:01Z",
      "status" => "counting"
    }

    assert FreezeState.state(base, now, false) == {"active", nil}
    assert FreezeState.state(base, ~U[2026-11-10 10:00:01Z], false) == {"expired", "expired"}
    assert FreezeState.state(base, ~U[2026-11-10 11:00:00Z], true) == {"ended", "posted"}

    assert FreezeState.state(%{base | "status" => "cancelled"}, ~U[2026-11-10 11:00:00Z], true) ==
             {"ended", "cancelled"}

    assert FreezeState.state(%{base | "freeze_until" => "garbage"}, now, false) ==
             {"expired", "expired"}

    assert FreezeState.state(%{base | "freeze_locations" => false}, now, false) == {"none", nil}
    assert FreezeState.state(Map.delete(base, "freeze_started_at"), now, false) == {"none", nil}
  end

  # --- criterion 9 ------------------------------------------------------------------------------

  test "F28/F29 the freeze audit entries hold no quantity; core audits the refusal as ledger.posting_held",
       ctx do
    x = C.world!(ctx, :a)
    C.receive!(x, x.ma, "100")
    id = C.frozen!(x)
    doc = P.issue!(x, D.body(x.ma, nil, %{"lines" => [C.plain_line(x.ma, "3")]}))
    C.held_by!(P.complete(x, pending_post!(x, doc)))
    C.cancel!(x, id)

    for action <- ~w(stock.count.freeze_started stock.count.freeze_ended) do
      assert [{^id, text}] = C.audits(x.s, action)
      refute text =~ ~r/quantity|book|counted/
    end

    assert [{_, held}] = C.audits(x.s, "ledger.posting_held") |> Enum.take(-1)
    assert held =~ C.count(x, id)["number"]
  end

  test "F28b the module source and runbook state the freeze (docs)" do
    runbook = File.read!("docs/runbooks/stock-counts.md")
    assert runbook =~ "freeze_locations" and runbook =~ "location_frozen"
    assert runbook =~ "count_freeze_limit_minutes"
  end
end
