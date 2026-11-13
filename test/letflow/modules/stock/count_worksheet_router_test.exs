Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountWorksheetRouterTest do
  @moduledoc """
  T-1905 (design tests R1..R9, S1, S2): the count worksheet at `GET /counts/:id/print/worksheet` and
  `GET /counts/:id/paperwork/worksheet` through the full `Letflow.Router` with real OIDC bearer
  tokens on committed tenants (Sandbox `:auto`). `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CountsFixture, as: F
  alias Letflow.Entities.Records
  alias Letflow.Identity.User
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock.CountPaperworkSource
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.OrgFixture
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  setup do
    ctx = S.setup_oidc!([:a, :b, :s])
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

  defp strip(conn), do: M.strip_conn(conn)

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

  defp fv(schema, id) do
    {:ok, r} = Org.lookup(schema, id)
    Map.drop(r, ["record_id", "entity_type"])
  end

  defp update!(schema, type, id, extra) do
    {:ok, _} =
      Records.update_record(
        %{
          entity_type: type,
          record_id: id,
          field_values: Map.merge(fv(schema, id), extra),
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        schema,
        OrgFixture.owner()
      )
  end

  defp world!(ctx, name, slug \\ "wsheet") do
    t = S.tenant!(slug, Map.fetch!(ctx.names, name))
    s = t.schema_name
    w = F.world!(s)
    chair_tok = S.token(ctx, name, ["TENANT_ADMIN"], sub: "chair-#{name}")
    status!(call(:get, "/counts", chair_tok), 200)
    chair_user = Repo.one!(from(u in User, where: u.username == ^"chair-#{name}"), prefix: s)
    chair = F.employee!(s, w.unit, user: chair_user.id)

    le =
      OrgFixture.create!(s, "org_legal_entity", OrgFixture.values("org_legal_entity", "LE-1")).record_id

    update!(s, "org_unit", w.unit, %{"legal_entity_id" => le})
    %{t: t, s: s, w: %{w | chair: chair}, chair_tok: chair_tok, le: fv(s, le)}
  end

  defp stock!(x) do
    S.post!(x.s, "receipt", %{lines: [S.line(S.uuid(), "10", %{to: S.side(x.w.unit, x.w.a)})]})
    S.post!(x.s, "receipt", %{lines: [S.line(S.uuid(), "4", %{to: S.side(x.w.unit, x.w.a1)})]})
  end

  defp ordered!(x, extra \\ %{}) do
    input = F.input(x.w, Map.merge(window(), extra))
    id = status!(call(:post, "/counts", x.chair_tok, input), 201)["id"]
    status!(call(:post, "/counts/#{id}/issue", x.chair_tok, %{}), 200)
    id
  end

  defp open!(x, id), do: status!(call(:post, "/counts/#{id}/open", x.chair_tok, %{}), 200)

  defp ws(id, tok, q \\ ""), do: call(:get, "/counts/#{id}/print/worksheet#{q}", tok)
  defp xl(id, tok, q \\ ""), do: call(:get, "/counts/#{id}/paperwork/worksheet#{q}", tok)
  defp texts(conn), do: PdfProbe.items(conn.resp_body)

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
            v = Regex.run(~r/<v>(.*?)<\/v>/, List.first(rest) || "")

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

  defp set_zone!(x, zone) do
    Repo.query!(
      "UPDATE tenants SET settings = jsonb_set(coalesce(settings, '{}'::jsonb), '{timezone}', $2::jsonb) WHERE id = $1",
      [Ecto.UUID.dump!(x.t.tenant_id), zone]
    )
  end

  describe "R1 / R4 pdf, xlsx, variants" do
    test "ordered and counting; expected rule; bad parameters", ctx do
      x = world!(ctx, :a)
      stock!(x)
      id = ordered!(x)

      conn = ws(id, x.chair_tok)
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() == "application/pdf"

      assert hd(get_resp_header(conn, "content-disposition")) =~
               ~r/\Aattachment; filename="CO-\d{4}-\d+_worksheet\.pdf"\z/

      assert "%PDF-" <> _ = conn.resp_body
      assert "Рабочий лист инвентаризации" in texts(conn)
      assert Enum.any?(texts(conn), &String.contains?(&1, x.le["name"]))
      assert Enum.any?(texts(conn), &String.contains?(&1, x.le["bin"]))

      # blank: no expected column and no book quantity (10 and 4 are the stocked quantities)
      for q <- ["", "?expected=0"] do
        t = texts(ws(id, x.chair_tok, q))
        refute "Ожидается (по учёту)" in t
        refute "10" in t
        refute "4" in t
      end

      t = texts(ws(id, x.chair_tok, "?expected=1&lang=en"))
      assert "Expected (book)" in t and "10" in t and "4" in t

      for bad <- ["?expected=2", "?expected=true", "?expected="] do
        assert status!(ws(id, x.chair_tok, bad), 422)["reason"] == "invalid_expected", bad
        assert status!(xl(id, x.chair_tok, bad), 422)["reason"] == "invalid_expected", bad
      end

      assert status!(ws(id, x.chair_tok, "?lang=de"), 422)["reason"] == "invalid_lang"
      assert status!(ws(id, x.chair_tok, "?form=inv10"), 422)["reason"] == "invalid_form"

      open!(x, id)
      assert ws(id, x.chair_tok, "?lang=kk").status == 200
      assert "Түгендеудің жұмыс парағы" in texts(ws(id, x.chair_tok, "?lang=kk"))
    end

    test "the xlsx has the three sheets and empty counted cells", ctx do
      x = world!(ctx, :a)
      stock!(x)
      id = ordered!(x)
      conn = xl(id, x.chair_tok, "?lang=en&expected=1")
      assert conn.status == 200

      assert hd(get_resp_header(conn, "content-disposition")) =~
               ~r/filename="CO-\d{4}-\d+_worksheet\.xlsx"/

      sh = sheets(conn.resp_body)
      assert Map.keys(sh) |> Enum.sort() == ["Document", "Lines", "Signatures"]
      [header | rows] = sh["Lines"]
      assert length(rows) == 2
      counted = Enum.find_index(header, &(&1 == "Counted qty"))
      assert Enum.all?(rows, &(Enum.at(&1, counted) == ""))
      assert "Expected (book)" in header

      blank = sheets(xl(id, x.chair_tok, "?lang=en").resp_body)["Lines"] |> hd()
      refute "Expected (book)" in blank
    end
  end

  describe "R3 same lines as the sheet" do
    test "the preview at ordered equals the lines after the open", ctx do
      x = world!(ctx, :a)
      stock!(x)
      id = ordered!(x)

      before = sheets(xl(id, x.chair_tok, "?lang=en").resp_body)["Lines"] |> tl()
      open!(x, id)
      rows = status!(call(:get, "/counts/#{id}/lines", x.chair_tok), 200)["rows"]
      after_open = sheets(xl(id, x.chair_tok, "?lang=en").resp_body)["Lines"] |> tl()

      assert length(rows) == 2
      assert before == after_open
      assert length(before) == length(rows)
    end
  end

  describe "R5 / R5b header and zone" do
    test "times carry the tenant offset, equal to the order print", ctx do
      x = world!(ctx, :a, "ws-tz-a")
      stock!(x)

      id =
        ordered!(x, %{
          "planned_start" => "2026-11-10T09:00:00+05:00",
          "planned_end" => "2026-11-11T09:00:00+05:00"
        })

      b = world!(ctx, :b, "ws-tz-b")
      stock!(b)

      idb = ordered!(b)

      set_zone!(b, "Asia/Tokyo")

      a_texts = texts(ws(id, x.chair_tok))
      assert Enum.any?(a_texts, &(&1 =~ "(UTC+05:00)"))
      refute Enum.any?(a_texts, &(&1 =~ "(UTC+00:00)"))

      w = texts(ws(idb, b.chair_tok))
      o = texts(call(:get, "/counts/#{idb}/print/order", b.chair_tok))
      refute Enum.any?(w, &(&1 =~ "(UTC+00:00)"))

      for {wl, ol} <- [{"Дата приказа: ", "Выдан: "}, {"Начало (план): ", "Начало (план): "}] do
        [wv] = Enum.filter(w, &String.starts_with?(&1, wl))
        assert wv =~ " (UTC+09:00)"
        [ov] = Enum.filter(o, &String.starts_with?(&1, ol))
        assert String.replace_prefix(wv, wl, "") == String.replace_prefix(ov, ol, "")
      end

      open!(b, idb)
      assert Enum.any?(texts(ws(idb, b.chair_tok)), &(&1 =~ "срез" or &1 =~ "среза"))
      refute Enum.any?(texts(ws(idb, b.chair_tok)), &(&1 =~ "(UTC+00:00)"))

      doc = sheets(xl(idb, b.chair_tok, "?lang=ru").resp_body)["Документ"]
      assert Enum.any?(doc, fn [k, v] -> k == "Дата приказа" and v =~ "(UTC+09:00)" end)
    end
  end

  describe "R6 / R7 permission and tenancy" do
    test "a task worker is refused; another tenant and an unseen unit are 404", ctx do
      x = world!(ctx, :a, "ws-perm")
      stock!(x)
      id = ordered!(x)

      worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "ws-worker")
      assert ws(id, worker).status == 403
      assert xl(id, worker).status == 403

      assert {"GET", "/counts/:id/print/:kind", :StockRead} in Letflow.Modules.Stock.manifest().route_policies

      assert {"GET", "/counts/:id/paperwork/:kind", :StockRead} in Letflow.Modules.Stock.manifest().route_policies

      b = world!(ctx, :b, "ws-perm-b")
      stock!(b)
      idb = ordered!(b)
      unknown = Ecto.UUID.generate()

      for f <- [&ws/2, &xl/2] do
        got = f.(idb, ctx.tok_a)
        assert got.status == 404
        assert strip(got) == strip(f.(unknown, ctx.tok_a))
        refute got.resp_body =~ "%PDF"
      end

      s_t = S.tenant!("ws-scoped", Map.fetch!(ctx.names, :s))
      s = s_t.schema_name
      wx = F.world!(s)
      wy = F.world!(s)
      opts = %{actor_id: Ecto.UUID.generate(), scope: :all}
      {:ok, oy} = Letflow.Modules.Stock.Counts.create(s, F.input(wy, window()), opts)
      {:ok, _} = Letflow.Modules.Stock.Counts.issue(s, oy["id"], opts)

      tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "ws-scoped-user")
      status!(call(:get, "/counts", tok), 200)
      user = Repo.one!(from(u in User, where: u.username == "ws-scoped-user"), prefix: s)
      group = RSG.group_of!(s, "TENANT_ADMIN")
      _ = RSG.raw_delete_rows!(s, group, "TENANT_ADMIN")
      :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", wx.unit)

      assert strip(ws(oy["id"], tok)) == strip(ws(unknown, tok))
      assert ws(oy["id"], tok).status == 404
    end
  end

  describe "R8 not a document of record" do
    test "nothing is written by the worksheet", ctx do
      x = world!(ctx, :a, "ws-nowrite")
      stock!(x)
      id = ordered!(x)

      snapshot = fn ->
        for t <- ~w(documents document_versions audit_entries) do
          {t, Repo.query!(~s[SELECT count(*) FROM "#{x.s}".#{t}]).rows}
        end ++
          [
            lines:
              Repo.all(
                from(l in Letflow.Entities.Record.Latest,
                  where: l.entity_type == "count_sheet_line",
                  select: count()
                ),
                prefix: x.s
              ),
            order: status!(call(:get, "/counts/#{id}", x.chair_tok), 200)["status"]
          ]
      end

      snap = fn -> snapshot.() end
      before = snap.()
      for _ <- 1..3, do: assert(ws(id, x.chair_tok).status == 200)
      assert snap.() == before

      open!(x, id)
      before = snap.()
      for _ <- 1..3, do: assert(xl(id, x.chair_tok).status == 200)
      assert snap.() == before
    end
  end

  describe "R9 states" do
    test "only ordered and counting", ctx do
      x = world!(ctx, :a, "ws-states")
      stock!(x)

      draft = status!(call(:post, "/counts", x.chair_tok, F.input(x.w, window())), 201)["id"]
      assert status!(ws(draft, x.chair_tok), 422)["reason"] == "worksheet_not_available"

      cancelled = ordered!(x)
      status!(call(:post, "/counts/#{cancelled}/cancel", x.chair_tok, %{}), 200)
      assert status!(ws(cancelled, x.chair_tok), 422)["reason"] == "worksheet_not_available"

      id = ordered!(x)
      open!(x, id)

      for n <- [1, 2] do
        status!(
          call(:put, "/counts/#{id}/lines/#{n}/count", x.chair_tok, %{"counted_quantity" => "3"}),
          200
        )
      end

      status!(call(:post, "/counts/#{id}/close", x.chair_tok, %{}), 200)
      assert status!(ws(id, x.chair_tok), 422)["reason"] == "worksheet_not_available"
      assert status!(xl(id, x.chair_tok), 422)["reason"] == "worksheet_not_available"
    end
  end

  describe "S1 / S2 preview error paths" do
    test "no ledger authorization and the line cap", ctx do
      x = world!(ctx, :a, "ws-preview")
      stock!(x)
      id = ordered!(x)

      sctx = %{
        scope: :all,
        principal: nil,
        tenant_id: x.t.tenant_id
      }

      assert {:error, :ledger_read_not_allowed} =
               CountPaperworkSource.read_worksheet(x.s, id, sctx, nil)

      old = Application.get_env(:letflow, :stock_count_max_lines)
      Application.put_env(:letflow, :stock_count_max_lines, 1)

      on_exit(fn ->
        if old,
          do: Application.put_env(:letflow, :stock_count_max_lines, old),
          else: Application.delete_env(:letflow, :stock_count_max_lines)
      end)

      assert status!(ws(id, x.chair_tok), 422)["reason"] == "count_too_large"
    end
  end
end
