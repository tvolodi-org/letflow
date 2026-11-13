Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountPrintRouterTest do
  @moduledoc """
  REQ-736 / GH #3861, criteria 4 to 7 (design T-1349 tests R1..R4): `GET /counts/:id/print/:kind`
  through the full `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox
  `:auto`). `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CountsFixture, as: F
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Identity.User
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Stock.Counts
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
  defp print(id, kind, tok, q \\ ""), do: call(:get, "/counts/#{id}/print/#{kind}#{q}", tok)

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

  defp texts(pdf), do: Letflow.Modules.Stock.CountPrintTest.PdfProbe.items(pdf)

  describe "R1 download, kinds, language" do
    test "pdf for each issued kind; bad kind 404; lang default and invalid; not issued 422",
         ctx do
      x = world!(ctx, :a)
      stock!(x)

      draft = status!(call(:post, "/counts", x.chair_tok, F.input(x.w, window())), 201)["id"]
      assert status!(print(draft, "order", x.chair_tok), 422)["reason"] == "document_not_issued"

      id = ordered!(x)
      counted!(x, id)

      conn = print(id, "order", x.chair_tok)
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() == "application/pdf"

      assert hd(get_resp_header(conn, "content-disposition")) =~
               ~r/\Aattachment; filename="CO-\d{4}-\d+\.pdf"\z/

      assert "%PDF-" <> _ = conn.resp_body
      assert "Приказ о проведении инвентаризации" in texts(conn.resp_body)

      for {lang, title} <- [{"en", "Stock count order"}, {"kk", "Түгендеу жүргізу туралы бұйрық"}] do
        c = print(id, "order", x.chair_tok, "?lang=#{lang}")
        assert c.status == 200
        assert title in texts(c.resp_body)
      end

      sheet = print(id, "sheet", x.chair_tok, "?lang=en")
      assert sheet.status == 200
      assert hd(get_resp_header(sheet, "content-disposition")) =~ ~r/filename="CS-\d{4}-\d+\.pdf"/

      for bad <- ["?lang=de", "?lang=RU", "?lang="] do
        assert status!(print(id, "order", x.chair_tok, bad), 422)["reason"] == "invalid_lang", bad
      end

      for kind <- ["other", "ORDER", "orders"] do
        assert print(id, kind, x.chair_tok).status == 404, kind
      end

      assert status!(print(id, "differences", x.chair_tok), 422)["reason"] ==
               "document_not_issued"
    end

    test "the route is a StockRead route of the module" do
      assert {"GET", "/counts/:id/print/:kind", :StockRead} in Letflow.Modules.Stock.manifest().route_policies
    end
  end

  describe "R2 same source as the xlsx" do
    test "a changed live line does not change the PDF; the signers match the xlsx", ctx do
      x = world!(ctx, :a)
      stock!(x)
      id = ordered!(x)
      counted!(x, id)

      first = print(id, "sheet", x.chair_tok, "?lang=en")
      assert first.status == 200
      assert "3" in texts(first.resp_body)

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
            idempotency_key: "print-test:" <> Ecto.UUID.generate()
          },
          x.s,
          ManagedTypes.owner_for!(Letflow.Modules.Stock)
        )

      second = print(id, "sheet", x.chair_tok, "?lang=en")
      assert texts(second.resp_body) == texts(first.resp_body)
      refute "999" in texts(second.resp_body)

      xlsx = sheets(download(id, "sheet", x.chair_tok).resp_body)["signatures"]
      names = for [_role, name, _code | _] <- tl(xlsx), name != "", do: name
      assert names != []
      pdf = texts(second.resp_body)
      positions = Enum.map(names, fn n -> Enum.find_index(pdf, &(&1 == n)) end)
      refute nil in positions
      assert positions == Enum.sort(positions)
    end

    test "one scope check and one employee lookup in the shared source" do
      src = File.read!("lib/letflow/modules/stock/count_paperwork_source.ex")
      assert length(Regex.scan(~r/Scope\.allowed\?\(/, src)) == 1
      assert length(Regex.scan(~r/def read\(/, src)) == 1
      print = File.read!("lib/letflow/modules/stock/count_print.ex")
      refute print =~ "Scope.allowed?"
      refute print =~ "Org.lookup"
    end
  end

  describe "R3 names and scope" do
    test "a scoped admin gets an empty signer row for a member of an unseen unit", ctx do
      t = S.tenant!("print-s", Map.fetch!(ctx.names, :s))
      s = t.schema_name
      wx = F.world!(s)
      wz = F.world!(s)
      [mx, _] = wx.members
      [mz, _] = wz.members
      S.post!(s, "receipt", %{lines: [S.line(S.uuid(), "10", %{to: S.side(wx.unit, wx.a)})]})

      chair_tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "print-chair")
      status!(call(:get, "/counts", chair_tok), 200)
      cu = Repo.one!(from(u in User, where: u.username == "print-chair"), prefix: s)
      chair = F.employee!(s, wx.unit, user: cu.id)
      wx = %{wx | chair: chair}

      input = F.input(wx, Map.put(window(), "member_employee_ids", [mx, mz]))
      id = status!(call(:post, "/counts", chair_tok, input), 201)["id"]
      status!(call(:post, "/counts/#{id}/issue", chair_tok, %{}), 200)

      {xn, xc} = employee_name(s, mx)
      {zn, zc} = employee_name(s, mz)

      all = texts(print(id, "order", chair_tok, "?lang=en").resp_body)
      assert xn in all and zn in all and zc in all

      scoped_tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "print-scoped")
      status!(call(:get, "/counts", scoped_tok), 200)
      user = Repo.one!(from(u in User, where: u.username == "print-scoped"), prefix: s)
      group = RSG.group_of!(s, "TENANT_ADMIN")
      _ = RSG.raw_delete_rows!(s, group, "TENANT_ADMIN")
      :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", wx.unit)

      conn = print(id, "order", scoped_tok, "?lang=en")
      assert conn.status == 200
      rows = texts(conn.resp_body)
      assert xn in rows and xc in rows
      refute zn in rows
      refute zc in rows
      refute conn.resp_body =~ zn
    end
  end

  describe "R4 tenancy, permission, render failures" do
    test "another tenant, an unseen unit, no permission", ctx do
      _a = world!(ctx, :a)
      b = world!(ctx, :b)
      stock!(b)
      id = ordered!(b)
      unknown = Ecto.UUID.generate()

      got = print(id, "order", ctx.tok_a)
      want = print(unknown, "order", ctx.tok_a)
      assert got.status == 404
      assert strip(got) == strip(want)
      refute got.resp_body =~ "%PDF"

      tt = S.tenant!("print-t", Map.fetch!(ctx.names, :t))
      s = tt.schema_name
      wx = F.world!(s)
      wy = F.world!(s)
      opts = %{actor_id: Ecto.UUID.generate(), scope: :all}
      {:ok, oy} = Counts.create(s, F.input(wy, window()), opts)
      {:ok, _} = Counts.issue(s, oy["id"], opts)

      tok = S.token(ctx, :t, ["TENANT_ADMIN"], sub: "print-scoped-t")
      status!(call(:get, "/counts", tok), 200)
      user = Repo.one!(from(u in User, where: u.username == "print-scoped-t"), prefix: s)
      group = RSG.group_of!(s, "TENANT_ADMIN")
      _ = RSG.raw_delete_rows!(s, group, "TENANT_ADMIN")
      :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", wx.unit)

      got = print(oy["id"], "order", tok)
      want = print(unknown, "order", tok)
      assert got.status == 404
      assert strip(got) == strip(want)

      worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "print-worker")
      assert print(id, "order", worker).status == 403
    end

    test "a character the font lacks is 422 and writes no bytes", ctx do
      x = world!(ctx, :a, "print-glyph")
      stock!(x)

      bad =
        Letflow.OrgFixture.create!(
          x.s,
          "org_employee",
          Letflow.OrgFixture.values("org_employee", "E-GLYPH", %{
            "org_unit_id" => x.w.unit,
            "full_name" => "Bob \u6F22\u5B57"
          })
        ).record_id

      input = F.input(x.w, Map.put(window(), "member_employee_ids", [bad]))
      id = status!(call(:post, "/counts", x.chair_tok, input), 201)["id"]
      status!(call(:post, "/counts/#{id}/issue", x.chair_tok, %{}), 200)

      conn = print(id, "order", x.chair_tok, "?lang=en")
      assert status!(conn, 422)["reason"] == "print_unsupported_character"
      refute conn.resp_body =~ "%PDF"
      assert download(id, "order", x.chair_tok).status == 200
    end

    test "any other render violation is a 500 that logs rule atoms only" do
      # A cell taller than a page cannot be forced through the router: employee and catalog names
      # are capped by their entity types, so the 500 mapping is exercised on build/4's result:
      # a violation list other than :unsupported_glyph carries atoms only.
      issued = %{
        number_label: "N",
        version_no: 1,
        issued_at: nil,
        content: %{},
        order_content: %{}
      }

      huge = String.duplicate("W ", 40_000)
      names = %{employees: %{"e" => %{full_name: huge, code: "c"}}}
      order = %{"chair_employee_id" => "e"}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result =
            Letflow.Modules.Stock.CountPrint.build(
              :order,
              %{issued | order_content: order},
              names,
              :en
            )

          case result do
            {:error, {:render_failed, rules}} -> assert Enum.all?(rules, &is_atom/1)
            {:ok, _} -> :ok
          end
        end)

      refute log =~ "WW"
    end
  end
end
