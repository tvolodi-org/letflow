Code.require_file("../letflow/modules/stock/stock_fixture.exs", __DIR__)
Code.require_file("../letflow/modules/stock/posting_fixture.exs", __DIR__)

defmodule Letflow.Scripts.DemoUpgradeCheckTest do
  @moduledoc """
  T-1471 / D-108: the showroom demo tenant keeps its data across the module upgrade chain (REQ-768 plan, REQ-770
  apply, REQ-771 409 guard, REQ-772 upgrade on deploy), through the REAL HTTP path: a Bandit listener serves
  `Letflow.Router`; `scripts/demo/demo_showroom_seed.sh` and `scripts/demo/demo_upgrade_check.sh` run as
  subprocesses with `curl`; plan and apply are requested over HTTP (`:httpc`) with a minted admin token.
  One checkout holds one build, so "the previous manifest versions" are simulated as `upgrade_http_test.exs`
  does (version and hash on `tenant_modules`, the stamp on the module's process definitions); see
  `docs/runbooks/demo-upgrade-notes.md`. Committed tenant (Sandbox `:auto`), `async: false`.

  U1 seed, snapshot, age, plan + apply every installed module, verify equal; U2 verify before the apply reports
  pending (exit 3); U3 the seed script run again after the upgrade changes nothing; U4 a tampered ledger row or
  record is found (exit 1); U5 upgrade on deploy (flag on) leaves the data equal; U6 a task completion in the
  window answers 409 upgrade_required; U7 static checks and bad input; U8 a module with no declared upgrade window is refused and nothing changes.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo
  alias Letflow.StockFixture, as: S

  @seed "scripts/demo/demo_showroom_seed.sh"
  @check "scripts/demo/demo_upgrade_check.sh"
  @notes "docs/runbooks/demo-upgrade-notes.md"
  @runbook "docs/runbooks/demo-showroom.md"
  # dependency order of the demo's modules; only the installed ones are used
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
     tmp: Path.join(System.tmp_dir!(), "t1471-#{System.unique_integer([:positive])}")}
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

  defp check(c, mode, file, extra \\ []),
    do: System.cmd("bash", [@check, mode, file], env: env(c) ++ extra, stderr_to_stdout: true)

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

  # plan then apply through the routes; returns [{module, plan_status, apply_status_or_nil, plan_body}]
  defp upgrade_all(c, modules) do
    for m <- modules do
      {ps, pbody} = http(c, :post, "/tenant/modules/#{m}/upgrade/plan", %{})
      plan = Jason.decode!(pbody)

      if ps == 200 and plan["up_to_date"] == false and is_binary(plan["plan_hash"]) do
        {as, abody} =
          http(c, :post, "/tenant/modules/#{m}/upgrade", %{
            "plan_hash" => plan["plan_hash"],
            "rationale" => "T-1471 demo upgrade chain check"
          })

        {m, ps, as, Jason.decode!(abody)}
      else
        {m, ps, nil, plan}
      end
    end
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
    out
  end

  @tag timeout: 600_000
  test "U1 seed, snapshot, age, plan + apply each module, verify: every record, document and balance equal",
       c do
    seeded!(c)
    modules = installed(c)
    assert "stock" in modules and "org" in modules
    snap = snapshot_file(c)

    {out0, 0} = check(c, "snapshot", snap)
    assert File.exists?(snap)
    refute out0 =~ c.token1

    before_counts = counts(c.schema)
    before_ledger = ledger(c.schema)
    assert before_ledger != []

    age_all!(c.schema, modules)
    results = upgrade_all(c, modules)

    for {m, ps, as, body} <- results do
      assert ps == 200, "plan of #{m}: #{inspect(body)}"
      # a module whose plan the apply refuses is a finding for the notes, not a weaker assertion
      assert as == 200, "apply of #{m}: HTTP #{inspect(as)} #{inspect(body)}"
      assert body["state"] == "done"
    end

    # the rows are at the compiled version and hash
    for m <- modules do
      {:ok, entry} = Letflow.Modules.Catalog.fetch(m)
      {:ok, hash} = Letflow.Modules.Catalog.manifest_hash(m)
      row = Repo.get_by!(TenantModule, [module_id: m], prefix: c.schema)
      assert row.version == entry.manifest().version
      assert row.manifest_hash == hash
    end

    assert counts(c.schema) == before_counts
    assert ledger(c.schema) == before_ledger

    {out, code} = check(c, "verify", snap)
    assert code == 0, out
    assert out =~ "RESULT: data equal, upgrade chain complete"
    assert out =~ "equal stock balances"
    assert out =~ "equal print inv10: 200 pdf"
    refute out =~ "DIFF"
    refute out =~ c.token1
  end

  @tag timeout: 600_000
  test "U2 before the apply the check names the pending modules (exit 3), data still equal", c do
    seeded!(c)
    modules = installed(c)
    snap = snapshot_file(c)
    {_, 0} = check(c, "snapshot", snap)
    age_all!(c.schema, modules)

    {out, code} = check(c, "verify", snap)
    assert code == 3, out
    for m <- modules, do: assert(out =~ "pending #{m}: pending ")
    refute out =~ "DIFF"
  end

  @tag timeout: 600_000
  test "U3 the seed script run again after the upgrade exits 0 and changes no table count", c do
    seeded!(c)
    modules = installed(c)
    age_all!(c.schema, modules)
    assert Enum.all?(upgrade_all(c, modules), fn {_, _, as, _} -> as == 200 end)

    before = counts(c.schema)
    {out, 0} = seed(c)
    assert out =~ "== done", out
    assert counts(c.schema) == before
  end

  @tag timeout: 600_000
  test "U4 a deleted ledger row or a changed record is found by the check (exit 1)", c do
    seeded!(c)
    snap = snapshot_file(c)
    {_, 0} = check(c, "snapshot", snap)

    {out_ok, 0} = check(c, "verify", snap)
    assert out_ok =~ "RESULT: data equal"

    %{rows: [[id]]} =
      Repo.query!(
        ~s|SELECT id FROM "#{c.schema}".ledger_leg ORDER BY posting_seq DESC, leg_no LIMIT 1|
      )

    Repo.query!(~s|ALTER TABLE "#{c.schema}".ledger_leg DISABLE TRIGGER USER|)

    try do
      Repo.query!(
        ~s|UPDATE "#{c.schema}".ledger_leg SET quantity = quantity + 1 WHERE id = $1|,
        [id]
      )
    after
      Repo.query!(~s|ALTER TABLE "#{c.schema}".ledger_leg ENABLE TRIGGER USER|)
    end

    {out, code} = check(c, "verify", snap)
    assert code == 1, out
    assert out =~ ~r/DIFF  stock (balances|movements)/
    assert out =~ "RESULT: data differs"
  end

  @tag timeout: 600_000
  test "U5 upgrade on deploy: the boot run leaves the data equal; outcomes are listed", c do
    seeded!(c)
    modules = installed(c)
    snap = snapshot_file(c)
    {_, 0} = check(c, "snapshot", snap)
    age_all!(c.schema, modules)

    previous = Application.get_env(:letflow, :module_upgrade_on_boot, false)
    Application.put_env(:letflow, :module_upgrade_on_boot, true)

    on_exit(fn -> Application.put_env(:letflow, :module_upgrade_on_boot, previous) end)

    assert Letflow.ModuleUpgrade.Boot.flag_on?()
    # the boot hook runs synchronously inside start_link/1 and returns :ignore
    assert :ignore = Letflow.ModuleUpgrade.Boot.start_link([])

    outcomes = Letflow.ModuleUpgrade.Boot.list_outcomes()
    mine = Enum.filter(outcomes, &(&1.tenant_id == c.t.tenant.id))
    assert mine != [], "boot run left no outcome for the demo tenant: #{inspect(outcomes)}"
    assert Enum.all?(mine, &(&1.outcome in [:upgraded, :failed, :left_for_admin]))

    # data is equal whatever the boot run did; a module left to an administrator keeps the check at exit 3
    {out, code} = check(c, "verify", snap)
    refute out =~ "DIFF", out
    assert code in [0, 3], out

    left = for o <- mine, o.outcome != :upgraded, do: o.module_id
    assert Enum.all?(upgrade_all(c, Enum.uniq(left)), fn {_, _, as, _} -> as in [nil, 200] end)

    {out2, code2} = check(c, "verify", snap)
    assert code2 == 0, out2
  end

  @tag timeout: 600_000
  test "U8 a module with no declared window (org) aged by version is refused 409 no_upgrade_path, data untouched",
       c do
    seeded!(c)
    snap = snapshot_file(c)
    {_, 0} = check(c, "snapshot", snap)
    before = counts(c.schema)

    {1, _} =
      Repo.update_all(
        from(r in TenantModule, where: r.module_id == "org"),
        [set: [version: "0.2.0", manifest_hash: String.duplicate("5", 64)]],
        prefix: c.schema
      )

    {200, pbody} = http(c, :post, "/tenant/modules/org/upgrade/plan", %{})
    plan = Jason.decode!(pbody)
    assert plan["up_to_date"] == false
    assert plan["upgrade_path_available"] == false
    assert plan["path_error"] == "no_upgrade_path"

    {409, abody} =
      http(c, :post, "/tenant/modules/org/upgrade", %{
        "plan_hash" => plan["plan_hash"] || String.duplicate("0", 64),
        "rationale" => "T-1471 no path"
      })

    assert Jason.decode!(abody)["code"] == "no_upgrade_path"
    assert counts(c.schema) == before

    {out, code} = check(c, "verify", snap)
    assert code == 3, out
    assert out =~ "pending org: pending 0.2.0"
    refute out =~ "DIFF"
  end

  test "U7 no secrets in the script or the notes, set +x present, bad input exits 2", c do
    for path <- [@check, @notes] do
      text = File.read!(path)
      refute Regex.match?(~r/Bearer [A-Za-z0-9._-]{12,}/, text), "#{path}: a bearer value"
      refute Regex.match?(~r/PASSWORD=['"]?[A-Za-z0-9]/, text), "#{path}: a password value"
      mails = Regex.scan(~r/[A-Za-z0-9._-]+@([A-Za-z0-9-]+\.[A-Za-z][A-Za-z.]+)/, text)

      assert Enum.all?(mails, fn [_, d] -> d in ["example.com", "example.org"] end),
             "#{path}: #{inspect(mails)}"
    end

    assert File.read!(@check) =~ "set +x"
    assert File.read!(@runbook) =~ "demo-upgrade-notes.md"

    {out, code} = System.cmd("bash", [@check, "bogus", "x"], env: env(c), stderr_to_stdout: true)
    assert code == 2 and out =~ "usage"

    {out, code} =
      System.cmd("bash", [@check, "verify", "/nonexistent/file"],
        env: env(c),
        stderr_to_stdout: true
      )

    assert code == 2 and out =~ "cannot read"

    {out, code} =
      System.cmd("bash", [@check, "snapshot", "x"],
        env: [{"BASE_URL", ""}],
        stderr_to_stdout: true
      )

    assert code == 2 and out =~ "BASE_URL"
  end
end

defmodule Letflow.Scripts.DemoUpgradeWindowTest do
  @moduledoc """
  T-1471 U6 (REQ-771): while a module is older than the build, a human task whose completion writes the module
  answers 409 `upgrade_required` and posts nothing; after the apply it completes. Own module: the posting fixture
  and the demo fixture each manage their own sandbox cleanup.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo
  alias Letflow.StockPostingFixture, as: P

  @tag timeout: 600_000
  test "U6 REQ-771: in the window a post task is refused 409 upgrade_required, after the apply it completes" do
    pctx = P.setup!([:a, :b])
    doc = P.issue!(pctx)
    task = P.pending_task(pctx, doc["id"], "post")
    age_stock!(pctx.schema)

    claim = post_conn("/api/v1/tasks/#{task.id}/claim", pctx.tok_a, %{})
    assert claim.status == 200

    refused =
      post_conn("/api/v1/tasks/#{task.id}/complete", pctx.tok_a, %{"output_variables" => %{}})

    assert refused.status == 409, refused.resp_body
    assert Jason.decode!(refused.resp_body)["code"] == "upgrade_required"
    assert P.counts(pctx, doc["id"]) == %{entries: %{}, marks: 0}

    plan = post_conn("/api/v1/tenant/modules/stock/upgrade/plan", pctx.tok_a, %{})
    plan_hash = Jason.decode!(plan.resp_body)["plan_hash"]

    applied =
      post_conn("/api/v1/tenant/modules/stock/upgrade", pctx.tok_a, %{
        "plan_hash" => plan_hash,
        "rationale" => "T-1471 window check"
      })

    assert applied.status == 200, applied.resp_body

    done =
      post_conn("/api/v1/tasks/#{task.id}/complete", pctx.tok_a, %{"output_variables" => %{}})

    assert done.status == 200, done.resp_body
  end

  defp age_stock!(schema) do
    {:ok, entry} = Letflow.Modules.Catalog.fetch("stock")
    hash = String.duplicate("7", 64)

    {1, _} =
      Repo.update_all(
        from(r in TenantModule, where: r.module_id == "stock"),
        [set: [version: entry.manifest().min_upgradable_from, manifest_hash: hash]],
        prefix: schema
      )

    Repo.query!(~s(ALTER TABLE "#{schema}".process_definitions DISABLE TRIGGER USER))

    try do
      Repo.update_all(
        from(d in ProcessDefinition,
          where: d.owner_module == "stock" and not is_nil(d.owner_manifest_hash)
        ),
        [set: [owner_manifest_hash: hash]],
        prefix: schema
      )
    after
      Repo.query!(~s(ALTER TABLE "#{schema}".process_definitions ENABLE TRIGGER USER))
    end
  end

  defp post_conn(path, tok, body) do
    Plug.Test.conn(:post, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Letflow.Router.call(Letflow.Router.init([]))
  end
end
