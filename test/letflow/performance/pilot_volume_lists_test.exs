Code.require_file("../modules/assets/register_fixture.exs", __DIR__)
Code.require_file("../modules/assets/assets_fixture.exs", __DIR__)
Code.require_file("../modules/catalog_items/catalog_items_fixture.exs", __DIR__)
Code.require_file("../modules/codes/codes_fixture.exs", __DIR__)
Code.require_file("../modules/locations/locations_fixture.exs", __DIR__)
Code.require_file("../modules/org/org_fixture.exs", __DIR__)

defmodule Letflow.Performance.PilotVolumeListsTest do
  @moduledoc """
  T-1801 (follow-up of T-1562 / B16#1): the other list screens at pilot size. The web modules catalog_items, codes,
  locations and org load a whole type with `fetchAllRecords` (page_size 200, cursor loop, `MAX_PAGES = 50`, so at most
  10 000 rows); the stock and assets pickers read one page of 200. This test seeds @rows records of each of
  `catalog_item`, `code_tag`, `location_node`, `org_employee` and replays those reads against the real router, printing
  per type: pages needed, rows the screen's loop reaches, whether the server still had a next cursor after the loop
  (a silent truncation), the loop time, and the time and fullness of one picker page.

  `@moduletag :pilot_volume`: excluded by default, run on demand with
  `MIX_TEST_PARTITION=<n> mix test --only pilot_volume test/letflow/performance/pilot_volume_lists_test.exs`.
  Local test stack only. The only assertions are structural (every type was seeded to the full count).
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsFixture, as: A
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.CatalogItemsFixture, as: C
  alias Letflow.CodesFixture, as: K
  alias Letflow.LocationsFixture, as: L
  alias Letflow.OrgFixture, as: O
  alias Letflow.Repo

  @moduletag :pilot_volume
  @moduletag timeout: 600_000

  @rows String.to_integer(System.get_env("PILOT_ROWS") || "12000")
  @max_pages 50
  @entity "/api/v1/entities/query"

  defp fresh_conn, do: Ecto.Adapters.SQL.Sandbox.checkin(Repo)

  defp ms(fun) do
    {micros, result} = :timer.tc(fun)
    {micros / 1000, result}
  end

  defp post_json(path, tok, body) do
    import Plug.Conn

    Plug.Test.conn(:post, path, Jason.encode!(body))
    |> put_req_header("authorization", "Bearer " <> tok)
    |> put_req_header("content-type", "application/json")
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp num(i), do: String.pad_leading("#{i}", 6, "0")

  defp seed!(label, make) do
    {t, _} =
      ms(fn ->
        1..@rows
        |> Task.async_stream(make, max_concurrency: 4, ordered: false, timeout: 120_000)
        |> Stream.run()
      end)

    IO.puts("PILOT-LISTS seed #{label}: #{@rows} rows in #{round(t / 1000)} s")
  end

  # the screens' loop: page_size 200, follow the cursor, stop after @max_pages
  defp loop(tok, type, filters, sort_field) do
    body = %{
      entity_type: type,
      filters: filters,
      sort: [%{field: sort_field, dir: "asc"}],
      page_size: 200
    }

    Enum.reduce_while(1..@max_pages, {nil, 0, 0, 0.0}, fn page, {cursor, _, rows, total} ->
      b = if cursor, do: Map.put(body, :cursor, cursor), else: body
      fresh_conn()
      {t, conn} = ms(fn -> post_json(@entity, tok, b) end)

      assert conn.status == 200,
             "#{type} page #{page}: #{conn.status} #{String.slice(conn.resp_body, 0, 300)}"

      resp = Jason.decode!(conn.resp_body)
      acc = {resp["next_cursor"], page, rows + length(resp["items"]), total + t}
      if resp["next_cursor"], do: {:cont, acc}, else: {:halt, acc}
    end)
  end

  defp report(tok, type, sort_field, picker? \\ true) do
    screen = [%{field: "deleted", op: "eq", value: false}]

    picker = [
      %{field: "active", op: "eq", value: true},
      %{field: "deleted", op: "eq", value: false}
    ]

    {next, pages, rows, total} = loop(tok, type, screen, sort_field)

    fresh_conn()

    # code_tag has no `active` field and no picker: its row only reports the screen loop
    {t_pick, pick} =
      if picker? do
        {t, conn} =
          ms(fn ->
            post_json(@entity, tok, %{entity_type: type, filters: picker, page_size: 200})
          end)

        assert conn.status == 200
        {t, Jason.decode!(conn.resp_body)}
      else
        {0.0, %{"items" => [], "next_cursor" => nil}}
      end

    IO.puts(
      "PILOT-LISTS #{type}: screen loop #{pages} pages, #{rows} rows reached, truncated=#{next != nil}, " <>
        "#{round(total)} ms (#{round(total / pages)} ms/page); picker one page: #{length(pick["items"])} rows, " <>
        "more_on_server=#{pick["next_cursor"] != nil}, #{round(t_pick)} ms"
    )

    {next != nil, pick["next_cursor"] != nil}
  end

  test "P-lists: fetch-all loops and picker pages of the master types at pilot size" do
    ctx = S.setup_oidc!([:a])
    a = S.tenant!("pilotl", ctx.names.a)
    schema = a.schema_name

    for m <- ~w(org catalog_items locations codes) do
      # a module the provisioning already installed answers 409
      try do
        A.install_module!(a.tenant_id, m)
      rescue
        e in RuntimeError -> if e.message =~ "409", do: :ok, else: reraise(e, __STACKTRACE__)
      end
    end

    uom = C.uom!(schema, "PERF-UOM")
    unit_id = O.unit_id!(schema, "PERF-UNIT")

    seed!("catalog_item", fn i ->
      C.item!(schema, "IT-" <> num(i), uom.record_id)
    end)

    seed!("code_tag", fn i -> K.tag!(schema, "TAG-" <> num(i)) end)
    seed!("location_node", fn i -> L.node!(schema, "LOC-" <> num(i)) end)

    seed!("org_employee", fn i ->
      O.create!(
        schema,
        "org_employee",
        O.values("org_employee", "EMP-" <> num(i), %{"org_unit_id" => unit_id})
      )
    end)

    tok = S.token(ctx, :a, ["TENANT_ADMIN"])

    results = [
      report(tok, "catalog_item", "code"),
      report(tok, "code_tag", "value", false),
      report(tok, "location_node", "code"),
      report(tok, "org_employee", "code")
    ]

    assert length(results) == 4
  end
end
