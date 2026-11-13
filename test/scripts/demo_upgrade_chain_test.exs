Code.require_file("../letflow/modules/stock/stock_fixture.exs", __DIR__)

defmodule Letflow.Scripts.DemoUpgradeChainTest do
  @moduledoc """
  T-1480 / D-108: `scripts/demo_upgrade_chain.sh` APPLIES the module upgrade chain (REQ-768 plan, REQ-770 apply) to
  the demo tenants, through the REAL HTTP path (a Bandit listener serving `Letflow.Router`, the script as a `bash`
  subprocess with `curl`), like `demo_upgrade_check_test.exs`. The previous build is simulated as there (version and
  hash on `tenant_modules` and on the stamps of the module's process definitions). Committed tenant, `async: false`.

  C1 seed, snapshot, age, run the chain, verify equal; C2 run again changes nothing; C3 a module with no upgrade
  path is reported pending (exit 3), nothing applied; C4 DRY_RUN applies nothing; C5 bad input exits 2; C6 a list
  of slugs; C7 static checks. Not covered over HTTP: the password grant (no IdP in the test, same code as the
  check script) and an apply refused with 409 ack_required / a stale plan_hash (needs a fixture module).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo
  alias Letflow.StockFixture, as: S

  @seed "scripts/demo/demo_showroom_seed.sh"
  @check "scripts/demo/demo_upgrade_check.sh"
  @chain "scripts/demo_upgrade_chain.sh"
  @notes "docs/runbooks/demo-upgrade-notes.md"
  @order ~w(org locations catalog_items codes stock assets)

  setup do
    for tool <- ~w(bash curl jq cksum date),
        do: if(System.find_executable(tool) == nil, do: flunk("missing tool #{tool}"))

    {:ok, _} = Application.ensure_all_started(:inets)

    ctx = S.setup_oidc!([:a])
    t = S.tenant!("demo", Map.fetch!(ctx.names, :a))
    pid = start_supervised!({Bandit, plug: Letflow.Router, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    exp = System.system_time(:second) + 3600
    tok = fn sub -> S.token(ctx, :a, ["TENANT_ADMIN"], sub: sub, exp: exp) end

    {:ok,
     ctx: ctx,
     t: t,
     schema: t.schema_name,
     port: port,
     token1: tok.("demo-admin"),
     token2: tok.("demo-admin2"),
     slug: t.tenant.slug,
     tmp: Path.join(System.tmp_dir!(), "t1480-#{System.unique_integer([:positive])}")}
  end

  defp env(c) do
    [
      {"BASE_URL", "http://127.0.0.1:#{c.port}"},
      {"TENANT_SLUG", c.slug},
      {"ACCESS_TOKEN", c.token1}
    ]
  end

  defp seed(c) do
    System.cmd("bash", [@seed],
      env:
        env(c) ++
          [
            {"ACCESS_TOKEN2", c.token2},
            {"ADMIN_USERNAME", "demo-admin"},
            {"ADMIN2_USERNAME", "demo-admin2"}
          ],
      stderr_to_stdout: true
    )
  end

  defp check(c, mode, file),
    do: System.cmd("bash", [@check, mode, file], env: env(c), stderr_to_stdout: true)

  defp chain(c, extra \\ []),
    do: System.cmd("bash", [@chain], env: env(c) ++ extra, stderr_to_stdout: true)

  defp snapshot_file(c) do
    File.mkdir_p!(c.tmp)
    on_exit(fn -> File.rm_rf(c.tmp) end)
    Path.join(c.tmp, "snap.json")
  end

  defp http(c, method, path, body \\ nil) do
    headers = [
      {~c"authorization", ~c"Bearer #{c.token1}"},
      {~c"x-tenant-slug", String.to_charlist(c.slug)}
    ]

    url = ~c"http://127.0.0.1:#{c.port}/api/v1#{path}"

    req =
      if body,
        do: {url, headers, ~c"application/json", Jason.encode!(body)},
        else: {url, headers}

    {:ok, {{_, status, _}, _h, resp}} = :httpc.request(method, req, [], body_format: :binary)
    {status, resp}
  end

  defp installed(c) do
    {200, body} = http(c, :get, "/me/modules")
    ids = for m <- Jason.decode!(body)["installed_modules"], do: m["module_id"]
    Enum.filter(@order, &(&1 in ids)) ++ (ids -- @order)
  end

  # Make every installed module look like an older build installed it: older version, a foreign manifest hash on
  # the row and on the stamps of its process definitions (triggers off for the stamp update, as age!/3 does).
  defp age_all!(schema, modules) do
    for m <- modules do
      hash = String.duplicate("7", 64)
      {:ok, entry} = Letflow.Modules.Catalog.fetch(m)

      # only a module that declares an upgrade window (`min_upgradable_from`, today stock) can be aged by
      # VERSION; the others change by manifest hash at the same version (see the notes, "No upgrade path")
      version = Map.get(entry.manifest(), :min_upgradable_from, entry.manifest().version)

      {1, _} =
        Repo.update_all(
          from(r in TenantModule, where: r.module_id == ^m),
          [set: [version: version, manifest_hash: hash]],
          prefix: schema
        )

      Repo.query!(~s(ALTER TABLE "#{schema}".process_definitions DISABLE TRIGGER USER))

      try do
        Repo.update_all(
          from(d in ProcessDefinition,
            where: d.owner_module == ^m and not is_nil(d.owner_manifest_hash)
          ),
          [set: [owner_manifest_hash: hash]],
          prefix: schema
        )
      after
        Repo.query!(~s(ALTER TABLE "#{schema}".process_definitions ENABLE TRIGGER USER))
      end
    end

    :ok
  end

  # tables the upgrade legitimately adds to (journal, audit, definition versions, events, idempotency)
  @upgrade_tables ~w(tenant_module_upgrades audit_entries entity_definitions process_definitions
                     entity_definition_versions event_store events event_idempotency tenant_modules
                     artifact_versions artifacts)

  defp counts(schema) do
    %{rows: tables} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_type = 'BASE TABLE' ORDER BY 1",
        [schema]
      )

    for [name] <- tables, name not in @upgrade_tables, into: %{} do
      %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}"."#{name}"|)
      {name, n}
    end
  end

  defp ledger(schema) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT e.cause, count(DISTINCT e.id), sum(l.quantity)::text, sum(abs(l.quantity))::text FROM "#{schema}".ledger_entry e JOIN "#{schema}".ledger_leg l ON l.entry_id = e.id GROUP BY e.cause ORDER BY e.cause|
      )

    rows
  end

  defp seeded!(c) do
    {out, 0} = seed(c)
    assert out =~ "== done", out
  end

  defp versions(c, schema) do
    _ = c

    Repo.all(
      from(r in TenantModule,
        select: {r.module_id, r.version, r.manifest_hash},
        order_by: r.module_id
      ),
      prefix: schema
    )
  end

  @tag timeout: 600_000
  test "C1 aged tenant: the chain applies every module, data equal, verify exits 0", c do
    seeded!(c)
    modules = installed(c)
    assert "stock" in modules and "org" in modules
    snap = snapshot_file(c)
    {_, 0} = check(c, "snapshot", snap)
    before_counts = counts(c.schema)
    before_ledger = ledger(c.schema)
    age_all!(c.schema, modules)

    {out, code} = chain(c)
    assert code == 0, out
    for m <- modules, do: assert(out =~ ~r/^applied #{c.slug}\/#{m}: /m, out)
    assert out =~ "RESULT: every module"
    refute out =~ "DIFF"
    refute out =~ c.token1
    refute out =~ "ack_destructive"

    for m <- modules do
      {:ok, entry} = Letflow.Modules.Catalog.fetch(m)
      {:ok, hash} = Letflow.Modules.Catalog.manifest_hash(m)
      row = Repo.get_by!(TenantModule, [module_id: m], prefix: c.schema)
      assert row.version == entry.manifest().version
      assert row.manifest_hash == hash
    end

    assert counts(c.schema) == before_counts
    assert ledger(c.schema) == before_ledger
    {vout, vcode} = check(c, "verify", snap)
    assert vcode == 0, vout
    assert vout =~ "RESULT: data equal, upgrade chain complete"
  end

  @tag timeout: 600_000
  test "C2 a second run is idempotent: only ok lines, exit 0, nothing changes", c do
    seeded!(c)
    modules = installed(c)
    age_all!(c.schema, modules)
    {_, 0} = chain(c)
    rows = versions(c, c.schema)
    before = counts(c.schema)

    {out, code} = chain(c)
    assert code == 0, out
    for m <- modules, do: assert(out =~ ~r/^ok      #{c.slug}\/#{m}: up_to_date/m, out)
    refute out =~ "applied"
    assert versions(c, c.schema) == rows
    assert counts(c.schema) == before
  end

  @tag timeout: 600_000
  test "C3 a module with no upgrade path (org aged below its window) is pending, exit 3, nothing applied",
       c do
    seeded!(c)

    {1, _} =
      Repo.update_all(
        from(r in TenantModule, where: r.module_id == "org"),
        [set: [version: "0.0.5", manifest_hash: String.duplicate("5", 64)]],
        prefix: c.schema
      )

    before = counts(c.schema)
    {out, code} = chain(c)
    assert code == 3, out
    assert out =~ ~r/^pending #{c.slug}\/org: 0\.0\.5 -> .*path available: false/m, out
    assert out =~ ~r/^ok      #{c.slug}\/stock: /m, out
    refute out =~ "DIFF"
    refute out =~ "applied"
    assert Repo.get_by!(TenantModule, [module_id: "org"], prefix: c.schema).version == "0.0.5"
    assert counts(c.schema) == before
  end

  @tag timeout: 600_000
  test "C4 DRY_RUN plans only: would apply lines, exit 3, rows unchanged", c do
    seeded!(c)
    modules = installed(c)
    age_all!(c.schema, modules)
    rows = versions(c, c.schema)

    {out, code} = chain(c, [{"DRY_RUN", "1"}])
    assert code == 3, out
    assert out =~ ~r/^would apply #{c.slug}\/stock: /m, out
    refute out =~ "applied"
    assert versions(c, c.schema) == rows
  end

  test "C5 bad input exits 2 before any request; an unusable token stops with exit 4", c do
    run = fn env -> System.cmd("bash", [@chain], env: env, stderr_to_stdout: true) end

    {out, code} = run.([{"ACCESS_TOKEN", "x"}])
    assert code == 2 and out =~ "BASE_URL"

    {out, code} = run.([{"BASE_URL", "http://127.0.0.1:#{c.port}"}])
    assert code == 2 and out =~ "no sign-in"

    {out, code} =
      run.([
        {"BASE_URL", "http://127.0.0.1:#{c.port}"},
        {"ADMIN_USERNAME", "u"},
        {"ADMIN_PASSWORD", "p"}
      ])

    assert code == 2 and out =~ "no sign-in"

    {out, code} = run.(env(c) |> List.keystore("TENANT_SLUG", 0, {"TENANT_SLUG", "a b;c"}))
    assert code == 2 and out =~ "TENANT_SLUG"

    {out, code} =
      run.(env(c) |> List.keystore("ACCESS_TOKEN", 0, {"ACCESS_TOKEN", "not-a-token"}))

    assert code == 4, out
    assert out =~ "STOP:"
  end

  @tag timeout: 600_000
  test "C6 a list of slugs: each tenant gets its lines; the same demo tenant twice stays idempotent",
       c do
    seeded!(c)
    modules = installed(c)
    age_all!(c.schema, modules)

    {out, code} = chain(c, [{"TENANT_SLUG", "#{c.slug},#{c.slug}"}])
    assert code == 0, out
    assert out =~ ~r/^applied #{c.slug}\/stock: /m
    assert out =~ ~r/^ok      #{c.slug}\/stock: /m
  end

  test "C7 no secrets in the script, set +x present, never sends ack_destructive, notes name the script" do
    text = File.read!(@chain)
    refute Regex.match?(~r/Bearer [A-Za-z0-9._-]{12,}/, text)
    refute Regex.match?(~r/PASSWORD=['"]?[A-Za-z0-9]/, text)
    refute text =~ "ack_destructive\":"
    refute Regex.match?(~r/(jq -nc|--arg)[^\n]*ack_destructive/, text)
    assert text =~ "set +x"
    mails = Regex.scan(~r/[A-Za-z0-9._-]+@([A-Za-z0-9-]+\.[A-Za-z][A-Za-z.]+)/, text)
    assert Enum.all?(mails, fn [_, d] -> d in ["example.com", "example.org"] end)
    notes = File.read!(@notes)
    assert notes =~ "scripts/demo_upgrade_chain.sh"
    refute Regex.match?(~r/Bearer [A-Za-z0-9._-]{12,}/, notes)
  end
end
