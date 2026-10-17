defmodule Letflow.Routers.EntitiesDefinitionsListTypeAccessTest do
  @moduledoc """
  GH #2739 -- HTTP-level tests that `GET /entities/definitions` honours per-type
  authorization (`Letflow.Entities.TypeAccess`, REQ-394): a caller denied a type
  gets no definition of it on the list, pages and `next_cursor` are computed over
  visible rows only, and a denied type is indistinguishable from an absent one
  (INV-2, INV-5).

  Spec: `test/specs/GH2739-definitions-list-type-access.md`. Design:
  `lib/letflow/design/gh2739-definitions-list-type-access.md`. Context-level
  tests (cursors, statement count, tenant-prefix gate, parity, `/2` removal) are in
  `test/letflow/entities/definitions_list_type_access_test.exs`.

  Determinism (design section 10): every fixture row has a fixed uuid and a fixed
  distinct `inserted_at` (`Letflow.TestSupport.DefinitionsListFixture`). The "world
  with X" and the "world without X" are two real tenants seeded from the same row
  table minus the `x_ent` versions. `next_cursor` embeds its mint time, so where it
  is non-null the tests compare its DECODED last-row position and null-ness; raw
  response bytes are compared only on pages whose `next_cursor` is null. The only
  textual masking is the world-specific `artifact_version_id` (a fresh uuid per
  tenant) in the body, and the volatile headers `date` and `x-request-id`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Identity
  alias Letflow.TenantFixture
  alias Letflow.TestSupport.DefinitionsListFixture, as: Fx

  @denied Fx.denied_name()
  @volatile_headers ["date", "x-request-id"]
  @page_sizes [1, 2, 3, 4, 5, 6, 7, 200]
  @denied_keys [:x0, :x1, :x2, :x3]

  # -- request plumbing -------------------------------------------------------

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp get(ctx, path) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", "gh2739-pinned-trace")
    |> dispatch()
  end

  defp list_path(params) do
    query = URI.encode_query(params)

    if query == "",
      do: "/api/v1/entities/definitions",
      else: "/api/v1/entities/definitions?" <> query
  end

  defp list(ctx, params), do: get(ctx, list_path(params))

  # status, volatile-masked headers, body with the world-specific artifact_version_id
  # masked, decoded items without it, and the raw next_cursor
  defp norm(conn, ctx) do
    decoded = Jason.decode!(conn.resp_body)

    %{
      status: conn.status,
      headers:
        conn.resp_headers
        |> Enum.reject(fn {name, _} -> name in @volatile_headers end)
        |> Enum.sort(),
      body: String.replace(conn.resp_body, ctx.artifact_version_id, "<artifact_version_id>"),
      items: for(item <- decoded["items"] || [], do: Map.delete(item, "artifact_version_id")),
      next: decoded["next_cursor"],
      keys: decoded |> Map.keys() |> Enum.sort()
    }
  end

  # Same status, same headers (minus volatile), same items, `next_cursor` equal by
  # null-ness and decoded position, and raw bytes equal where `next_cursor` is null.
  defp assert_same!(label, a, b) do
    assert {label, a.status} == {label, b.status}
    assert {label, a.headers} == {label, b.headers}
    assert {label, a.items} == {label, b.items}
    assert {label, is_nil(a.next)} == {label, is_nil(b.next)}
    assert {label, Fx.cursor_position(a.next)} == {label, Fx.cursor_position(b.next)}
    if is_nil(a.next), do: assert({label, a.body} == {label, b.body})
    :ok
  end

  # Follows next_cursor from the first page; returns the normalised responses.
  defp walk(ctx, page_size), do: walk(ctx, page_size, nil, [])

  defp walk(ctx, page_size, cursor, acc) do
    params = if cursor, do: [page_size: page_size, cursor: cursor], else: [page_size: page_size]
    conn = list(ctx, params)
    assert conn.status == 200, "page_size #{page_size}: status #{conn.status}"
    page = norm(conn, ctx)
    acc = [page | acc]
    assert length(acc) <= 20, "pagination did not terminate"

    if page.next, do: walk(ctx, page_size, page.next, acc), else: Enum.reverse(acc)
  end

  defp item_ids(page), do: Enum.map(page.items, & &1["id"])

  # -- fixtures -----------------------------------------------------------------

  defp token_ctx(tenant_info, schema_name, user, roles) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: schema_name)

    Map.merge(tenant_info, %{plaintext: plaintext, user_id: user.id, roles: roles})
  end

  # A provisioned tenant plus a TENANT_ADMIN caller. `world` is :with_x, :without_x or :empty.
  defp world!(world) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "gh2739",
        display_name: "GH2739 Definitions List Test Tenant"
      )

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    artifact_version_id =
      case world do
        :empty -> "00000000-0000-4000-8000-00000000dead"
        seeded -> Fx.seed!(tenant.schema_name, tenant.tenant_id, seeded)
      end

    info = %{
      tenant_id: tenant.tenant_id,
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      artifact_version_id: artifact_version_id
    }

    token_ctx(info, tenant.schema_name, Fx.insert_user!(tenant.schema_name), ["TENANT_ADMIN"])
  end

  # a second caller (own user and token) in the same tenant
  defp another_caller(ctx) do
    info = Map.take(ctx, [:tenant_id, :schema_name, :slug, :artifact_version_id])
    token_ctx(info, ctx.schema_name, Fx.insert_user!(ctx.schema_name), ["TENANT_ADMIN"])
  end

  # the denied world (X restricted, caller holds no grant) and the world without X
  defp denied_world! do
    denied = world!(:with_x)
    :ok = Fx.restrict!(denied.schema_name, @denied)
    denied
  end

  defp denied_and_absent_worlds!, do: {denied_world!(), world!(:without_x)}

  # -- T-1 (red on main) ------------------------------------------------------------

  describe "T-1 -- a denied type is absent from the list" do
    test "no x_ent item, no x_ent id and no x_ent name anywhere in the body, for page sizes that would include it" do
      denied = denied_world!()

      for page_size <- @page_sizes do
        conn = list(denied, page_size: page_size)
        assert conn.status == 200
        page = norm(conn, denied)

        refute Enum.any?(page.items, &(&1["name"] == @denied)), "page_size #{page_size}"

        for key <- @denied_keys do
          refute conn.resp_body =~ Fx.id(key), "page_size #{page_size}: #{key} id in body"
        end

        refute conn.resp_body =~ @denied, "page_size #{page_size}: type name in body"
      end

      # non-vacuous: the same tenant lists the type for a caller holding the grant
      granted = another_caller(denied)
      :ok = Fx.grant!(denied.schema_name, granted.user_id, @denied)
      granted_page = norm(list(granted, page_size: 200), granted)
      assert item_ids(granted_page) == Fx.ids(:with_x)
    end
  end

  # -- T-2 (red on main) --------------------------------------------------------------

  describe "T-2 -- pagination equals the world in which the type does not exist" do
    test "page lists and next_cursor presence/position are identical for every page size" do
      {denied, absent} = denied_and_absent_worlds!()

      for page_size <- @page_sizes do
        in_denied = walk(denied, page_size)
        in_absent = walk(absent, page_size)

        summarize = fn pages ->
          for page <- pages do
            %{
              ids: item_ids(page),
              names: Enum.map(page.items, & &1["name"]),
              next_null?: is_nil(page.next),
              next_position: Fx.cursor_position(page.next)
            }
          end
        end

        assert {page_size, summarize.(in_denied)} == {page_size, summarize.(in_absent)}

        # the cursor of every non-final page names that page's LAST VISIBLE row
        for page <- in_denied, page.next != nil do
          last = List.last(page.items)
          {id, inserted_at_us} = Fx.cursor_position(page.next)
          assert id == last["id"]

          assert inserted_at_us ==
                   last["inserted_at"]
                   |> DateTime.from_iso8601()
                   |> elem(1)
                   |> DateTime.to_unix(:microsecond)
        end
      end
    end

    test "visible order is b1 a3 a2 a1; a page of 4 holds them all and next_cursor is nil (trailing denied tail); a page ending exactly on a denied row still holds only visible rows" do
      denied = denied_world!()
      visible = [Fx.id(:b1), Fx.id(:a3), Fx.id(:a2), Fx.id(:a1)]

      # raw order x3 b1 a3 x2 a2 x1 a1 x0: only x0 follows a1, and it is denied
      [only] = walk(denied, 4)
      assert item_ids(only) == visible
      assert only.next == nil

      # page sizes 3 and 4 over raw order x3 b1 a3 x2 a2 x1 a1 x0: a post-filter would read a raw
      # page ending exactly on a denied row (x2 for 4) and return a short page or a cursor naming x2
      [first, second] = walk(denied, 3)
      assert item_ids(first) == [Fx.id(:b1), Fx.id(:a3), Fx.id(:a2)]
      assert Fx.cursor_position(first.next) == {Fx.id(:a2), dt_us(:a2)}
      assert item_ids(second) == [Fx.id(:a1)]
      assert second.next == nil

      pages = walk(denied, 1)
      assert Enum.map(pages, &item_ids/1) == Enum.map(visible, &[&1])
      assert Enum.map(pages, &is_nil(&1.next)) == [false, false, false, true]

      assert [one] = walk(denied, 200)
      assert item_ids(one) == visible
      assert one.next == nil
    end
  end

  # -- T-3 ---------------------------------------------------------------------------------

  describe "T-3 -- envelope" do
    test "the top-level key set is exactly items and next_cursor, no count or total" do
      denied = denied_world!()

      for page_size <- [1, 200] do
        assert norm(list(denied, page_size: page_size), denied).keys == ["items", "next_cursor"]
      end
    end
  end

  # -- T-6 ------------------------------------------------------------------------------

  describe "T-6 -- cursor error statuses do not depend on type visibility" do
    test "wrong-endpoint, expired and garbage cursors answer the same in the denied and absent worlds" do
      {denied, absent} = denied_and_absent_worlds!()

      expired =
        "ED:"
        |> Letflow.Api.Pagination.build_raw_cursor_timestamp_key(1, Fx.id(:a1), 1)
        |> Letflow.Api.Pagination.encode_cursor()

      wrong_endpoint =
        "RV:"
        |> Letflow.Api.Pagination.build_raw_cursor_timestamp_key(
          System.system_time(:microsecond),
          Fx.id(:a1),
          1
        )
        |> Letflow.Api.Pagination.encode_cursor()

      for {label, cursor, status} <- [
            {:expired, expired, 410},
            {:wrong_endpoint, wrong_endpoint, 400},
            {:garbage, "!!!not-base64!!!", 400}
          ] do
        in_denied = norm(list(denied, cursor: cursor), denied)
        in_absent = norm(list(absent, cursor: cursor), absent)
        assert {label, in_denied.status} == {label, status}
        assert_same!(label, in_denied, in_absent)
      end
    end
  end

  # -- T-7 ---------------------------------------------------------------------------------

  describe "T-7 -- no behaviour change for callers without a denied type" do
    test "an unrestricted tenant and a granted user see the full golden list; the denied user sees it minus x_ent" do
      world = world!(:with_x)
      all_keys = Fx.keys(:with_x)
      golden = fn keys -> Enum.map(keys, &Fx.golden_item/1) end

      # unrestricted tenant: everything, newest first, exact item shape
      unrestricted = norm(list(world, page_size: 200), world)
      assert unrestricted.items == golden.(all_keys)
      assert unrestricted.next == nil

      # first page of a smaller size keeps its cursor position
      first = norm(list(world, page_size: 3), world)
      assert first.items == golden.([:x3, :b1, :a3])
      assert Fx.cursor_position(first.next) == {Fx.id(:a3), dt_us(:a3)}

      # restrict x_ent: the granted user is unchanged, the other caller loses it
      denied_caller = another_caller(world)
      granted_caller = another_caller(world)
      :ok = Fx.restrict!(world.schema_name, @denied)
      :ok = Fx.grant!(world.schema_name, granted_caller.user_id, @denied)

      granted = norm(list(granted_caller, page_size: 200), granted_caller)
      assert granted.items == golden.(all_keys)
      assert granted.next == nil
      assert_same!(:granted_vs_unrestricted, granted, unrestricted)

      visible = norm(list(denied_caller, page_size: 200), denied_caller)
      assert visible.items == golden.([:b1, :a3, :a2, :a1])
    end
  end

  # -- T-8 ---------------------------------------------------------------------------------

  describe "T-8 -- name / entity_type / status parameters are ignored" do
    test "a request with them equals the same request without them, and never confirms the denied name" do
      denied = denied_world!()

      for {page_size, extra} <- [
            {200, [name: @denied]},
            {200, [entity_type: @denied]},
            {200, [status: "active"]},
            {2, [name: @denied, entity_type: @denied, status: "inactive"]}
          ] do
        plain = norm(list(denied, page_size: page_size), denied)
        filtered = norm(list(denied, [page_size: page_size] ++ extra), denied)
        assert_same!({page_size, extra}, filtered, plain)
        refute Enum.any?(filtered.items, &(&1["name"] == @denied))
      end
    end
  end

  # -- T-10 --------------------------------------------------------------------------------

  describe "T-10 -- the three single-definition GETs are unchanged" do
    test "a denied definition answers exactly like an absent one, a granted user gets 200" do
      world = world!(:empty)

      definition = %{
        name: "k_ent",
        display_name: "K",
        fields: [
          %{name: "email", type: :string, required: true, queried: true},
          %{name: "age", type: :integer}
        ]
      }

      {:ok, created} =
        Definitions.create_definition(
          %{definition: definition, created_by: world.user_id},
          world.schema_name
        )

      {:ok, _} =
        Definitions.activate_definition(
          "k_ent",
          world.user_id,
          "gh2739 go-live",
          world.schema_name
        )

      denied_caller = another_caller(world)
      granted_caller = another_caller(world)
      absent_id = "ffffffff-0000-4000-8000-000000000002"

      routes = [
        {"/api/v1/entities/definitions/active/", "k_ent", "ghost_ent"},
        {"/api/v1/entities/definitions/by-name/", "k_ent", "ghost_ent"},
        {"/api/v1/entities/definitions/", created.id, absent_id}
      ]

      # control: unrestricted, every route answers 200
      for {base, present, _absent} <- routes do
        assert get(denied_caller, base <> present).status == 200, base
      end

      :ok = Fx.restrict!(world.schema_name, "k_ent")
      :ok = Fx.grant!(world.schema_name, granted_caller.user_id, "k_ent")

      for {base, present, absent} <- routes do
        denied_response = norm(get(denied_caller, base <> present), denied_caller)
        absent_response = norm(get(denied_caller, base <> absent), denied_caller)
        assert denied_response.status == 404, base
        assert_same!(base, denied_response, absent_response)
        assert get(granted_caller, base <> present).status == 200, base
      end
    end
  end

  # -- T-11 --------------------------------------------------------------------------------

  describe "T-11 -- HTTP denied vs absent" do
    test "every page of the denied world equals the same page of the world without the type (status, headers, items, cursor position, bytes where next_cursor is null)" do
      {denied, absent} = denied_and_absent_worlds!()

      for page_size <- @page_sizes do
        in_denied = walk(denied, page_size)
        in_absent = walk(absent, page_size)
        assert {page_size, length(in_denied)} == {page_size, length(in_absent)}

        for {{a, b}, index} <- Enum.with_index(Enum.zip(in_denied, in_absent)) do
          assert_same!({page_size, index}, a, b)
        end
      end

      # at least one compared page has a null next_cursor, so bytes WERE compared
      assert [%{next: nil}] = walk(denied, 200)
      assert [%{next: nil}] = walk(absent, 200)
    end
  end

  # -- T-16 --------------------------------------------------------------------------------

  describe "T-16 -- no administrator bypass" do
    test "a TENANT_ADMIN without a grant does not see the restricted type on the list" do
      denied = denied_world!()
      assert denied.roles == ["TENANT_ADMIN"]

      page = norm(list(denied, page_size: 200), denied)
      assert item_ids(page) == Fx.ids(:without_x)
    end
  end

  # -- T-17 --------------------------------------------------------------------------------

  describe "T-17 -- everything denied" do
    test "a caller denied every type gets exactly the response of an empty tenant" do
      denied = world!(:with_x)

      for name <- ["a_ent", "b_ent", @denied] do
        :ok = Fx.restrict!(denied.schema_name, name)
      end

      empty = world!(:empty)

      for params <- [[], [page_size: 1], [page_size: 200]] do
        in_denied = norm(list(denied, params), denied)
        in_empty = norm(list(empty, params), empty)

        assert in_denied.items == []
        assert in_denied.next == nil
        assert Jason.decode!(in_denied.body) == %{"items" => [], "next_cursor" => nil}
        assert_same!(params, in_denied, in_empty)
      end
    end
  end

  defp dt_us(key), do: DateTime.to_unix(Fx.inserted_at(key), :microsecond)
end
