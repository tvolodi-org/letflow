defmodule Letflow.Routers.PromotionReadStoredIdsTest do
  @moduledoc """
  ISS-1029 (Q-1011 / GH #2311): the three promotion READ routes re-check the review's STORED
  `source_tenant_id` / `target_tenant_id` against the caller, as approve, reject, apply and
  run-assertions already do (ISS-1026). A non-operator holder of `:PromotionsRead` (`TENANT_ADMIN`
  of tenant A; the platform pin is on P) who reads a review whose stored plan names a foreign
  tenant must get the SAME 404 as for a nonexistent review, and the list must not show it.
  The operator (`PLATFORM_ADMIN` of the pinned P) and own-tenant reviews are unchanged.

  Reviews are seeded through the real `PromotionReviewStore.insert_review/2`
  (`Scope.seed_review!/4`). `async: false` (VM-global platform pin, restored by the fixture).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn, only: [assign: 3]

  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Definitions.PromotionReview

  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope

  @reader ["TENANT_ADMIN"]
  @operator ["PLATFORM_ADMIN"]

  setup do
    # a = the non-operator reader's tenant, b = a foreign tenant, p = the pinned platform tenant
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, Map.put(tenants, :caller, Ecto.UUID.generate())}
  end

  defp get_resp(fixture, path, roles, user_id) do
    conn = Fixture.router_conn(:get, path, fixture, roles, nil)
    ac = %{conn.assigns.auth_context | user_id: user_id}

    Letflow.Routers.Promotions.call(
      assign(conn, :auth_context, ac),
      Letflow.Routers.Promotions.init([])
    )
  end

  # The bytes a non-operator sees for a nonexistent review id: the baseline a foreign-named review
  # must reproduce on each per-review read route.
  defp baseline(ctx, suffix, fixture \\ nil) do
    resp = get_resp(fixture || ctx.a, "/#{Ecto.UUID.generate()}#{suffix}", @reader, ctx.caller)
    assert resp.status == 404
    Scope.observable(resp)
  end

  defp list_ids(resp) do
    assert resp.status == 200
    resp.resp_body |> Jason.decode!() |> Map.fetch!("items") |> Enum.map(& &1["id"])
  end

  describe "non-operator reader, review naming a foreign tenant in its own schema" do
    setup %{a: a, b: b} do
      %{review: review} = Scope.seed_review!(a, a.tenant_id, b.tenant_id)
      {:ok, review_id: review.id}
    end

    test "GET /:id/context answers the nonexistent-review 404 bytes", ctx do
      resp = get_resp(ctx.a, "/#{ctx.review_id}/context", @reader, ctx.caller)
      assert Scope.observable(resp) == baseline(ctx, "/context")
    end

    test "GET /:id (assertion run) answers the nonexistent-review 404 bytes", ctx do
      resp = get_resp(ctx.a, "/#{ctx.review_id}", @reader, ctx.caller)
      assert Scope.observable(resp) == baseline(ctx, "")
    end

    test "GET / (list) omits the review", ctx do
      ids = list_ids(get_resp(ctx.a, "/", @reader, ctx.caller))
      refute ctx.review_id in ids
    end
  end

  describe "controls: own-tenant review and operator are unchanged" do
    test "a review naming only the reader's own tenant reads 200 and is listed", ctx do
      %{review: review} = Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.a.tenant_id)

      ctx_resp = get_resp(ctx.a, "/#{review.id}/context", @reader, ctx.caller)
      assert ctx_resp.status == 200
      assert review.id in list_ids(get_resp(ctx.a, "/", @reader, ctx.caller))
    end

    test "the operator still reads a review naming foreign tenants (200)", ctx do
      %{review: review} = Scope.seed_review!(ctx.p, ctx.a.tenant_id, ctx.b.tenant_id)

      resp = get_resp(ctx.p, "/#{review.id}/context", @operator, ctx.caller)
      assert resp.status == 200
    end
  end

  # --- ISS-1029 additions: the extended matrix (design revision 1, tests 1(a)..1(i)) ----------

  # Seeds one review per entry of `spec` (given NEWEST FIRST) in `fixture`'s schema and pins
  # their `inserted_at` so the list order is exactly `spec` order. Entry kinds: `:own`
  # (own/own ids), `:hidden` (own source, foreign target), `{:raw, json_text}` (own/own seeded,
  # then the stored plan text overwritten verbatim). Returns `[{kind, review}]` in spec order.
  defp seed_ordered!(fixture, foreign_id, spec) do
    base = DateTime.utc_now() |> DateTime.truncate(:second)
    own = fixture.tenant_id

    spec
    |> Enum.with_index()
    |> Enum.map(fn {kind, idx} ->
      target = if kind == :hidden, do: foreign_id, else: own
      %{review: review} = Scope.seed_review!(fixture, own, target)
      query = from(r in PromotionReview, where: r.id == ^review.id)

      case kind do
        {:raw, text} ->
          {1, _} =
            Repo.update_all(query, [set: [serialised_plan: text]], prefix: fixture.schema_name)

        _ ->
          :ok
      end

      ts = DateTime.add(base, -idx, :second)
      {1, _} = Repo.update_all(query, [set: [inserted_at: ts]], prefix: fixture.schema_name)

      {kind, %{review | inserted_at: ts}}
    end)
  end

  defp ids_of(rows, kind), do: for({k, r} <- rows, k == kind, do: r.id)

  defp list_page(ctx, fixture, roles, query) do
    resp = get_resp(fixture, "/?" <> query, roles, ctx.caller)
    assert resp.status == 200, "list answered #{resp.status}: #{resp.resp_body}"
    body = Jason.decode!(resp.resp_body)
    {Enum.map(body["items"], & &1["id"]), body["next_cursor"]}
  end

  # Pages through the list; returns [{ids, next_cursor}] for every page requested.
  defp walk(ctx, fixture, roles, page_size), do: do_walk(ctx, fixture, roles, page_size, nil, [])

  defp do_walk(_ctx, _f, _r, _ps, _cur, acc) when length(acc) > 400,
    do: flunk("list paging did not terminate")

  defp do_walk(ctx, fixture, roles, page_size, cursor, acc) do
    q = "page_size=#{page_size}" <> if(cursor, do: "&cursor=#{cursor}", else: "")
    {ids, next} = list_page(ctx, fixture, roles, q)
    acc = acc ++ [{ids, next}]
    if next, do: do_walk(ctx, fixture, roles, page_size, next, acc), else: acc
  end

  defp assert_exact_union(pages, expected_ids) do
    all = Enum.flat_map(pages, &elem(&1, 0))
    assert all == expected_ids, "pages #{inspect(all)} != visible rows #{inspect(expected_ids)}"
    assert pages |> List.last() |> elem(1) == nil
  end

  describe "1(a) GET /:id of a foreign-named review that has an assertion run" do
    test "answers the nonexistent baseline and carries no run data", ctx do
      %{review: review} = Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.b.tenant_id)

      Repo.insert!(
        %PromotionAssertionRun{
          review_id: review.id,
          idempotency_key: "iss1029-#{System.unique_integer([:positive, :monotonic])}",
          plan_digest: review.plan_digest,
          status: :failed,
          assertions_total: 2,
          assertions_passed: 1,
          assertions_failed: 1,
          failing_assertion_ids: ["ISS1029-FAILING-ASSERTION"],
          completed_at: DateTime.utc_now()
        },
        prefix: ctx.a.schema_name
      )

      resp = get_resp(ctx.a, "/#{review.id}", @reader, ctx.caller)
      assert Scope.observable(resp) == baseline(ctx, "")
      refute resp.resp_body =~ "ISS1029-FAILING-ASSERTION"
      refute resp.resp_body =~ "failing_assertion_ids"
      refute resp.resp_body =~ "assertions_failed"
    end
  end

  describe "1(b) non-UUID id on both per-review routes" do
    test "is the unchanged 404", ctx do
      for suffix <- ["", "/context"] do
        resp = get_resp(ctx.a, "/not-a-uuid#{suffix}", @reader, ctx.caller)
        assert resp.status == 404
        assert Scope.observable(resp) == baseline(ctx, suffix)
      end
    end
  end

  describe "1(c) list paging with hidden rows at page boundaries" do
    for {name, spec} <- [
          {"V H V", [:own, :hidden, :own]},
          {"H H V V", [:hidden, :hidden, :own, :own]},
          {"V H H", [:own, :hidden, :hidden]},
          {"H V H V H", [:hidden, :own, :hidden, :own, :hidden]}
        ],
        page_size <- [1, 2] do
      test "#{name} at page_size #{page_size}: only visible rows, each once, final cursor nil",
           ctx do
        rows = seed_ordered!(ctx.a, ctx.b.tenant_id, unquote(spec))
        pages = walk(ctx, ctx.a, @reader, unquote(page_size))
        assert_exact_union(pages, ids_of(rows, :own))

        # no page is short unless it is the last one
        assert pages
               |> Enum.drop(-1)
               |> Enum.all?(fn {ids, _} -> length(ids) == unquote(page_size) end)
      end
    end

    test "a schema whose rows are ALL hidden lists as the empty list with a nil cursor", ctx do
      seed_ordered!(ctx.a, ctx.b.tenant_id, [:hidden, :hidden, :hidden])
      assert [{[], nil}] = walk(ctx, ctx.a, @reader, 1)
      assert [{[], nil}] = walk(ctx, ctx.a, @reader, 2)

      # byte-identical to a schema that never had the rows
      mine = get_resp(ctx.a, "/?page_size=1", @reader, ctx.caller)
      empty = get_resp(ctx.b, "/?page_size=1", @reader, ctx.caller)
      assert Jason.decode!(mine.resp_body) == Jason.decode!(empty.resp_body)
    end
  end

  describe "1(d) no cursor encodes a hidden row" do
    test "cursors carry only emitted rows; an empty page never has a cursor", ctx do
      rows =
        seed_ordered!(ctx.a, ctx.b.tenant_id, [
          :hidden,
          :own,
          :hidden,
          :hidden,
          :own,
          :own,
          :hidden
        ])

      hidden = for {:hidden, r} <- rows, do: r
      pages = walk(ctx, ctx.a, @reader, 1) ++ walk(ctx, ctx.a, @reader, 2)

      for {ids, cursor} <- pages do
        if ids == [], do: assert(cursor == nil)

        if cursor do
          {:ok, decoded} = Base.url_decode64(cursor, padding: false)

          for h <- hidden do
            refute decoded =~ h.id
            refute decoded =~ Integer.to_string(DateTime.to_unix(h.inserted_at, :microsecond))
          end
        end
      end
    end

    test "an all-hidden schema never yields a cursor", ctx do
      seed_ordered!(ctx.a, ctx.b.tenant_id, [:hidden, :hidden])
      assert [{[], nil}] = walk(ctx, ctx.a, @reader, 1)
    end
  end

  # The hidden runs are far larger than the 100-row minimum scan chunk and than any row budget
  # a capped implementation would plausibly use (a cap of 1000 rows is still killed).
  describe "1(e) a long hidden run never hides or strands a visible row" do
    test "one visible row behind 1100 newer hidden rows is returned by the first request", ctx do
      rows = seed_ordered!(ctx.a, ctx.b.tenant_id, List.duplicate(:hidden, 1100) ++ [:own])
      assert length(rows) == 1101
      assert [{ids, nil}] = walk(ctx, ctx.a, @reader, 1)
      assert ids == ids_of(rows, :own)
    end

    test "a visible row in the middle of two 250-row hidden runs", ctx do
      spec = List.duplicate(:hidden, 250) ++ [:own] ++ List.duplicate(:hidden, 250)
      rows = seed_ordered!(ctx.a, ctx.b.tenant_id, spec)
      assert [{ids, nil}] = walk(ctx, ctx.a, @reader, 1)
      assert ids == ids_of(rows, :own)
    end
  end

  describe "1(f) malformed and legacy stored plans" do
    @malformed [
      {"JSON string", ~s("x")},
      {"JSON array", "[1]"},
      {"JSON number", "7"},
      {"JSON null", "null"},
      {"truncated JSON", ~s({"a":)},
      {"map missing the ids", ~s({"entries":[]})}
    ]

    test "non-operator list answers 200, shows only own/own rows, pages consistently", ctx do
      spec = Enum.flat_map(@malformed, fn {_n, text} -> [:own, {:raw, text}] end) ++ [:own]
      rows = seed_ordered!(ctx.a, ctx.b.tenant_id, spec)

      for page_size <- [1, 3] do
        assert_exact_union(walk(ctx, ctx.a, @reader, page_size), ids_of(rows, :own))
      end
    end

    test "the operator list is unfiltered and includes the malformed rows", ctx do
      spec = [:own | Enum.map(@malformed, fn {_n, text} -> {:raw, text} end)]
      rows = seed_ordered!(ctx.p, ctx.b.tenant_id, spec)

      listed = ctx |> walk(ctx.p, @operator, 50) |> Enum.flat_map(&elem(&1, 0))
      assert listed == Enum.map(rows, fn {_k, r} -> r.id end)
    end
  end

  describe "1(g) list filters compose with the visibility filter" do
    test "status and def_id filters return only visible rows of that status/def", ctx do
      rows = seed_ordered!(ctx.a, ctx.b.tenant_id, [:hidden, :own, :hidden, :own])
      [{:own, first_own} | _] = Enum.filter(rows, &match?({:own, _}, &1))

      {ids, nil} = list_page(ctx, ctx.a, @reader, "status=pending_review&page_size=10")
      assert ids == ids_of(rows, :own)

      {ids, nil} = list_page(ctx, ctx.a, @reader, "status=approved&page_size=10")
      assert ids == []

      {ids, nil} = list_page(ctx, ctx.a, @reader, "def_id=#{first_own.def_id}&page_size=10")
      assert ids == [first_own.id]
    end
  end

  describe "1(h) operator list" do
    test "includes the foreign-named review with an unchanged cursor shape", ctx do
      rows = seed_ordered!(ctx.p, ctx.b.tenant_id, [:hidden, :own, :hidden])
      pages = walk(ctx, ctx.p, @operator, 2)
      assert Enum.flat_map(pages, &elem(&1, 0)) == Enum.map(rows, fn {_k, r} -> r.id end)
      assert [{[_, _], cursor}, {[_], nil}] = pages
      assert is_binary(cursor)
    end
  end

  describe "1(i) AC4: TENANT_ADMIN of the platform tenant" do
    for pin <- [:pinned, :unpinned] do
      test "reads an operator-seeded foreign-named review as 404 (#{pin})", ctx do
        if unquote(pin) == :unpinned, do: Fixture.unpin!()

        %{review: foreign} = Scope.seed_review!(ctx.p, ctx.a.tenant_id, ctx.b.tenant_id)
        %{review: own} = Scope.seed_review!(ctx.p, ctx.p.tenant_id, ctx.p.tenant_id)

        for suffix <- ["", "/context"] do
          resp = get_resp(ctx.p, "/#{foreign.id}#{suffix}", @reader, ctx.caller)
          assert Scope.observable(resp) == baseline(ctx, suffix, ctx.p)
        end

        {ids, _} = list_page(ctx, ctx.p, @reader, "page_size=10")
        refute foreign.id in ids
        assert own.id in ids
      end
    end

    test "the operator (PLATFORM_ADMIN of the pinned P) reads it on all three routes", ctx do
      %{review: foreign} = Scope.seed_review!(ctx.p, ctx.a.tenant_id, ctx.b.tenant_id)

      for suffix <- ["", "/context"] do
        assert get_resp(ctx.p, "/#{foreign.id}#{suffix}", @operator, ctx.caller).status == 200
      end

      {ids, _} = list_page(ctx, ctx.p, @operator, "page_size=10")
      assert foreign.id in ids
    end
  end
end
