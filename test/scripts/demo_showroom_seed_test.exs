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
