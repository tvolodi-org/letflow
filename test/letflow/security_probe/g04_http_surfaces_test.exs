defmodule Letflow.SecurityProbe.G04HttpSurfacesTest do
  @moduledoc """
  G-04, HTTP surfaces (design cases C-21, C-22, C-24, C-25, C-26, C-27 and the
  seeded leaks of S1..S4 and the S* catch-all).

  One real tenant and a real TENANT_ADMIN token drive the REAL `Letflow.Router`.
  Every case plants a canary (`G04Canary.new/2`) in a request form (percent,
  double percent, header, cookie, urlencoded body, query, path), then runs ALL
  collectors it has (response body S1, headers S2, errors S3, every log level
  including Ecto SQL S4, and the database catch-all S*: every table of the
  tenant schema as `row_to_json`). A hit fails unless the exceptions list
  excuses it.

  Non-vacuity: the `seeded:` tests plant a canary straight into each surface
  through the SAME collector and verdict and assert the hit is named.

  Class table and what is not yet covered: `docs/security-probes/G-04.md`.
  """

  use Letflow.DataCase, async: false

  @moduletag :security_probe
  @moduletag probe_cost_s: 12

  require Logger

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.SecurityProbe.G04Canary, as: G
  alias Letflow.TenantFixture

  @exceptions Path.expand("../../fixtures/security_probes/g04/exceptions.txt", __DIR__)

  setup tags do
    if tags[:tenant] do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "g04")
      user = insert_user!(tenant)

      {:ok, %{plaintext: token}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: tenant.schema_name
        )

      {:ok, tenant: tenant, token: token}
    else
      :ok
    end
  end

  setup do
    {:ok, rows} = G.load_exceptions(@exceptions)
    sink = G.attach_sink()
    on_exit(fn -> G.detach_sink(sink) end)
    {:ok, rows: rows, sink: sink}
  end

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "g04-caller-#{Ecto.UUID.generate()}",
      display_name: "G-04 Caller",
      email: "g04-caller-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  # --- driving and collecting ------------------------------------------------

  defp call(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  # C-24/C-25 (design §6): the header and cookie canaries ride on EVERY request
  # of this file, so each real case also proves them absent from its sinks.
  @ambient_headers ["user-agent", "x-request-id", "traceparent", "idempotency-key"]

  defp ambient_canaries, do: [G.new("C-24", :header), G.new("C-25", :header)]

  defp ambient_headers do
    [c24, c25] = ambient_canaries()
    Enum.map(@ambient_headers, &{&1, c24.value}) ++ [{"cookie", "lf=" <> c25.value}]
  end

  defp request(method, path, body, headers) do
    conn = Plug.Test.conn(method, path, body)

    conn =
      Enum.reduce(ambient_headers() ++ headers, conn, fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)

    call(conn)
  end

  defp json_request(method, path, map, headers) do
    request(method, path, Jason.encode!(map), [{"content-type", "application/json"} | headers])
  end

  defp auth(%{token: token, tenant: tenant}),
    do: [{"authorization", "Bearer " <> token}, {"x-tenant-slug", tenant.tenant.slug}]

  # `authorised: true` is a case's declaration that the caller may read the record
  # that owns the value: the 2xx body is then `body_2xx_authorised` (exception E-01);
  # every other 2xx body is `body_2xx_other` and fails on a hit.
  defp response_items(conn, opts \\ []) do
    {surface, part} =
      cond do
        conn.status >= 400 -> {"S3", "raw_body"}
        Keyword.get(opts, :authorised, false) -> {"S1", "body_2xx_authorised"}
        true -> {"S1", "body_2xx_other"}
      end

    headers = Enum.map_join(conn.resp_headers, "\n", fn {k, v} -> k <> ": " <> v end)

    [
      {surface, "#{conn.method} #{conn.request_path} -> #{conn.status}", part, conn.resp_body},
      {"S2", "#{conn.method} #{conn.request_path}", "resp_headers", headers}
    ]
  end

  defp database_items(ctx), do: G.database_items(ctx.tenant.schema_name)

  # One verdict PER canary and case (`case_id:`): a case-scoped baseline row is
  # judged stale only by its own case. The ambient C-24/C-25 canaries are scanned
  # in every case.
  defp run_case(ctx, canary, responses, opts \\ []) do
    items =
      Enum.flat_map(responses, &response_items(&1, opts)) ++
        G.drain_sink(ctx.sink) ++ database_items(ctx)

    verdict_items(items, [canary | ambient_canaries()], ctx.rows)
  end

  defp verdict_items(items, canaries, rows) do
    G.verdict_cases(items, canaries, rows)
  end

  defp assert_clean(v) do
    assert v.unlisted == [], "G-04 leak(s): #{inspect(v.unlisted, pretty: true)}"
    assert v.stale == [], "stale baseline row(s): #{inspect(v.stale)}"
  end

  defp assert_status(conn, expected) do
    assert conn.status in List.wrap(expected),
           "entry condition: #{conn.method} #{conn.request_path} answered #{conn.status}, expected #{inspect(expected)}"

    conn
  end

  # --- the inventory is not empty ---------------------------------------------

  @tag tenant: true
  test "completeness: the catch-all reads a non-empty tenant schema and the sink works", ctx do
    assert Logger.level() == :debug
    items = database_items(ctx)
    assert length(items) > 20

    # the public side was read as well (the S* catch-all covers both schemas)
    assert Enum.any?(items, fn {_s, loc, _p, _b} -> String.starts_with?(loc, "public.") end)

    refute Enum.any?(items, fn {_s, loc, _p, _b} ->
             String.ends_with?(loc, ".schema_migrations")
           end)
  end

  # --- seeded failing cases (non-vacuity) -------------------------------------

  describe "seeded: a canary written straight into each surface is caught" do
    test "S1/S2/S3 through a response", ctx do
      c = G.new("SEED-HTTP", :email)

      ok = %{
        Plug.Test.conn(:get, "/api/v1/instances")
        | status: 200,
          resp_body: "x " <> c.value
      }

      hdr = %{
        ok
        | resp_body: "",
          resp_headers: [{"location", "/x?e=" <> URI.encode_www_form(c.value)}]
      }

      err = %{ok | status: 422, resp_body: ~s({"detail":"bad #{c.core}"})}

      hits = G.scan(Enum.flat_map([ok, hdr, err], &response_items/1), c)
      assert Enum.map(hits, & &1.surface) |> Enum.uniq() |> Enum.sort() == ["S1", "S2", "S3"]
      assert Enum.all?(G.verdict(hits, ctx.rows).unlisted, &(&1.kind == :email))
      assert length(G.verdict(hits, ctx.rows).unlisted) == 3
    end

    test "S4: a debug message, metadata and an Ecto SQL parameter", ctx do
      c = G.new("SEED-LOG2", :email)
      Logger.debug("leak #{c.value}")
      Logger.info("meta", data: c.core)
      Repo.query!("SELECT $1::text", [c.value])
      hits = G.scan(G.drain_sink(ctx.sink), c)
      assert length(hits) >= 3, inspect(hits)
      assert Enum.any?(hits, &(&1.locator =~ "debug"))
    end

    @tag tenant: true
    test "S*: a row in a table nobody listed", ctx do
      c = G.new("SEED-DB", :name)
      prefix = ctx.tenant.schema_name
      Repo.query!(~s|CREATE TABLE "#{prefix}".g04_seed (v text)|)
      Repo.query!(~s|INSERT INTO "#{prefix}".g04_seed VALUES ($1)|, [c.value])

      try do
        hits = G.scan(database_items(ctx), c)
        assert [%{surface: "S*:g04_seed"}] = hits
      after
        Repo.query!(~s|DROP TABLE "#{prefix}".g04_seed|)
      end
    end

    @tag tenant: true
    test "S*: a row in a table of the public schema", ctx do
      c = G.new("SEED-PUB", :email)
      Repo.query!("CREATE TABLE public.g04_seed_pub (v text)")
      Repo.query!("INSERT INTO public.g04_seed_pub VALUES ($1)", [c.value])

      try do
        hits = G.scan(database_items(ctx), c)
        assert [%{surface: "S*:g04_seed_pub"}] = hits
      after
        Repo.query!("DROP TABLE public.g04_seed_pub")
      end
    end

    test "S4: the production formatter bytes are collected and scanned", ctx do
      c = G.new("SEED-FMT", :name)
      Logger.info("formatter probe", seeded_field: c.core)
      items = G.drain_sink(ctx.sink)
      fmt = Enum.filter(items, fn {_s, loc, _p, _b} -> loc =~ "Obs.Logger.format" end)
      assert fmt != [], "no Letflow.Obs.Logger.format output was collected"
      assert [_ | _] = G.scan(fmt, c)
    end

    @tag tenant: true
    test "S5: an audit column and the authorised S1 part are told apart", ctx do
      c = G.new("SEED-S5", :email)
      ok = %{Plug.Test.conn(:get, "/x") | status: 200, resp_body: c.value}
      [{s1, _, part, _} | _] = response_items(ok, authorised: true)
      assert {s1, part} == {"S1", "body_2xx_authorised"}
      assert [{"S1", _, "body_2xx_other", _} | _] = response_items(ok)

      hits = G.scan(response_items(ok, authorised: true), c)
      assert G.verdict(hits, ctx.rows).unlisted == []
      hits = G.scan(response_items(ok), c)
      assert [_] = G.verdict(hits, ctx.rows).unlisted
    end

    test "a case-scoped baseline row is not stale in another case" do
      row = %{
        id: "B-X",
        type: "baseline",
        kinds: ["email"],
        surfaces: ["S4"],
        cases: ["C-01"],
        parts: ["any"],
        reason: "r",
        decided_by: "t"
      }

      hit = %{
        case_id: "C-01",
        kind: :email,
        surface: "S4",
        locator: "l",
        part: "any",
        form: :core
      }

      assert G.verdict([hit], [row], case_id: "C-01").stale == []
      assert G.verdict([], [row], case_id: "C-21").stale == []
      assert [%{id: "B-X"}] = G.verdict([], [row], case_id: "C-01").stale
    end
  end

  # --- real cases ---------------------------------------------------------------

  @tag tenant: true
  test "real cases through the real router (C-03, C-05, C-21..C-28)", ctx do
    c27(ctx)
    c24(ctx)
    c22(ctx)
    c21(ctx)
    c03(ctx)
    c05(ctx)
    c23(ctx)
    c26(ctx)
    c28(ctx)
  end

  # The real cases share one tenant: provisioning a tenant dominates the cost.
  defp c27(ctx) do
    c = G.new("C-27", :token)
    hdrs = [{"authorization", c.value}, {"x-tenant-slug", ctx.tenant.tenant.slug}]
    r1 = request(:get, "/api/v1/instances", "", hdrs)
    r2 = request(:get, "/api/v1/no-such-g04-path", "", hdrs)
    assert_status(r1, [401, 403, 404])
    assert_status(r2, [401, 403, 404])
    assert_clean(run_case(ctx, c, [r1, r2]))
  end

  # C-24/C-25: the ambient header and cookie canaries ride on every request of
  # this test (see `request/4`). The entry condition is a 200 on a real route,
  # then a problem report is filed (the platform tenant pinned to this tenant).
  defp c24(ctx) do
    r = request(:get, "/api/v1/instances", "", auth(ctx)) |> assert_status(200)
    [c24, c25] = ambient_canaries()
    assert_clean(verdict_items(response_items(r) ++ G.drain_sink(ctx.sink), [c24, c25], ctx.rows))

    Letflow.Support.PlatformTenantFixture.pin!(ctx.tenant.tenant_id)

    rep =
      json_request(
        :post,
        "/api/v1/me/problem-reports",
        %{"consent" => true, "text" => "g04 probe report"},
        auth(ctx)
      )
      |> assert_status(201)

    assert_clean(run_case(ctx, c24, [rep], authorised: true))
  end

  defp c22(ctx) do
    c = G.new("C-22", :name)

    rs =
      for seg <- [
            c.core,
            URI.encode_www_form(c.value),
            URI.encode_www_form(URI.encode_www_form(c.value))
          ],
          path <- ["/api/v1/instances/", "/api/v1/identity/users/"] do
        r = request(:get, path <> seg, "", auth(ctx))
        assert_status(r, [400, 404, 422])
      end

    assert_clean(run_case(ctx, c, rs))
  end

  # C-21: the list answers 200 (entry condition). The canary is also stored as a
  # user (C-03 shape) so a list can echo it: that hit is E-01 only for the
  # authorised caller; the `q` echo itself must stay clean.
  defp c21(ctx) do
    c = G.new("C-21", :email)

    rs =
      for q <- [
            c.value,
            URI.encode_www_form(c.value),
            URI.encode_www_form(URI.encode_www_form(c.value))
          ],
          path <- ["/api/v1/instances", "/api/v1/identity/users"] do
        request(:get, path <> "?q=" <> URI.encode_www_form(q), "", auth(ctx))
        |> assert_status(200)
      end

    assert_clean(run_case(ctx, c, rs))
  end

  # C-03: create a user with the canary email and name, read it back as the
  # authorised caller. Hits: E-01 (2xx body), E-03 (audit before/after). Any
  # other surface (logs, headers, other audit columns, other tables) must be clean.
  defp c03(ctx) do
    c = G.new("C-03", :email)
    n = G.new("C-03", :name)

    created =
      json_request(
        :post,
        "/api/v1/identity/users",
        %{"username" => "g04-" <> c.core, "display_name" => n.value, "email" => c.value},
        auth(ctx)
      )
      |> assert_status(201)

    id = Jason.decode!(created.resp_body)["id"]
    read = request(:get, "/api/v1/identity/users/" <> id, "", auth(ctx)) |> assert_status(200)

    items =
      Enum.flat_map([created, read], &response_items(&1, authorised: true)) ++
        G.drain_sink(ctx.sink) ++ database_items(ctx)

    hits = G.scan(items, c) ++ G.scan(items, n)
    v = G.verdict(hits, ctx.rows, case_id: "C-03")

    # the users table holds the record by design (its home); it is the only
    # S*:users hit the case may have. Everything else must be excused or absent.
    {home, rest} = Enum.split_with(v.unlisted, &(&1.surface == "S*:users"))
    assert home != [], "the canary was not stored: the case did not reach the write"
    assert rest == [], "G-04 leak(s): #{inspect(rest, pretty: true)}"
    assert v.excused != []
  end

  # C-05: unauthenticated signup; the answer must not echo the address.
  defp c05(ctx) do
    c = G.new("C-05", :email)
    previous = Application.get_env(:letflow, Letflow.Signup)
    Application.put_env(:letflow, Letflow.Signup, Keyword.put(previous || [], :enabled, true))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:letflow, Letflow.Signup, previous),
        else: Application.delete_env(:letflow, Letflow.Signup)
    end)

    r =
      json_request(
        :post,
        "/api/signup",
        %{"email" => c.value, "slug" => "g04-" <> String.slice(c.core, 0, 10), "name" => "g04"},
        []
      )

    assert_status(r, [202, 422, 429, 503])
    items = response_items(r) ++ G.drain_sink(ctx.sink) ++ database_items(ctx)
    v = G.verdict(G.scan(items, c), ctx.rows, case_id: "C-05")
    # signup_requests keeps the request until it is verified: that table is the value's home
    rest = Enum.reject(v.unlisted, &(&1.surface == "S*:signup_requests"))
    assert rest == [], "G-04 leak(s): #{inspect(rest, pretty: true)}"
  end

  # C-23: base64 forms arrive as a cursor and as a bearer token payload; both are refused
  # and write nothing (the S* catch-all runs).
  defp c23(ctx) do
    c = G.new("C-23", :token)
    b64 = Base.url_encode64(c.value, padding: false)

    r1 =
      request(:get, "/api/v1/identity/users?cursor=U:" <> b64, "", auth(ctx))
      |> assert_status([200, 400, 422])

    r2 =
      request(:get, "/api/v1/instances", "", [
        {"authorization", "Bearer " <> b64 <> "." <> b64},
        {"x-tenant-slug", ctx.tenant.tenant.slug}
      ])
      |> assert_status([401, 403])

    assert_clean(run_case(ctx, c, [r1, r2]))
  end

  # C-28 (S12): a real raise under /api/v1 with the canary in the path and the query, forced
  # as test/letflow/error_capture_test.exs EC-2 does (drop the tenant's groups table). The
  # raise text (S3), the logs (S4), the capture tables and the error_groups rows (S12/S*)
  # must hold no canary. Runs LAST: it drops a table of the shared tenant.
  defp c28(ctx) do
    previous = Application.get_env(:letflow, :error_capture, [])

    Application.put_env(:letflow, :error_capture, Keyword.put(previous, :enabled, true))
    on_exit(fn -> Application.put_env(:letflow, :error_capture, previous) end)

    for t <- [Letflow.ErrorCapture.main_table(), Letflow.ErrorCapture.samples_table()],
        do: :ets.delete_all_objects(t)

    c = G.new("C-28", :name)
    Repo.query!(~s|DROP TABLE "#{ctx.tenant.schema_name}".groups CASCADE|)

    conn =
      Plug.Test.conn(
        :get,
        "/api/v1/identity/groups/#{c.core}/members?n=#{URI.encode_www_form(c.value)}"
      )

    conn =
      Enum.reduce(auth(ctx) ++ ambient_headers(), conn, fn {k, v}, acc ->
        Plug.Conn.put_req_header(acc, k, v)
      end)

    error = assert_raise(Plug.Conn.WrapperError, fn -> call(conn) end)
    assert :ok = Letflow.ErrorCapture.Buffer.flush()

    ets =
      for t <- [Letflow.ErrorCapture.main_table(), Letflow.ErrorCapture.samples_table()] do
        {"S12", "ets #{t}", "any", inspect(:ets.tab2list(t), limit: :infinity)}
      end

    items =
      [{"S3", "raised", "raw_body", Exception.message(error)}] ++
        ets ++ G.drain_sink(ctx.sink) ++ database_items(ctx)

    assert_clean(verdict_items(items, [c | ambient_canaries()], ctx.rows))

    # the capture really ran: a group row exists in the pinned platform schema
    assert Repo.aggregate(Letflow.ErrorCapture.Group, :count, prefix: ctx.tenant.schema_name) >= 1
  end

  defp c26(ctx) do
    c = G.new("C-26", :name)
    body = "name=" <> URI.encode_www_form(c.value)

    conn =
      Plug.Test.conn(:post, "/api/v1/instances", body)
      |> then(fn conn ->
        Enum.reduce(
          auth(ctx) ++ [{"content-type", "application/x-www-form-urlencoded"}],
          conn,
          fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end
        )
      end)

    # The test adapter raises Plug.Parsers.UnsupportedMediaTypeError (the
    # endpoint renders it as 415); the shared dispatch records both.
    %{raised: raised, response: response} =
      Letflow.Support.G13Matrix.dispatch(conn, Letflow.Router)

    assert match?(%Plug.Conn.WrapperError{}, raised) or
             (response != nil and elem(response, 0) in [400, 415, 422]),
           "urlencoded body was neither refused nor an error: #{inspect(response)}"

    items =
      case response do
        {status, headers, resp_body} ->
          [
            {"S3", "urlencoded -> #{status}", "raw_body", resp_body},
            {"S2", "urlencoded", "resp_headers",
             Enum.map_join(headers, "\n", fn {k, v} -> k <> ": " <> v end)}
          ]

        nil ->
          []
      end

    error_text =
      if raised, do: [{"S3", "raised", "raw_body", Exception.message(raised)}], else: []

    hits =
      G.scan(
        items ++ error_text ++ G.drain_sink(ctx.sink) ++ database_items(ctx),
        c
      )

    assert_clean(G.verdict(hits, ctx.rows, case_id: "C-26"))
  end

  test "the cookie guard: no module in lib/ reads or sets a cookie (design §0, cell I10)" do
    {out, code} =
      System.cmd(
        "git",
        ["grep", "-nE", "fetch_cookies|put_resp_cookie|req_cookies", "--", "lib/"],
        stderr_to_stdout: true
      )

    assert code == 1, "a cookie reader appeared; cell I10 must become P: #{out}"
  end
end
