Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountPaperworkRouterTest do
  @moduledoc """
  REQ-719 / GH #3762 criteria 2 to 5 (R1..R8): `GET /counts/:id/paperwork/:kind` through the full
  `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox `:auto`).
  `async: false`.

  The differences kind needs REQ-717 (`differences_document_id`), which is not on main when this
  is written: only its 422 is tested here; the renderer is covered in `count_paperwork_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CountsFixture, as: F
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Identity.User
  alias Letflow.Modules.Stock.Counts
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  setup do
    ctx = S.setup_oidc!([:a, :b, :s, :t])
    Map.put(ctx, :tok_a, S.token(ctx, :a, ["TENANT_ADMIN"]))
  end

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

  defp strip(conn), do: conn |> S.json() |> Map.delete("trace_id")

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    S.json(conn)
  end

  defp window do
    now = DateTime.utc_now()

    %{
      "planned_start" => DateTime.to_iso8601(DateTime.add(now, -3600)),
      "planned_end" => DateTime.to_iso8601(DateTime.add(now, 20 * 3600))
    }
  end

  defp world!(ctx, name, slug \\ "paper") do
    t = S.tenant!(slug, Map.fetch!(ctx.names, name))
    s = t.schema_name
    w = F.world!(s)
    chair_tok = S.token(ctx, name, ["TENANT_ADMIN"], sub: "chair-#{name}")
    status!(call(:get, "/counts", chair_tok), 200)
    chair_user = Repo.one!(from(u in User, where: u.username == ^"chair-#{name}"), prefix: s)
    chair = F.employee!(s, w.unit, user: chair_user.id)
    %{t: t, s: s, w: %{w | chair: chair}, chair_tok: chair_tok}
  end

  defp stock!(x) do
    S.post!(x.s, "receipt", %{lines: [S.line(S.uuid(), "10", %{to: S.side(x.w.unit, x.w.a)})]})
    S.post!(x.s, "receipt", %{lines: [S.line(S.uuid(), "4", %{to: S.side(x.w.unit, x.w.a1)})]})
  end

  defp ordered!(x, input_extra \\ %{}) do
    input = F.input(x.w, Map.merge(window(), input_extra))
    id = status!(call(:post, "/counts", x.chair_tok, input), 201)["id"]
    status!(call(:post, "/counts/#{id}/issue", x.chair_tok, %{}), 200)
    id
  end

  defp counted!(x, id) do
    status!(call(:post, "/counts/#{id}/open", x.chair_tok, %{}), 200)

    for n <- [1, 2] do
      body = %{"counted_quantity" => "3"}
      status!(call(:put, "/counts/#{id}/lines/#{n}/count", x.chair_tok, body), 200)
    end

    assert status!(call(:post, "/counts/#{id}/close", x.chair_tok, %{}), 200)["status"] ==
             "counted"
  end

  defp download(id, kind, tok), do: call(:get, "/counts/#{id}/paperwork/#{kind}", tok)

  defp sheets(binary) do
    {:ok, files} = :zip.unzip(binary, [:memory])
    parts = Map.new(files, fn {n, c} -> {to_string(n), c} end)

    strings =
      Regex.scan(~r/<si>(.*?)<\/si>/s, Map.fetch!(parts, "xl/sharedStrings.xml"))
      |> Enum.map(fn [_, si] ->
        Regex.scan(~r/<t[^>]*>(.*?)<\/t>/s, si) |> Enum.map_join(fn [_, t] -> t end)
      end)

    names =
      Regex.scan(~r/<sheet [^>]*name="([^"]+)"/, Map.fetch!(parts, "xl/workbook.xml"))
      |> Enum.map(&List.last/1)

    names
    |> Enum.with_index(1)
    |> Map.new(fn {name, i} ->
      xml = Map.fetch!(parts, "xl/worksheets/sheet#{i}.xml")

      rows =
        Regex.scan(~r/<row [^>]*>(.*?)<\/row>/s, xml)
        |> Enum.map(fn [_, row] ->
          Regex.scan(~r/<c ([^>]*?)(?:\/>|>(.*?)<\/c>)/s, row)
          |> Enum.map(fn [_, attrs | rest] ->
            body = List.first(rest) || ""
            v = Regex.run(~r/<v>(.*?)<\/v>/, body)

            cond do
              v == nil -> ""
              attrs =~ ~s(t="s") -> Enum.at(strings, String.to_integer(List.last(v)))
              true -> List.last(v)
            end
          end)
        end)

      {name, rows}
    end)
  end

  defp employee_name(s, id) do
    {:ok, r} = Letflow.Modules.Org.lookup(s, id)
    {r["full_name"], r["code"]}
  end

  describe "R1 R2 R3 R4 download, kinds, not issued" do
    test "order and sheet download; other kinds 404; not issued 422", ctx do
      x = world!(ctx, :a)
      stock!(x)

      draft =
        status!(call(:post, "/counts", x.chair_tok, F.input(x.w, window())), 201)["id"]

      assert status!(download(draft, "order", x.chair_tok), 422)["reason"] ==
               "document_not_issued"

      id = ordered!(x)
      conn = download(id, "order", x.chair_tok)
      assert conn.status == 200

      assert get_resp_header(conn, "content-type") |> hd() ==
               "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

      [disp] = get_resp_header(conn, "content-disposition")
      assert disp =~ ~r/\Aattachment; filename="CO-\d{4}-\d+\.xlsx"\z/

      assert Map.keys(sheets(conn.resp_body)) |> Enum.sort() == [
               "document",
               "scope",
               "signatures"
             ]

      # T-1435 X5: ?lang= localizes; an unknown one is 422 invalid_lang
      ru = call(:get, "/counts/#{id}/paperwork/order?lang=ru", x.chair_tok)
      assert ru.status == 200
      assert Map.keys(sheets(ru.resp_body)) |> Enum.sort() == ["Документ", "Охват", "Подписи"]

      assert status!(call(:get, "/counts/#{id}/paperwork/order?lang=de", x.chair_tok), 422)[
               "reason"
             ] ==
               "invalid_lang"

      assert status!(download(id, "sheet", x.chair_tok), 422)["reason"] == "document_not_issued"

      assert status!(download(id, "differences", x.chair_tok), 422)["reason"] ==
               "document_not_issued"

      counted!(x, id)
      conn = download(id, "sheet", x.chair_tok)
      assert conn.status == 200
      assert hd(get_resp_header(conn, "content-disposition")) =~ ~r/filename="CS-\d{4}-\d+\.xlsx"/

      assert Map.keys(sheets(conn.resp_body)) |> Enum.sort() == [
               "document",
               "lines",
               "signatures"
             ]

      assert status!(download(id, "differences", x.chair_tok), 422)["reason"] ==
               "document_not_issued"

      for kind <- ["other", "ORDER", "orders", "Sheet"] do
        assert download(id, kind, x.chair_tok).status == 404, kind
      end
    end

    test "T3 the unit column of the sheet and the differences shows the unit name, not its id",
         ctx do
      x = world!(ctx, :a)
      uom = Letflow.CatalogItemsFixture.uom!(x.s, "KGX#{System.unique_integer([:positive])}")

      for {loc, q} <- [{x.w.a, "10"}, {x.w.a1, "4"}] do
        S.post!(x.s, "receipt", %{
          lines: [S.line(S.uuid(), q, %{to: S.side(x.w.unit, loc)}, %{unit: uom.record_id})]
        })
      end

      id = ordered!(x)
      counted!(x, id)
      conn = download(id, "sheet", x.chair_tok)
      assert conn.status == 200

      [header | rows] = sheets(conn.resp_body)["lines"]
      at = Enum.find_index(header, &(&1 == "unit"))
      assert rows != []

      for row <- rows do
        cell = Enum.at(row, at)
        assert cell =~ ~r/\AKGX\d+ /
        refute cell =~ uom.record_id
      end
    end

    test "R4 the route is a StockRead route of the module" do
      assert {"GET", "/counts/:id/paperwork/:kind", :StockRead} in Letflow.Modules.Stock.manifest().route_policies
    end
  end

  describe "R5 fixed content" do
    test "a changed live line does not change the issued sheet file", ctx do
      x = world!(ctx, :a)
      stock!(x)
      id = ordered!(x)
      counted!(x, id)

      first = download(id, "sheet", x.chair_tok)
      assert first.status == 200
      before = sheets(first.resp_body)["lines"]
      assert Enum.any?(before, &("3.000000000" in &1))

      line =
        Repo.one!(
          from(l in Latest,
            where:
              l.entity_type == "count_sheet_line" and
                fragment("?->>'line_no' = '1'", l.field_values)
          ),
          prefix: x.s
        )

      fv = Map.put(line.field_values, "counted_quantity", "999.000000000")

      {:ok, _} =
        Records.update_record(
          %{
            entity_type: "count_sheet_line",
            record_id: line.record_id,
            field_values: fv,
            actor_id: Ecto.UUID.generate(),
            idempotency_key: "paper-test:" <> Ecto.UUID.generate()
          },
          x.s,
          ManagedTypes.owner_for!(Letflow.Modules.Stock)
        )

      second = download(id, "sheet", x.chair_tok)
      assert sheets(second.resp_body)["lines"] == before
      refute second.resp_body =~ "999"
      assert sheets(download(id, "sheet", x.chair_tok).resp_body) == sheets(second.resp_body)
    end
  end

  describe "R6 names and scope" do
    test "a scoped admin sees an empty row for a member of an unseen unit", ctx do
      t = S.tenant!("paper-s", Map.fetch!(ctx.names, :s))
      s = t.schema_name
      wx = F.world!(s)
      wz = F.world!(s)
      [mx, _] = wx.members
      [mz, _] = wz.members
      m = D.masters!(s)
      _ = m
      S.post!(s, "receipt", %{lines: [S.line(S.uuid(), "10", %{to: S.side(wx.unit, wx.a)})]})

      chair_tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "paper-chair")
      status!(call(:get, "/counts", chair_tok), 200)
      cu = Repo.one!(from(u in User, where: u.username == "paper-chair"), prefix: s)
      chair = F.employee!(s, wx.unit, user: cu.id)
      wx = %{wx | chair: chair}

      input = F.input(wx, Map.put(window(), "member_employee_ids", [mx, mz]))
      id = status!(call(:post, "/counts", chair_tok, input), 201)["id"]
      status!(call(:post, "/counts/#{id}/issue", chair_tok, %{}), 200)
      status!(call(:post, "/counts/#{id}/open", chair_tok, %{}), 200)

      lines = status!(call(:get, "/counts/#{id}/lines", chair_tok), 200)["rows"]

      for l <- lines do
        body = %{"counted_quantity" => "1"}
        status!(call(:put, "/counts/#{id}/lines/#{l["line_no"]}/count", chair_tok, body), 200)
      end

      status!(call(:post, "/counts/#{id}/close", chair_tok, %{}), 200)

      {cn, cc} = employee_name(s, chair)
      {xn, xc} = employee_name(s, mx)
      {zn, zc} = employee_name(s, mz)

      all = sheets(download(id, "sheet", chair_tok).resp_body)["signatures"]
      assert ["chair", cn, cc, "", ""] in all
      assert ["member", xn, xc, "", ""] in all
      assert ["member", zn, zc, "", ""] in all

      scoped_tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "paper-scoped")
      status!(call(:get, "/counts", scoped_tok), 200)
      user = Repo.one!(from(u in User, where: u.username == "paper-scoped"), prefix: s)
      group = RSG.group_of!(s, "TENANT_ADMIN")
      _ = RSG.raw_delete_rows!(s, group, "TENANT_ADMIN")
      :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", wx.unit)

      conn = download(id, "sheet", scoped_tok)
      assert conn.status == 200
      rows = sheets(conn.resp_body)["signatures"]
      assert ["chair", cn, cc, "", ""] in rows
      assert ["member", xn, xc, "", ""] in rows
      assert ["member", "", "", "", ""] in rows
      refute zn in List.flatten(rows)
      refute zc in List.flatten(rows)
      refute conn.resp_body =~ zn
    end
  end

  describe "R7 tenancy and permission" do
    test "another tenant, an unseen unit, no permission", ctx do
      _a = world!(ctx, :a)
      b = world!(ctx, :b)
      stock!(b)
      id = ordered!(b)
      unknown = Ecto.UUID.generate()

      got = download(id, "order", ctx.tok_a)
      want = download(unknown, "order", ctx.tok_a)
      assert got.status == 404
      assert strip(got) == strip(want)
      refute got.resp_body =~ "PK"

      tt = S.tenant!("paper-t", Map.fetch!(ctx.names, :t))
      s = tt.schema_name
      wx = F.world!(s)
      wy = F.world!(s)
      opts = %{actor_id: Ecto.UUID.generate(), scope: :all}
      {:ok, oy} = Counts.create(s, F.input(wy, window()), opts)
      {:ok, _} = Counts.issue(s, oy["id"], opts)
      _ = wx

      tok = S.token(ctx, :t, ["TENANT_ADMIN"], sub: "paper-scoped-t")
      status!(call(:get, "/counts", tok), 200)
      user = Repo.one!(from(u in User, where: u.username == "paper-scoped-t"), prefix: s)
      group = RSG.group_of!(s, "TENANT_ADMIN")
      _ = RSG.raw_delete_rows!(s, group, "TENANT_ADMIN")
      :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", wx.unit)

      got = download(oy["id"], "order", tok)
      want = download(unknown, "order", tok)
      assert got.status == 404
      assert strip(got) == strip(want)

      worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "paper-worker")
      assert download(id, "order", worker).status == 403
    end
  end

  describe "R8 tenant time zone" do
    test "only the token's tenant decides the zone", ctx do
      a = world!(ctx, :a, "paper-tz-a")
      stock!(a)
      ida = ordered!(a)
      b = world!(ctx, :b, "paper-tz-b")
      stock!(b)
      idb = ordered!(b)

      Repo.query!(
        "UPDATE tenants SET settings = jsonb_set(coalesce(settings, '{}'::jsonb), '{timezone}', '\"Asia/Tokyo\"') WHERE id = $1",
        [Ecto.UUID.dump!(b.t.tenant_id)]
      )

      doc = &sheets(&1.resp_body)["document"]
      a_doc = doc.(download(ida, "order", a.chair_tok))
      b_doc = doc.(download(idb, "order", b.chair_tok))

      assert ["timezone", "Asia/Almaty"] in a_doc
      assert ["timezone", "Asia/Tokyo"] in b_doc
      assert Enum.any?(a_doc, &match?(["issued_at", <<_::binary-size(19), "+05:00">>], &1))
      assert Enum.any?(b_doc, &match?(["issued_at", <<_::binary-size(19), "+09:00">>], &1))
    end
  end
end
