Code.require_file("../letflow/modules/stock/stock_fixture.exs", __DIR__)

defmodule Letflow.Scripts.DemoShowroomSeedTest do
  @moduledoc """
  T-1470 / D-108: `scripts/demo/demo_showroom_seed.sh` through the REAL HTTP path (D-098). A Bandit listener
  serves `Letflow.Router`; the script runs as a subprocess with `curl` against it, signed in with minted OIDC
  tokens (the Keycloak password grant cannot run in ExUnit; its code is a copy of the e2e seed's `get_token`).
  The tenant is committed (Sandbox `:auto`), `async: false`.

  D1 runs, D2 data of every kind, D3 second run changes nothing, D4 a partial first run completes, D5 no
  secrets printed, D6 no secrets in the repo, D7 unknown tenant stops, D8 Inv-* print reachable, D9 bad input.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo
  alias Letflow.StockFixture, as: S

  @script "scripts/demo/demo_showroom_seed.sh"
  @runbook "docs/runbooks/demo-showroom.md"
  @canary "CANARY-pw-9f3a7c"

  setup do
    for tool <- ~w(bash curl jq cksum date), do: tool_or_skip(tool)
    {:ok, _} = Application.ensure_all_started(:inets)

    ctx = S.setup_oidc!([:a, :nobody])
    t = S.tenant!("demo", Map.fetch!(ctx.names, :a))
    pid = start_supervised!({Bandit, plug: Letflow.Router, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    exp = System.system_time(:second) + 3600

    tok = fn sub -> S.token(ctx, :a, ["TENANT_ADMIN"], sub: sub, exp: exp) end

    {:ok,
     ctx: ctx,
     t: t,
     port: port,
     token1: tok.("demo-admin"),
     token2: tok.("demo-admin2"),
     token_al: tok.("admin-login"),
     token_ul: tok.("user-login"),
     token_smoke: tok.("demo-smoke"),
     stranger: S.token(ctx, :nobody, ["TENANT_ADMIN"], sub: "stranger", exp: exp),
     slug: t.tenant.slug}
  end

  defp tool_or_skip(tool) do
    if System.find_executable(tool) == nil,
      do: flunk("missing tool #{tool}: the seed script needs it")
  end

  defp run(c, extra \\ []) do
    env =
      [
        {"BASE_URL", "http://127.0.0.1:#{c.port}"},
        {"TENANT_SLUG", c.slug},
        {"ACCESS_TOKEN", c.token1},
        {"ACCESS_TOKEN2", c.token2},
        {"ADMIN_USERNAME", "demo-admin"},
        {"ADMIN2_USERNAME", "demo-admin2"},
        {"ADMIN2_PASSWORD", @canary}
      ] ++ extra

    System.cmd("bash", [@script], env: env, stderr_to_stdout: true)
  end

  defp snapshot(schema) do
    %{rows: tables} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_type = 'BASE TABLE' ORDER BY 1",
        [schema]
      )

    Map.new(tables, fn [name] ->
      %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}"."#{name}"|)
      {name, n}
    end)
  end

  defp causes(schema) do
    %{rows: rows} =
      Repo.query!(~s|SELECT cause, count(*) FROM "#{schema}".ledger_entry GROUP BY cause|)

    Map.new(rows, fn [c, n] -> {c, n} end)
  end

  defp records(schema, type) do
    %{rows: [[n]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{schema}".entity_record_latest WHERE entity_type = $1 AND NOT deleted|,
        [type]
      )

    n
  end

  defp get(c, path, token \\ nil) do
    headers = [
      {~c"authorization", ~c"Bearer #{token || c.token1}"},
      {~c"x-tenant-slug", String.to_charlist(c.slug)}
    ]

    {:ok, {{_, status, _}, resp_headers, body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{c.port}/api/v1#{path}", headers}, [],
        body_format: :binary
      )

    {status, resp_headers, body}
  end

  @tag timeout: 600_000
  test "D1 D2 D3 D5 D8: one run makes everything, the second changes nothing", c do
    {out1, 0} = run(c)
    assert out1 =~ "== done", out1

    schema = c.t.schema_name

    # D2: data of every kind
    assert records(schema, "catalog_item") >= 10
    assert records(schema, "location_node") >= 6
    ledger = causes(schema)

    for cause <- ~w(receipt issue transfer hand_over return write_off opening) do
      assert Map.get(ledger, cause, 0) >= 1,
             "no ledger entry of cause #{cause}: #{inspect(ledger)}\n#{out1}"
    end

    {200, _, counts} = get(c, "/modules/stock/counts?limit=50")
    assert [%{"id" => count_id, "status" => "signed"} | _] = Jason.decode!(counts)["rows"]

    if out1 =~ "skip assets" do
      flunk("assets step skipped on this build: #{out1}")
    else
      assert records(schema, "assets_card") == 6

      for cause <- ~w(commission handover writeoff),
          do: assert(Map.get(ledger, cause, 0) >= 1, out1)
    end

    # D8: the official forms print through the same listener
    {200, h1, pdf1} =
      get(c, "/modules/stock/counts/#{count_id}/print/sheet?form=inv10&lang=ru&format=pdf")

    assert pdf1 =~ "%PDF" and content_type(h1) =~ "pdf"

    {200, h2, pdf2} =
      get(c, "/modules/stock/counts/#{count_id}/print/differences?form=inv18&lang=ru&format=pdf")

    assert pdf2 =~ "%PDF" and content_type(h2) =~ "pdf"

    # D5: no secrets printed; the login (without a password) is printed
    refute out1 =~ c.token1
    refute out1 =~ c.token2
    refute out1 =~ @canary
    assert out1 =~ "demo-admin"

    # D3: the second run changes nothing
    before = snapshot(schema)
    {out2, 0} = run(c)
    assert out2 =~ "== done", out2
    assert snapshot(schema) == before, out2
    refute out2 =~ "ok   receipt receipt-1 issued", out2
    refute out2 =~ "(task completed)", out2
    refute out2 =~ @canary
  end

  @tag timeout: 600_000
  test "D4: a partial first run (masters only) is completed by the next run, then nothing changes",
       c do
    {out0, 0} = run(c, [{"SKIP_DOCS", "1"}])
    assert out0 =~ "SKIP_DOCS=1", out0
    schema = c.t.schema_name
    assert causes(schema) == %{}

    {out1, 0} = run(c)
    assert out1 =~ "== done", out1
    ledger = causes(schema)

    for cause <- ~w(issue transfer hand_over return write_off opening),
        do: assert(Map.get(ledger, cause) == 1, inspect(ledger))

    assert Map.get(ledger, "receipt") == 2

    before = snapshot(schema)
    {out2, 0} = run(c)
    assert out2 =~ "== done", out2
    assert snapshot(schema) == before
  end

  test "D7: a token of a realm with no tenant stops with a clear line and writes nothing", c do
    {out, code} =
      run(c, [
        {"ACCESS_TOKEN", c.stranger},
        {"ACCESS_TOKEN2", ""},
        {"ADMIN2_USERNAME", ""},
        {"TENANT_SLUG", "no-such-tenant"}
      ])

    assert code == 1, out
    assert out =~ "STOP:" and out =~ "no-such-tenant", out
    assert records(c.t.schema_name, "catalog_item") == 0
  end

  defp signin_logins(c, tokens) do
    for t <- tokens, do: {200, _, _} = get(c, "/me/modules", t)
  end

  defp employee_users(schema) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT field_values->>'code', field_values->>'user_id' FROM "#{schema}".entity_record_latest WHERE entity_type = 'org_employee' AND NOT deleted|
      )

    Map.new(rows, fn [code, uid] -> {code, uid} end)
  end

  @logins [{"ADMIN_LOGIN_USERNAME", "admin-login"}, {"USER_LOGIN_USERNAME", "user-login"}]

  @tag timeout: 600_000
  test "L1 L2: admin-login and user-login are linked to E005 and E004, demo-smoke stays unlinked, repeatable",
       c do
    signin_logins(c, [c.token_al, c.token_ul, c.token_smoke])
    schema = c.t.schema_name

    {out, 0} = run(c, @logins)
    assert out =~ "ok   admin-login linked to a user account", out
    assert out =~ "ok   user-login linked to a user account", out
    refute out =~ "STOP", out

    users = employee_users(schema)
    for code <- ~w(DEMO-E001 DEMO-E003 DEMO-E004 DEMO-E005), do: assert(users[code], code)
    assert users |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length() == 4

    {200, _, body} = get(c, "/identity/users?search=demo-smoke&page_size=50")
    smoke = Enum.find(Jason.decode!(body)["items"], &(&1["username"] == "demo-smoke"))
    refute Enum.any?(Map.values(users), &(&1 == smoke["id"]))

    before = snapshot(schema)
    {out2, 0} = run(c, @logins)
    refute out2 =~ "STOP", out2
    assert snapshot(schema) == before
    assert employee_users(schema) == users
  end

  test "L3: without the variables E004 and E005 stay unlinked and the skip is logged", c do
    {out, 0} = run(c)
    assert out =~ "skip link admin-login: no username given", out
    assert out =~ "skip link user-login: no username given", out
    users = employee_users(c.t.schema_name)
    assert users["DEMO-E004"] == nil and users["DEMO-E005"] == nil
  end

  test "L4: logins that never signed in are skipped with a note and nothing is linked", c do
    {out, 0} = run(c, @logins)
    assert out =~ "no account admin-login yet", out
    assert out =~ "no account user-login yet", out
    users = employee_users(c.t.schema_name)
    assert users["DEMO-E004"] == nil and users["DEMO-E005"] == nil
  end

  test "L5: a login already linked to another employee is a note, not a STOP", c do
    signin_logins(c, [c.token_ul])
    {_, 0} = run(c)
    {200, _, body} = get(c, "/identity/users?search=user-login&page_size=50")
    uid = Enum.find(Jason.decode!(body)["items"], &(&1["username"] == "user-login"))["id"]

    {:ok, {{_, 200, _}, _, _}} =
      :httpc.request(
        :patch,
        {String.to_charlist(
           "http://127.0.0.1:#{c.port}/api/v1/modules/org/employees/#{employee_id(c, "DEMO-E002")}"
         ),
         [
           {~c"authorization", ~c"Bearer #{c.token1}"},
           {~c"x-tenant-slug", String.to_charlist(c.slug)}
         ], ~c"application/json", Jason.encode!(%{user_id: uid, idempotency_key: "l5-hand"})},
        [],
        body_format: :binary
      )

    {out, 0} = run(c, [{"USER_LOGIN_USERNAME", "user-login"}])
    assert out =~ "note link user-login", out
    refute out =~ "STOP", out
  end

  defp employee_id(c, code) do
    %{rows: [[id]]} =
      Repo.query!(
        ~s|SELECT record_id::text FROM "#{c.t.schema_name}".entity_record_latest WHERE entity_type = 'org_employee' AND field_values->>'code' = $1|,
        [code]
      )

    id
  end

  test "D9b: a bad or clashing login name exits 2 and names the variable", c do
    {out, code} = run(c, [{"ADMIN_LOGIN_USERNAME", "bad name"}])
    assert code == 2 and out =~ "ADMIN_LOGIN_USERNAME"
    {out, code} = run(c, [{"USER_LOGIN_USERNAME", "demo-admin2"}])
    assert code == 2 and out =~ "USER_LOGIN_USERNAME"
  end

  test "D9: bad input exits 2 before any request", c do
    {out, code} = run(c, [{"DEMO_TAG", "Bad Tag"}])
    assert code == 2
    assert out =~ "DEMO_TAG"

    {out, code} = run(c, [{"BASE_URL", ""}])
    assert code == 2 and out =~ "BASE_URL"
  end

  test "D6: no secrets and no real addresses in the script or the README" do
    for path <- [@script, @runbook] do
      text = File.read!(path)
      refute Regex.match?(~r/Bearer [A-Za-z0-9._-]{12,}/, text), "#{path}: a bearer value"
      refute Regex.match?(~r/PASSWORD=['"]?[A-Za-z0-9]/, text), "#{path}: a password value"

      mails = Regex.scan(~r/[A-Za-z0-9._-]+@([A-Za-z0-9-]+\.[A-Za-z][A-Za-z.]+)/, text)

      assert Enum.all?(mails, fn [_, domain] -> domain in ["example.com", "example.org"] end),
             "#{path}: #{inspect(mails)}"
    end

    assert File.read!(@script) =~ "set +x"
    assert File.read!(@runbook) =~ "## Reset"
  end

  defp content_type(headers) do
    Enum.find_value(headers, "", fn {k, v} ->
      if to_string(k) == "content-type", do: to_string(v)
    end)
  end
end
