defmodule Letflow.Routers.GH2747CursorTailHttpTest do
  @moduledoc """
  GH #2747: a keyset cursor with a VALID prefix and mint slot but a malformed tail must be
  refused with the endpoint's own client error, never a 500. Spec: `test/specs/GH-2747.md`.

  Real HTTP through `Letflow.Router` (bearer token + `x-tenant-slug`) against real Postgres,
  no mocks. `users` and `tenants` in particular must go through the full router: their
  handlers used to match `{:ok, _} = Identity.list_*` bare, so the new error tuple would
  have surfaced as a `MatchError` 500 only on that path.

  Every endpoint in `@endpoints` is described by its cursor prefix and slot layout (the
  first slot is always the mint time `decode_cursor/4` reads for expiry). For each slot the
  test forges a cursor that is valid everywhere except that slot, plus every truncation and
  an over-long tail, and asserts the response status is the endpoint's own cursor error
  status and its body is byte-identical to the one an undecodable cursor already gets
  (`@control_cursor`). A bad MINT slot is refused before the seek decoder runs, so for those
  forgeries only "a 4xx, never a 5xx" is asserted.

  The trace id is pinned so bodies compare byte for byte. Failure messages carry only a label
  and a status, never a response body. `async: false` (VM-global platform-tenant pin).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  import Letflow.TestSupport.CursorForgery,
    only: [forge: 2, forgeries: 2, good: 1, now_us: 0, valid: 2]

  alias Letflow.Api.Pagination
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TestSupport.InstanceFixture

  @fixed_trace "00000000-0000-4000-8000-0000000000dd"
  @control_cursor "!!!not-base64!!!"

  # name, who calls (:a = TENANT_ADMIN of an ordinary tenant, :p = PLATFORM_ADMIN of the
  # platform tenant), cursor prefix, slot layout, the endpoint's own cursor-error status.
  @endpoints [
    {:users, :a, "U:", [:mint, :dt, :uuid], 400},
    {:tenants, :p, "T:", [:mint, :dt, :uuid], 400},
    {:group_members, :a, "G:", [:mint, :dt, :uuid], 400},
    {:audit, :a, "A:", [:mint, :dt, :uuid], 400},
    {:platform_events, :a, "PE:", [:mint, :int, :uuid], 400},
    {:instances_list, :a, "IL:", [:mint_dt, :uuid], 422},
    {:instances_history, :a, "IH:", [:mint, :int], 422},
    {:instances_timeline, :a, "IT:", [:mint, :int], 422},
    {:instance_attachments, :a, "IA:", [:mint_dt, :uuid], 422},
    {:dlq, :a, "D:", [:mint_dt, :uuid], 400},
    {:tasks, :a, "T:", [:mint_dt, :uuid], 422},
    {:service_catalog_list, :a, "SC:", [:mint_dt, :string], 400},
    {:service_catalog_list_all, :p, "SCA:", [:mint_dt, :string], 400},
    {:definitions_list, :a, "DL:", [:mint, :uuid, :dt], 400},
    {:definitions_search, :a, "DS:", [:mint, :rank_id, :dt], 400},
    {:promotion_reviews, :a, "PR:", [:mint, :uuid, :dt], 400},
    {:entities_definitions, :a, "ED:", [:mint, :uuid, :dt], 400}
  ]

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp ctx!(:a, needs_instance?) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2747-a")
    ctx = %{slug: tenant.tenant.slug, token: mint!(tenant, ["TENANT_ADMIN"]), tenant: tenant}

    if needs_instance?,
      do: Map.put(ctx, :instance_id, InstanceFixture.real_instance!(tenant)),
      else: ctx
  end

  defp ctx!(:p, _needs_instance?) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2747-p")
    Fixture.pin!(tenant.tenant_id)
    %{slug: tenant.tenant.slug, token: mint!(tenant, ["PLATFORM_ADMIN"]), tenant: tenant}
  end

  defp mint!(tenant, roles), do: Fixture.mint_token!(tenant, roles)

  defp get(ctx, path, query) do
    path = if query == %{}, do: path, else: path <> "?" <> URI.encode_query(query)

    conn(:get, path)
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", @fixed_trace)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  # The route + fixed query each endpoint is hit with; the cursor is added on top.
  defp route(:users, _ctx), do: {"/api/v1/identity/users", %{}}
  defp route(:tenants, _ctx), do: {"/api/v1/tenants", %{}}
  defp route(:audit, _ctx), do: {"/api/v1/audit", %{}}
  defp route(:platform_events, _ctx), do: {"/api/v1/promotions/platform-events", %{}}
  defp route(:instances_list, _ctx), do: {"/api/v1/instances", %{}}
  defp route(:instances_history, ctx), do: {"/api/v1/instances/#{ctx.instance_id}/history", %{}}
  defp route(:instances_timeline, ctx), do: {"/api/v1/instances/#{ctx.instance_id}/timeline", %{}}

  defp route(:instance_attachments, ctx),
    do: {"/api/v1/instances/#{ctx.instance_id}/attachments", %{}}

  defp route(:dlq, _ctx), do: {"/api/v1/dlq", %{}}
  defp route(:tasks, _ctx), do: {"/api/v1/tasks", %{}}
  defp route(:service_catalog_list, _ctx), do: {"/api/v1/services", %{}}
  defp route(:service_catalog_list_all, _ctx), do: {"/api/v1/admin/services", %{}}
  defp route(:definitions_list, _ctx), do: {"/api/v1/definitions", %{}}
  defp route(:definitions_search, _ctx), do: {"/api/v1/definitions/search", %{"q" => "gh2747"}}
  defp route(:promotion_reviews, _ctx), do: {"/api/v1/promotions", %{}}
  defp route(:entities_definitions, _ctx), do: {"/api/v1/entities/definitions", %{}}
  defp route(:group_members, ctx), do: {"/api/v1/identity/groups/#{ctx.group_id}/members", %{}}

  defp needs_instance?(name),
    do: name in [:instances_history, :instances_timeline, :instance_attachments]

  # ── The table-driven refusal test ──────────────────────────────────────────

  for {name, who, prefix, layout, status} <- @endpoints do
    @tag endpoint: name
    test "#{name}: valid prefix + mint with a malformed tail is refused with #{status}, not 500" do
      name = unquote(name)
      prefix = unquote(prefix)
      layout = unquote(layout)
      expected_status = unquote(status)

      ctx = ctx!(unquote(who), needs_instance?(name))
      ctx = maybe_with_group(ctx, name)
      {path, fixed} = route(name, ctx)

      control = get(ctx, path, Map.put(fixed, "cursor", @control_cursor))
      assert {name, :control, control.status} == {name, :control, expected_status}

      # Positive control: the same forging with every slot valid is accepted, so each
      # refusal below is down to the one mangled slot and nothing else.
      valid = get(ctx, path, Map.put(fixed, "cursor", valid(prefix, layout)))
      assert {name, :valid_cursor, valid.status} == {name, :valid_cursor, 200}

      for {label, cursor, bad_mint?} <- forgeries(prefix, layout) do
        resp = get(ctx, path, Map.put(fixed, "cursor", cursor))

        if bad_mint? do
          assert {label, resp.status in 400..499} == {label, true}
        else
          assert {label, resp.status} == {label, expected_status}
          assert {label, resp.resp_body == control.resp_body} == {label, true}
        end
      end
    end
  end

  # ── group-members: existence is checked before the cursor ──────────────────

  defp maybe_with_group(ctx, :group_members), do: with_group(ctx)
  defp maybe_with_group(ctx, _name), do: ctx

  defp with_group(ctx) do
    {:ok, group} =
      Identity.create_group(%{"name" => "gh2747-g-#{System.unique_integer([:positive])}"},
        prefix: ctx.tenant.schema_name
      )

    Map.put(ctx, :group_id, group.id)
  end

  describe "group-members: unknown / other-tenant groups never reveal a cursor verdict" do
    test "a never-existed group and another tenant's group answer the same 404 whatever the cursor" do
      ctx = ctx!(:a, false)
      other = TenantFixture.provisioned_tenant!(slug_prefix: "gh2747-b")

      {:ok, foreign} =
        Identity.create_group(%{"name" => "gh2747-foreign"}, prefix: other.schema_name)

      never = Ecto.UUID.generate()
      mangled = forge("G:", [now_us(), "abc", Ecto.UUID.generate()])
      truncated = forge("G:", [now_us()])

      for group_id <- [never, foreign.id] do
        path = "/api/v1/identity/groups/#{group_id}/members"
        baseline = get(ctx, path, %{})

        assert {group_id == never, baseline.status} == {group_id == never, 404}

        for {label, cursor} <- [mangled: mangled, truncated: truncated] do
          resp = get(ctx, path, %{"cursor" => cursor})
          assert {label, resp.status} == {label, 404}
          assert {label, resp.resp_body == baseline.resp_body} == {label, true}
        end
      end
    end

    test "an existing group answers 400 invalid cursor for the same mangled cursor" do
      ctx = ctx!(:a, false) |> with_group()
      path = "/api/v1/identity/groups/#{ctx.group_id}/members"
      resp = get(ctx, path, %{"cursor" => forge("G:", [now_us(), "abc", Ecto.UUID.generate()])})

      assert resp.status == 400
      assert resp.resp_body =~ "invalid cursor"
    end
  end

  # ── The 400 body names the cause on the endpoints that say so ──────────────

  describe "the 400 body" do
    test "users: a mangled tail answers 400 with the 'invalid cursor' detail" do
      ctx = ctx!(:a, false)

      resp =
        get(ctx, "/api/v1/identity/users", %{"cursor" => forge("U:", [now_us(), "abc", "x"])})

      assert resp.status == 400
      assert resp.resp_body =~ "invalid cursor"
    end

    test "tenants: a mangled tail answers 400 with the 'invalid cursor' detail" do
      ctx = ctx!(:p, false)
      resp = get(ctx, "/api/v1/tenants", %{"cursor" => forge("T:", [now_us()])})

      assert resp.status == 400
      assert resp.resp_body =~ "invalid cursor"
    end

    test "platform events: a sequence above int64 and one below int64 min answer 400 invalid cursor" do
      ctx = ctx!(:a, false)
      uuid = Ecto.UUID.generate()

      for seq <- ["9223372036854775808", "-9223372036854775809"] do
        resp =
          get(ctx, "/api/v1/promotions/platform-events", %{
            "cursor" => forge("PE:", [now_us(), seq, uuid])
          })

        assert {seq, resp.status} == {seq, 400}
        assert resp.resp_body =~ "invalid cursor"
      end
    end

    test "audit: a timestamp DateTime cannot represent answers 400 invalid cursor" do
      ctx = ctx!(:a, false)

      resp =
        get(ctx, "/api/v1/audit", %{
          "cursor" => forge("A:", [now_us(), "9223372036854775807", Ecto.UUID.generate()])
        })

      assert resp.status == 400
      assert resp.resp_body =~ "invalid cursor"
    end

    test "service catalog: a service_id with NUL or invalid UTF-8 answers 400 invalid cursor" do
      ctx = ctx!(:a, false)
      platform = ctx!(:p, false)

      for bad <- ["svc" <> <<0>>, <<255>>, ""] do
        resp = get(ctx, "/api/v1/services", %{"cursor" => forge("SC:", [now_us(), bad])})
        assert {:list, bad, resp.status} == {:list, bad, 400}
        assert resp.resp_body =~ "invalid cursor"

        resp =
          get(platform, "/api/v1/admin/services", %{"cursor" => forge("SCA:", [now_us(), bad])})

        assert {:list_all, bad, resp.status} == {:list_all, bad, 400}
        assert resp.resp_body =~ "invalid cursor"
      end
    end

    test "definitions search: rank 0, rank 4, a non-numeric rank and a non-UUID id answer 400" do
      ctx = ctx!(:a, false)
      uuid = Ecto.UUID.generate()

      for rank_id <- ["0|#{uuid}", "4|#{uuid}", "abc|#{uuid}", "2|not-a-uuid", "2"] do
        resp =
          get(ctx, "/api/v1/definitions/search", %{
            "q" => "gh2747",
            "cursor" => forge("DS:", [now_us(), rank_id, good(:dt)])
          })

        assert {rank_id, resp.status} == {rank_id, 400}
        assert resp.resp_body =~ "invalid cursor"
      end
    end

    test "instances history/timeline: a seq cursor with no tail colon and a non-numeric tail answer 422" do
      ctx = ctx!(:a, true)

      for {route, prefix} <- [{"history", "IH:"}, {"timeline", "IT:"}],
          cursor <- [
            Pagination.encode_cursor(prefix <> now_us()),
            Pagination.encode_cursor(prefix <> "abc")
          ] do
        resp = get(ctx, "/api/v1/instances/#{ctx.instance_id}/#{route}", %{"cursor" => cursor})
        assert {route, resp.status} == {route, 422}
        assert resp.resp_body =~ "cursor is not valid for this endpoint"
      end
    end
  end

  # ── Valid-cursor round trips: the real next_cursor fed back ────────────────

  defp items(resp), do: Jason.decode!(resp.resp_body)["items"]
  defp next(resp), do: Jason.decode!(resp.resp_body)["next_cursor"]

  # Follows next_cursor from a first page of size 1 to the end (bounded), returning the ids.
  defp walk(ctx, path, fixed, extract), do: do_walk(ctx, path, fixed, extract, nil, [], 12)

  defp do_walk(_ctx, _path, _fixed, _extract, _cursor, acc, 0),
    do: flunk("walk did not terminate: #{inspect(acc)}")

  defp do_walk(ctx, path, fixed, extract, cursor, acc, left) do
    query = Map.put(fixed, "page_size", "1")
    query = if cursor, do: Map.put(query, "cursor", cursor), else: query
    resp = get(ctx, path, query)
    assert {path, resp.status} == {path, 200}
    acc = acc ++ Enum.map(items(resp), extract)

    case next(resp) do
      nil -> acc
      c -> do_walk(ctx, path, fixed, extract, c, acc, left - 1)
    end
  end

  defp insert_user!(tenant, inserted_at) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2747-#{Ecto.UUID.generate()}",
      display_name: "GH2747 user",
      email: "gh2747-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal,
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  describe "round trips with the real next_cursor" do
    test "users: three rows with an IDENTICAL inserted_at are each visited exactly once" do
      ctx = ctx!(:a, false)
      same = ~N[2020-01-01 00:00:00]
      ids = for _ <- 1..3, do: insert_user!(ctx.tenant, same).id

      walked = walk(ctx, "/api/v1/identity/users", %{}, & &1["id"])

      assert Enum.sort(Enum.filter(walked, &(&1 in ids))) == Enum.sort(ids)
      assert length(Enum.uniq(walked)) == length(walked)
      # the tie is broken by id ascending, so the three tied rows come out in id order
      assert Enum.filter(walked, &(&1 in ids)) == Enum.sort(ids)
    end

    test "users: an upper-case UUID in the cursor pages exactly like the lower-case one" do
      ctx = ctx!(:a, false)
      same = ~N[2020-01-01 00:00:00]
      for _ <- 1..3, do: insert_user!(ctx.tenant, same)

      first = get(ctx, "/api/v1/identity/users", %{"page_size" => "1"})
      cursor = next(first)
      assert is_binary(cursor)

      {:ok, raw} = Base.url_decode64(cursor, padding: false)
      [prefix, mint, ts, uuid] = String.split(raw, ":", parts: 4)
      assert prefix == "U"
      upper = Pagination.encode_cursor(Enum.join([prefix, mint, ts, String.upcase(uuid)], ":"))
      assert upper != cursor

      lower_page = get(ctx, "/api/v1/identity/users", %{"page_size" => "2", "cursor" => cursor})
      upper_page = get(ctx, "/api/v1/identity/users", %{"page_size" => "2", "cursor" => upper})

      assert lower_page.status == 200
      assert upper_page.status == 200
      assert Enum.map(items(upper_page), & &1["id"]) == Enum.map(items(lower_page), & &1["id"])
    end

    test "tenants: page 2 from the real cursor answers 200 and does not repeat page 1" do
      ctx = ctx!(:p, false)
      _extra = TenantFixture.provisioned_tenant!(slug_prefix: "gh2747-t")

      first = get(ctx, "/api/v1/tenants", %{"page_size" => "1"})
      assert first.status == 200
      cursor = next(first)
      assert is_binary(cursor)

      second = get(ctx, "/api/v1/tenants", %{"page_size" => "1", "cursor" => cursor})
      assert second.status == 200
      assert [%{"slug" => s2}] = items(second)
      assert [%{"slug" => s1}] = items(first)
      assert s1 != s2
    end

    test "instances list: microsecond-apart rows are each visited exactly once, newest first" do
      ctx = ctx!(:a, false)
      expected = for _ <- 1..3, do: InstanceFixture.real_instance!(ctx.tenant)

      walked = walk(ctx, "/api/v1/instances", %{}, & &1["instance_id"])

      # newest first: the reverse of creation order, each visited exactly once
      assert walked == Enum.reverse(expected)
    end

    test "definitions search: paging crosses the exact / partial-name / description rank tiers" do
      ctx = ctx!(:a, false)
      schema = ctx.tenant.schema_name

      make = fn name, description ->
        {:ok, definition} =
          Letflow.Definitions.create(
            %{
              name: name,
              version: "1.0.0",
              description: description,
              graph: search_graph(),
              created_by: Ecto.UUID.generate()
            },
            prefix: schema
          )

        {:ok, _} = Letflow.Definitions.activate(definition.id, prefix: schema)
        definition.id
      end

      exact = make.("gh2747", nil)
      partial = make.("gh2747-extended", nil)
      described = make.("unrelated-name", "mentions gh2747 in passing")

      walked =
        walk(ctx, "/api/v1/definitions/search", %{"q" => "gh2747"}, & &1["definition"]["id"])

      assert walked == [exact, partial, described]
    end
  end

  defp search_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end
end
