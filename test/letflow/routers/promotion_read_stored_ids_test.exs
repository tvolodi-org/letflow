defmodule Letflow.Routers.PromotionReadStoredIdsTest do
  @moduledoc """
  ISS-1029 (Q-1011 / GH #2311, revised 10-point ACs): the three promotion READ routes
  (`GET /:id`, `GET /:id/context`, `GET /`) decide visibility from the review's STORED
  `source_tenant_id` / `target_tenant_id` against the AUTHENTICATED tenant:

    * a named PARTY (source OR target is the caller's tenant) keeps the ISS-1023 own-side view
      (200; `/:id` keeps the existing 7-key run map; the list shows the row);
    * a NON-PARTY non-operator (neither id is the caller's, or the ids are unreadable) gets the
      nonexistent-id 404 on the per-review routes (status, headers and body byte for byte) and
      the list omits the row with no placeholder, count or cursor gap;
    * the operator (`PLATFORM_ADMIN` of the pinned P) is unfiltered, even for unreadable rows.

  The write routes keep the strict both-sides predicate (covered by
  `promotion_approve_reject_stored_ids_test.exs`). Reviews are seeded through the real
  `PromotionReviewStore.insert_review/2` (`Scope.seed_review!/4`). `async: false` (VM-global
  platform pin, restored by the fixture).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn, only: [assign: 3, put_req_header: 3]

  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Definitions.PromotionReview

  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope

  @reader ["TENANT_ADMIN"]
  @operator ["PLATFORM_ADMIN"]

  @run_keys ~w(run_id status sandbox_id teardown_error assertions_passed assertions_failed failing_assertion_ids)

  setup do
    # a = the non-operator reader's tenant, b = a foreign tenant, p = the pinned platform tenant
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, Map.put(tenants, :caller, Ecto.UUID.generate())}
  end

  defp get_resp(fixture, path, roles, user_id, headers \\ []) do
    conn = Fixture.router_conn(:get, path, fixture, roles, nil)
    ac = %{conn.assigns.auth_context | user_id: user_id}
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    Letflow.Routers.Promotions.call(
      assign(conn, :auth_context, ac),
      Letflow.Routers.Promotions.init([])
    )
  end

  # The bytes a non-operator sees for a nonexistent review id: the baseline a non-party review
  # must reproduce on each per-review read route.
  defp baseline(ctx, suffix, fixture \\ nil, query \\ "", headers \\ []) do
    resp =
      get_resp(
        fixture || ctx.a,
        "/#{Ecto.UUID.generate()}#{suffix}#{query}",
        @reader,
        ctx.caller,
        headers
      )

    assert resp.status == 404
    Scope.observable(resp)
  end

  defp list_ids(resp) do
    assert resp.status == 200
    resp.resp_body |> Jason.decode!() |> Map.fetch!("items") |> Enum.map(& &1["id"])
  end

  defp insert_run!(fixture, review, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        PromotionAssertionRun,
        Map.merge(
          %{
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
          attrs
        )
      ),
      prefix: fixture.schema_name
    )
  end

  # --- AC10: the failing case re-seeded with a NON-party, plus party controls ------------------

  describe "non-operator reader, non-party review (b, p) in the reader's own schema" do
    setup %{a: a, b: b, p: p} do
      %{review: review} = Scope.seed_review!(a, b.tenant_id, p.tenant_id)
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

  describe "party controls (a, b) and (b, a): the ISS-1023 own-side view (AC1, AC10)" do
    test "a party as SOURCE reads /context 200 with only its own side, and is listed", ctx do
      %{review: review} = Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.b.tenant_id)

      resp = get_resp(ctx.a, "/#{review.id}/context", @reader, ctx.caller)
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      plan = body["serialised_plan"]

      refute resp.resp_body =~ ctx.b.tenant_id
      assert plan["source_tenant_id"] == ctx.a.tenant_id
      refute Map.has_key?(plan, "target_tenant_id")
      refute Map.has_key?(plan, "target_definition_id")
      assert Map.has_key?(plan, "source_definition_id")
      assert plan["entries"] == []
      assert body["review_id"] == review.id

      assert review.id in list_ids(get_resp(ctx.a, "/", @reader, ctx.caller))
    end

    test "a party as TARGET reads /context 200 with only its own side, and is listed", ctx do
      %{review: review} = Scope.seed_review!(ctx.a, ctx.b.tenant_id, ctx.a.tenant_id)

      resp = get_resp(ctx.a, "/#{review.id}/context", @reader, ctx.caller)
      assert resp.status == 200
      plan = Jason.decode!(resp.resp_body)["serialised_plan"]

      refute resp.resp_body =~ ctx.b.tenant_id
      assert plan["target_tenant_id"] == ctx.a.tenant_id
      refute Map.has_key?(plan, "source_tenant_id")
      refute Map.has_key?(plan, "source_definition_id")
      assert Map.has_key?(plan, "target_definition_id")
      assert plan["entries"] == []

      assert review.id in list_ids(get_resp(ctx.a, "/", @reader, ctx.caller))
    end

    test "a party reads GET /:id 200 (null run when none recorded)", ctx do
      for {src, tgt} <- [{ctx.a.tenant_id, ctx.b.tenant_id}, {ctx.b.tenant_id, ctx.a.tenant_id}] do
        %{review: review} = Scope.seed_review!(ctx.a, src, tgt)
        resp = get_resp(ctx.a, "/#{review.id}", @reader, ctx.caller)
        assert resp.status == 200
        assert Jason.decode!(resp.resp_body) == %{"assertion_run" => nil}
      end
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

  # --- Helpers for the ordered / paged matrix -------------------------------------------------

  # Seeds one review per entry of `spec` (given NEWEST FIRST) in `fixture`'s schema and pins
  # their `inserted_at` so the list order is exactly `spec` order. Entry kinds (relative to the
  # fixture's own tenant, `f1`/`f2` = the other two of a/b/p):
  #   :own        own/own                  (full view)
  #   :hidden     f1 -> f2                 (NON-party: 404 / omitted)
  #   :party_src  own -> f1                (named party as source: own-side view)
  #   :party_tgt  f1 -> own                (named party as target: own-side view)
  #   {:raw, txt} own/own seeded, then the stored plan text overwritten verbatim
  # Returns `[{kind, review}]` in spec order.
  defp seed_ordered!(ctx, fixture, spec) do
    base = DateTime.utc_now() |> DateTime.truncate(:second)
    own = fixture.tenant_id

    [f1, f2] =
      [ctx.a, ctx.b, ctx.p] |> Enum.map(& &1.tenant_id) |> Enum.reject(&(&1 == own))

    spec
    |> Enum.with_index()
    |> Enum.map(fn {kind, idx} ->
      {source, target} =
        case kind do
          :hidden -> {f1, f2}
          :party_src -> {own, f1}
          :party_tgt -> {f1, own}
          _ -> {own, own}
        end

      %{review: review} = Scope.seed_review!(fixture, source, target)
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

  defp visible_ids(rows),
    do: for({k, r} <- rows, k in [:own, :party_src, :party_tgt], do: r.id)

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

  # --- T3 / 1(a): a non-party review that has an assertion run --------------------------------

  describe "1(a) GET /:id of a non-party review that has an assertion run" do
    test "answers the nonexistent baseline and carries no run data (N6b)", ctx do
      %{review: review} = Scope.seed_review!(ctx.a, ctx.b.tenant_id, ctx.p.tenant_id)
      insert_run!(ctx.a, review)

      resp = get_resp(ctx.a, "/#{review.id}", @reader, ctx.caller)
      assert Scope.observable(resp) == baseline(ctx, "")
      refute resp.resp_body =~ "ISS1029-FAILING-ASSERTION"
      refute resp.resp_body =~ "failing_assertion_ids"
      refute resp.resp_body =~ "assertions_failed"
    end
  end

  # --- T7 / AC5: a party keeps the EXISTING 7-key run map -------------------------------------

  describe "T7 a party's GET /:id returns the existing 7-key run map, no new shape" do
    test "(a, b) and (b, a) with a recorded run match the own/own read key for key", ctx do
      %{review: own_review} = Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.a.tenant_id)
      own_run = insert_run!(ctx.a, own_review)

      own_resp = get_resp(ctx.a, "/#{own_review.id}", @reader, ctx.caller)
      assert own_resp.status == 200
      own_map = Jason.decode!(own_resp.resp_body)["assertion_run"]
      assert own_map |> Map.keys() |> Enum.sort() == Enum.sort(@run_keys)
      assert own_map["run_id"] == own_run.id

      for {src, tgt} <- [{ctx.a.tenant_id, ctx.b.tenant_id}, {ctx.b.tenant_id, ctx.a.tenant_id}] do
        %{review: review} = Scope.seed_review!(ctx.a, src, tgt)
        run = insert_run!(ctx.a, review)

        resp = get_resp(ctx.a, "/#{review.id}", @reader, ctx.caller)
        assert resp.status == 200

        map = Jason.decode!(resp.resp_body)["assertion_run"]
        assert map |> Map.keys() |> Enum.sort() == Enum.sort(@run_keys)

        assert map == %{
                 "run_id" => run.id,
                 "status" => "failed",
                 "sandbox_id" => nil,
                 "teardown_error" => nil,
                 "assertions_passed" => 1,
                 "assertions_failed" => 1,
                 "failing_assertion_ids" => ["ISS1029-FAILING-ASSERTION"]
               }
      end
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

  # --- T5 / AC3: the party is decided from stored ids vs the authenticated tenant only --------

  describe "T5 AC3: nothing in the request decides who is a party" do
    @attacks [
      "?tenant_id=TENANT&source_tenant_id=TENANT&target_tenant_id=TENANT",
      "?tenant=TENANT&tenantId=TENANT"
    ]

    test "request params and headers naming the reader's tenant do not open a non-party review",
         ctx do
      %{review: review} = Scope.seed_review!(ctx.a, ctx.b.tenant_id, ctx.p.tenant_id)
      headers = [{"x-tenant-id", ctx.a.tenant_id}, {"x-letflow-tenant", ctx.a.tenant_id}]

      for suffix <- ["", "/context"], attack <- @attacks do
        q = String.replace(attack, "TENANT", ctx.a.tenant_id)
        resp = get_resp(ctx.a, "/#{review.id}#{suffix}#{q}", @reader, ctx.caller, headers)
        assert resp.status == 404, "#{suffix}#{q}"
        assert Scope.observable(resp) == baseline(ctx, suffix, nil, q, headers)
      end

      {ids, _} = list_page(ctx, ctx.a, @reader, "tenant_id=#{ctx.a.tenant_id}&page_size=50")
      refute review.id in ids
    end

    test "request params and headers naming a foreign tenant do not close a party review", ctx do
      %{review: review} = Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.b.tenant_id)
      headers = [{"x-tenant-id", ctx.b.tenant_id}]

      for suffix <- ["", "/context"] do
        plain = get_resp(ctx.a, "/#{review.id}#{suffix}", @reader, ctx.caller)
        assert plain.status == 200

        for attack <- @attacks do
          q = String.replace(attack, "TENANT", ctx.b.tenant_id)
          resp = get_resp(ctx.a, "/#{review.id}#{suffix}#{q}", @reader, ctx.caller, headers)
          assert Scope.observable(resp) == Scope.observable(plain), "#{suffix}#{q}"
        end
      end

      {ids, _} = list_page(ctx, ctx.a, @reader, "tenant_id=#{ctx.b.tenant_id}&page_size=50")
      assert review.id in ids
    end
  end

  # --- T6 / AC4: the list with hidden rows equals the list without them -----------------------

  describe "T6 AC4: the list reveals nothing about omitted rows" do
    test "a cursor-less page with hidden rows is byte-identical to the page without them",
         ctx do
      rows =
        seed_ordered!(ctx, ctx.a, [:hidden, :own, :hidden, :party_src, :hidden, :party_tgt])

      with_hidden = get_resp(ctx.a, "/?page_size=10", @reader, ctx.caller)
      assert list_ids(with_hidden) == visible_ids(rows)

      hidden_ids = ids_of(rows, :hidden)

      {3, _} =
        Repo.delete_all(from(r in PromotionReview, where: r.id in ^hidden_ids),
          prefix: ctx.a.schema_name
        )

      without_hidden = get_resp(ctx.a, "/?page_size=10", @reader, ctx.caller)
      assert Scope.observable(with_hidden) == Scope.observable(without_hidden)

      refute with_hidden.resp_body =~ "total"
    end

    test "a cursor page matches on status, headers and items once hidden rows are deleted",
         ctx do
      rows = seed_ordered!(ctx, ctx.a, [:own, :hidden, :hidden, :party_src, :hidden, :own])

      with_hidden = get_resp(ctx.a, "/?page_size=2", @reader, ctx.caller)
      assert list_ids(with_hidden) == Enum.take(visible_ids(rows), 2)

      hidden_ids = ids_of(rows, :hidden)

      {3, _} =
        Repo.delete_all(from(r in PromotionReview, where: r.id in ^hidden_ids),
          prefix: ctx.a.schema_name
        )

      without_hidden = get_resp(ctx.a, "/?page_size=2", @reader, ctx.caller)

      assert with_hidden.status == without_hidden.status

      assert Enum.reject(with_hidden.resp_headers, &(elem(&1, 0) == "x-request-id")) ==
               Enum.reject(without_hidden.resp_headers, &(elem(&1, 0) == "x-request-id"))

      a = Jason.decode!(with_hidden.resp_body)
      b = Jason.decode!(without_hidden.resp_body)
      assert a["items"] == b["items"]
      assert a |> Map.keys() |> Enum.sort() == b |> Map.keys() |> Enum.sort()
      assert is_binary(a["next_cursor"]) and is_binary(b["next_cursor"])
    end
  end

  # --- T8 / AC6 -------------------------------------------------------------------------------

  describe "T8 AC6: the list shows own and party rows, omits non-parties, no placeholder" do
    test "own, party_src and party_tgt are listed; hidden are not; items keep the 7-key shape",
         ctx do
      rows = seed_ordered!(ctx, ctx.a, [:own, :hidden, :party_src, :hidden, :party_tgt])

      resp = get_resp(ctx.a, "/?page_size=50", @reader, ctx.caller)
      assert list_ids(resp) == visible_ids(rows)
      refute Enum.any?(ids_of(rows, :hidden), &(resp.resp_body =~ &1))

      items = Jason.decode!(resp.resp_body)["items"]
      assert length(items) == 3
      assert Enum.all?(items, &(Map.keys(&1) |> length() == 7))
      refute resp.resp_body =~ ctx.b.tenant_id
      refute resp.resp_body =~ ctx.p.tenant_id
    end
  end

  # --- T10 / AC8: page boundaries -------------------------------------------------------------

  describe "1(c) list paging with hidden rows at page boundaries" do
    for {name, spec} <- [
          {"V H V", [:own, :hidden, :party_src]},
          {"H H V V", [:hidden, :hidden, :party_tgt, :own]},
          {"V H H", [:party_src, :hidden, :hidden]},
          {"H V H V H", [:hidden, :own, :hidden, :party_tgt, :hidden]}
        ],
        page_size <- [1, 2] do
      test "#{name} at page_size #{page_size}: only visible rows, each once, final cursor nil",
           ctx do
        rows = seed_ordered!(ctx, ctx.a, unquote(spec))
        pages = walk(ctx, ctx.a, @reader, unquote(page_size))
        assert_exact_union(pages, visible_ids(rows))

        # no page is short unless it is the last one
        assert pages
               |> Enum.drop(-1)
               |> Enum.all?(fn {ids, _} -> length(ids) == unquote(page_size) end)
      end
    end

    test "a schema whose rows are ALL hidden lists as the empty list with a nil cursor", ctx do
      seed_ordered!(ctx, ctx.a, [:hidden, :hidden, :hidden])
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
        seed_ordered!(ctx, ctx.a, [
          :hidden,
          :own,
          :hidden,
          :hidden,
          :party_src,
          :party_tgt,
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
      seed_ordered!(ctx, ctx.a, [:hidden, :hidden])
      assert [{[], nil}] = walk(ctx, ctx.a, @reader, 1)
    end
  end

  # The hidden runs are far larger than the 100-row minimum scan chunk and than any row budget
  # a capped implementation would plausibly use (a cap of 1000 rows is still killed).
  describe "1(e) a long hidden run never hides or strands a visible row" do
    @tag :long_hidden_run
    test "one visible row behind 1100 newer hidden rows is returned by the first request", ctx do
      rows = seed_ordered!(ctx, ctx.a, List.duplicate(:hidden, 1100) ++ [:party_src])
      assert length(rows) == 1101
      assert [{ids, nil}] = walk(ctx, ctx.a, @reader, 1)
      assert ids == ids_of(rows, :party_src)
    end

    @tag :long_hidden_run
    test "a visible row in the middle of two 250-row hidden runs", ctx do
      spec = List.duplicate(:hidden, 250) ++ [:own] ++ List.duplicate(:hidden, 250)
      rows = seed_ordered!(ctx, ctx.a, spec)
      assert [{ids, nil}] = walk(ctx, ctx.a, @reader, 1)
      assert ids == ids_of(rows, :own)
    end
  end

  # --- T9 / AC7: unreadable stored ids ---------------------------------------------------------

  describe "1(f)/T9 malformed and legacy stored plans (AC7)" do
    @malformed [
      {"JSON string", ~s("x"), "x"},
      {"JSON array", "[1]", [1]},
      {"JSON number", "7", 7},
      {"JSON null", "null", nil},
      {"truncated JSON", ~s({"a":), nil},
      {"not JSON at all", "x", nil},
      {"empty text", "", nil},
      {"map missing the ids", ~s({"entries":[]}), %{"entries" => []}},
      {"non-string ids", ~s({"source_tenant_id":7,"target_tenant_id":[1]}),
       %{"source_tenant_id" => 7, "target_tenant_id" => [1]}}
    ]

    test "non-operator list answers 200, shows only readable rows, pages consistently", ctx do
      spec =
        Enum.flat_map(@malformed, fn {_n, text, _op} -> [:own, {:raw, text}] end) ++
          [:party_src]

      rows = seed_ordered!(ctx, ctx.a, spec)
      expected = for {k, r} <- rows, k in [:own, :party_src], do: r.id

      for page_size <- [1, 3] do
        assert_exact_union(walk(ctx, ctx.a, @reader, page_size), expected)
      end
    end

    test "non-operator per-review routes answer the nonexistent 404 bytes for every text",
         ctx do
      rows = seed_ordered!(ctx, ctx.a, Enum.map(@malformed, fn {_n, t, _} -> {:raw, t} end))

      for {{_kind, review}, {name, _text, _op}} <- Enum.zip(rows, @malformed),
          suffix <- ["", "/context"] do
        # {:raw, _} rows were seeded own/own then overwritten: only the stored text matters
        resp = get_resp(ctx.a, "/#{review.id}#{suffix}", @reader, ctx.caller)

        assert resp.status == 404, "#{name}#{suffix}"
        assert Scope.observable(resp) == baseline(ctx, suffix), "#{name}#{suffix}"
      end
    end

    test "the operator list is unfiltered and includes the malformed rows", ctx do
      spec = [:own | Enum.map(@malformed, fn {_n, text, _op} -> {:raw, text} end)]
      rows = seed_ordered!(ctx, ctx.p, spec)

      listed = ctx |> walk(ctx.p, @operator, 50) |> Enum.flat_map(&elem(&1, 0))
      assert listed == Enum.map(rows, fn {_k, r} -> r.id end)
    end

    test "the operator reads /:id and /:id/context of unparseable rows: 200, never a 500", ctx do
      rows = seed_ordered!(ctx, ctx.p, Enum.map(@malformed, fn {_n, t, _} -> {:raw, t} end))

      for {{_kind, review}, {name, _text, expected_plan}} <- Enum.zip(rows, @malformed) do
        run = get_resp(ctx.p, "/#{review.id}", @operator, ctx.caller)
        assert run.status == 200, "#{name} /:id"

        resp = get_resp(ctx.p, "/#{review.id}/context", @operator, ctx.caller)
        assert resp.status == 200, "#{name} /context: #{resp.resp_body}"
        body = Jason.decode!(resp.resp_body)
        assert body |> Map.keys() |> length() == 9
        assert body["review_id"] == review.id
        assert body["serialised_plan"] == expected_plan, name
      end
    end
  end

  describe "1(g) list filters compose with the visibility filter" do
    test "status and def_id filters return only visible rows of that status/def", ctx do
      rows = seed_ordered!(ctx, ctx.a, [:hidden, :own, :hidden, :party_tgt])
      [{:own, first_own} | _] = Enum.filter(rows, &match?({:own, _}, &1))

      {ids, nil} = list_page(ctx, ctx.a, @reader, "status=pending_review&page_size=10")
      assert ids == visible_ids(rows)

      {ids, nil} = list_page(ctx, ctx.a, @reader, "status=approved&page_size=10")
      assert ids == []

      {ids, nil} = list_page(ctx, ctx.a, @reader, "def_id=#{first_own.def_id}&page_size=10")
      assert ids == [first_own.id]
    end
  end

  # --- T4 / AC2: the operator ----------------------------------------------------------------

  describe "1(h) operator list" do
    test "includes the non-party and party reviews with an unchanged cursor shape", ctx do
      rows = seed_ordered!(ctx, ctx.p, [:hidden, :own, :party_src])
      pages = walk(ctx, ctx.p, @operator, 2)
      assert Enum.flat_map(pages, &elem(&1, 0)) == Enum.map(rows, fn {_k, r} -> r.id end)
      assert [{[_, _], cursor}, {[_], nil}] = pages
      assert is_binary(cursor)
    end
  end

  # --- 1(i) / T3 / T4: TENANT_ADMIN of the platform tenant -------------------------------------

  describe "1(i) AC2: TENANT_ADMIN of the platform tenant" do
    for pin <- [:pinned, :unpinned] do
      test "reads an operator-seeded non-party review (a, b) as 404 (#{pin})", ctx do
        if unquote(pin) == :unpinned, do: Fixture.unpin!()

        %{review: foreign} = Scope.seed_review!(ctx.p, ctx.a.tenant_id, ctx.b.tenant_id)
        %{review: own} = Scope.seed_review!(ctx.p, ctx.p.tenant_id, ctx.p.tenant_id)
        %{review: party} = Scope.seed_review!(ctx.p, ctx.p.tenant_id, ctx.b.tenant_id)

        for suffix <- ["", "/context"] do
          resp = get_resp(ctx.p, "/#{foreign.id}#{suffix}", @reader, ctx.caller)
          assert Scope.observable(resp) == baseline(ctx, suffix, ctx.p)
        end

        # the platform tenant's own party review (p, b) is still the own-side view
        assert get_resp(ctx.p, "/#{party.id}/context", @reader, ctx.caller).status == 200

        {ids, _} = list_page(ctx, ctx.p, @reader, "page_size=10")
        refute foreign.id in ids
        assert own.id in ids
        assert party.id in ids
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
