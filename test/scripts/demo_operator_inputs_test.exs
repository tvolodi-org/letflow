Code.require_file("../letflow/modules/stock/stock_fixture.exs", __DIR__)

defmodule Letflow.Scripts.DemoOperatorInputsTest.FakeIdp do
  @moduledoc """
  Stands in for Keycloak's token endpoint (the real one cannot run in ExUnit; same stance as the seed test).
  Serves only `POST /realms/:realm/protocol/openid-connect/token`, tells the test what it saw, and answers
  with the minted token when the password grant fields match.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %Plug.Conn{
          method: "POST",
          path_info: ["realms", realm, "protocol", "openid-connect", "token"]
        } = conn,
        opts
      ) do
    {:ok, body, conn} = read_body(conn)
    form = URI.decode_query(body)
    send(opts[:test_pid], {:idp, realm, form})

    ok? =
      form["grant_type"] == "password" and form["client_id"] == opts[:client_id] and
        form["username"] == opts[:username] and form["password"] == opts[:password]

    conn = put_resp_content_type(conn, "application/json")

    if ok?,
      do: send_resp(conn, 200, Jason.encode!(%{"access_token" => opts[:token]})),
      else: send_resp(conn, 401, Jason.encode!(%{"error" => "invalid_grant"}))
  end

  def call(conn, _opts), do: send_resp(conn, 404, "")
end

defmodule Letflow.Scripts.DemoOperatorInputsTest do
  @moduledoc """
  T-1473 (D-108): the operator inputs for the demo instance. S1-S5 `scripts/demo_smoke_read.sh` through a real
  Letflow listener and a fake token endpoint; C1-C3 `scripts/demo/demo_counts.sh`; R1 the realm files; D1 the
  README; B1 `scripts/demo/demo_platform_bootstrap.sh` with a stub release; E1 its Elixir expression on the test
  database.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo
  alias Letflow.StockFixture, as: S

  @smoke "scripts/demo_smoke_read.sh"
  @counts "scripts/demo/demo_counts.sh"
  @bootstrap "scripts/demo/demo_platform_bootstrap.sh"
  @readme "docs/runbooks/demo-operator-inputs.md"
  @showroom "docs/runbooks/demo-realm/demo-showroom.json"
  @platform "docs/runbooks/demo-realm/demo-platform.json"
  @canary "CANARY-smoke-pw-4c1d"

  defp need_tools!(tools) do
    for tool <- tools,
        System.find_executable(tool) == nil,
        do: flunk("missing tool #{tool}: the demo scripts need it")
  end

  defp scratch! do
    dir = Path.join(System.tmp_dir!(), "t1473-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write!(dir, name, content, mode \\ 0o600) do
    path = Path.join(dir, name)
    File.write!(path, content)
    File.chmod!(path, mode)
    path
  end

  # ---------------------------------------------------------------------------------------------
  # S1..S5: the smoke read over the real HTTP path
  # ---------------------------------------------------------------------------------------------
  describe "demo_smoke_read.sh" do
    setup do
      need_tools!(~w(bash curl jq mktemp))
      {:ok, _} = Application.ensure_all_started(:inets)

      ctx = S.setup_oidc!([:a, :b, :c])
      t = S.tenant!("smk", Map.fetch!(ctx.names, :a))
      empty = S.tenant!("smk0", Map.fetch!(ctx.names, :b), install: false)
      pid = start_supervised!({Bandit, plug: Letflow.Router, port: 0}, id: :router)
      {:ok, {_a, port}} = ThousandIsland.listener_info(pid)
      exp = System.system_time(:second) + 3600
      dir = scratch!()

      {:ok,
       ctx: ctx,
       t: t,
       empty: empty,
       port: port,
       exp: exp,
       dir: dir,
       pwfile: write!(dir, "pw", @canary <> "\n")}
    end

    defp start_idp!(c, token, overrides \\ []) do
      opts =
        Keyword.merge(
          [
            test_pid: self(),
            client_id: "letflow-demo-smoke",
            username: "demo-smoke",
            password: @canary,
            token: token
          ],
          overrides
        )

      pid =
        start_supervised!(
          {Bandit, plug: {Letflow.Scripts.DemoOperatorInputsTest.FakeIdp, opts}, port: 0},
          id: :idp
        )

      {:ok, {_a, port}} = ThousandIsland.listener_info(pid)
      Map.put(c, :idp_port, port)
    end

    defp token(c, name, sub \\ "demo-smoke"),
      do: S.token(c.ctx, name, ["TASK_WORKER"], sub: sub, exp: c.exp)

    defp smoke(c, extra \\ []) do
      env =
        [
          {"BASE_URL", "http://127.0.0.1:#{c.port}"},
          {"KEYCLOAK_URL", "http://127.0.0.1:#{c[:idp_port] || 1}"},
          {"SMOKE_PASSWORD_FILE", c.pwfile},
          {"SMOKE_REALM", "demo-showroom"},
          {"TMPDIR", c.dir}
        ] ++ extra

      System.cmd("bash", [@smoke], env: env, stderr_to_stdout: true)
    end

    @tag timeout: 120_000
    test "S1 happy path: login with the file password, read the module list", c do
      c = start_idp!(c, token(c, :a))
      {out, code} = smoke(c)
      assert code == 0, out
      assert out =~ ~r/^PASS login\+read \/api\/v1\/me\/modules modules=[1-9]\d*$/m

      assert_receive {:idp, "demo-showroom", form}
      assert form["password"] == @canary
      assert form["username"] == "demo-smoke"
    end

    @tag timeout: 120_000
    test "S2 wrong password: FAIL login, exit 1", c do
      c = start_idp!(c, token(c, :a), password: "another-password")
      {out, code} = smoke(c)
      assert code == 1
      assert out =~ "FAIL login: HTTP 401"
      refute out =~ @canary
    end

    @tag timeout: 120_000
    test "S3 bad input exits 2 before any request", c do
      c = start_idp!(c, token(c, :a))
      empty = write!(c.dir, "empty", "")
      multi = write!(c.dir, "multi", "one\ntwo\n")

      for {file, why} <- [
            {empty, "empty"},
            {multi, "multi-line"},
            {Path.join(c.dir, "absent"), "absent"}
          ] do
        {out, code} = smoke(c, [{"SMOKE_PASSWORD_FILE", file}])
        assert code == 2, "#{why}: #{out}"
      end

      {_out, code} = smoke(c, [{"SMOKE_PASSWORD_FILE", ""}])
      assert code == 2
      refute_receive {:idp, _, _}, 200
    end

    @tag timeout: 120_000
    test "S4 unknown realm token and an unmet EXPECT_JQ both fail", c do
      stranger = S.token(c.ctx, :b, ["TASK_WORKER"], sub: "demo-smoke", exp: c.exp)

      # a token of realm b is a real tenant, but with no modules installed: the default filter is unmet
      c1 = start_idp!(c, stranger)
      {out, code} = smoke(c1)
      assert code == 1
      assert out =~ "FAIL read"

      # S7: the slug resolves to a real tenant, so a rejected token stays a failure, not "not seeded"
      bogus = start_idp_again!(c, "not-a-token")
      {out, code} = smoke(bogus, [{"SMOKE_TENANT_SLUG", c.t.tenant.slug}])
      assert code == 1
      assert out =~ "FAIL read: HTTP 401"
    end

    @tag timeout: 120_000
    test "S6 login ok but no tenant for the slug: tenant not seeded yet, exit 3", c do
      # realm :c has a Keycloak user (the fake IdP) but no tenant; the read answers 401 like a bad token would
      tok = token(c, :c)
      c = start_idp!(c, tok)
      {out, code} = smoke(c, [{"SMOKE_TENANT_SLUG", "never-seeded"}])
      assert code == 3, out
      assert out =~ "tenant not seeded yet"
      refute out =~ "HTTP 401"
      refute out =~ @canary
      refute out =~ tok
    end

    @tag timeout: 120_000
    test "S8 a slug with unexpected characters exits 2", c do
      c = start_idp!(c, token(c, :a))
      {_out, code} = smoke(c, [{"SMOKE_TENANT_SLUG", "a b;c"}])
      assert code == 2
      refute_receive {:idp, _, _}, 200
    end

    defp start_idp_again!(c, token) do
      :ok = stop_supervised(:idp)
      start_idp!(c, token)
    end

    @tag timeout: 120_000
    test "S5 neither the password nor the token is printed; the temp dir is removed", c do
      tok = token(c, :a)
      c = start_idp!(c, tok)
      before = File.ls!(c.dir) |> Enum.sort()
      {out, code} = smoke(c)
      assert code == 0, out
      refute out =~ @canary
      refute out =~ tok
      assert File.ls!(c.dir) |> Enum.sort() == before
    end
  end

  # ---------------------------------------------------------------------------------------------
  # C1..C3: the survival counts
  # ---------------------------------------------------------------------------------------------
  describe "demo_counts.sh" do
    setup do
      need_tools!(~w(bash awk sort))
      {:ok, dir: scratch!()}
    end

    defp counts(args, env \\ []),
      do: System.cmd("bash", [@counts | args], env: env, stderr_to_stdout: true)

    defp run_sql! do
      {sql, 0} = counts(["--print-sql"])

      {:ok, lines} =
        Repo.transaction(fn ->
          Repo.query!("SET TRANSACTION READ ONLY")
          %{rows: rows} = Repo.query!(sql)
          Enum.map(rows, fn [line] -> line end)
        end)

      lines
    end

    test "C1 the statement is read-only and its counts equal direct queries" do
      ctx = S.setup_oidc!([:a])
      t = S.tenant!("cnt", Map.fetch!(ctx.names, :a))
      schema = t.schema_name
      slug = t.tenant.slug

      lines = run_sql!()
      assert lines == Enum.sort(lines)
      assert "tenants #{count!("public.tenants")}" in lines

      assert "tenant.#{slug}.status.active 1" in lines or
               Enum.any?(lines, &(&1 =~ "tenant.#{slug}.status."))

      %{rows: [[active]]} =
        Repo.query!(~s|SELECT count(*) FROM "#{schema}".tenant_modules WHERE status = 'active'|)

      assert "tenant.#{slug}.modules_active #{active}" in lines
      assert active >= 1
      assert "tenant.#{slug}.users #{count!(~s|"#{schema}".users|)}" in lines
      assert "tenant.#{slug}.ledger_legs #{count!(~s|"#{schema}".ledger_leg|)}" in lines
      assert "tenant.#{slug}.documents #{count!(~s|"#{schema}".documents|)}" in lines

      %{rows: mods} =
        Repo.query!(~s|SELECT module_id FROM "#{schema}".tenant_modules WHERE status = 'active'|)

      for [id] <- mods, do: assert("tenant.#{slug}.module.#{id} 1" in lines)

      # a grouped key: one record per type, then it shows up with the direct count
      Repo.query!(
        ~s|INSERT INTO "#{schema}".entity_record_latest (id, entity_type, record_id, field_values, deleted, last_event_global_seq, inserted_at, updated_at) | <>
          ~s|VALUES (gen_random_uuid(), 't1473_type', gen_random_uuid(), '{}'::jsonb, false, 1, now(), now())|
      )

      assert "tenant.#{slug}.records.t1473_type 1" in run_sql!()
    end

    defp count!(table) do
      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}")
      n
    end

    test "C2 compare: equal and superset pass, a lower or missing key is LOST, empty is input error",
         %{dir: dir} do
      before = write!(dir, "before", "tenants 2\ntenant.a.users 3\ntenant.a.records.x 5\n")
      equal = write!(dir, "equal", "tenants 2\ntenant.a.users 3\ntenant.a.records.x 5\n")

      more =
        write!(
          dir,
          "more",
          "tenants 3\ntenant.a.users 3\ntenant.a.records.x 9\ntenant.b.users 1\n"
        )

      lower = write!(dir, "lower", "tenants 2\ntenant.a.users 2\ntenant.a.records.x 5\n")
      missing = write!(dir, "missing", "tenants 2\ntenant.a.users 3\n")
      empty = write!(dir, "empty", "")

      assert {_, 0} = counts(["compare", before, equal])
      assert {_, 0} = counts(["compare", before, more])

      assert {out, 1} = counts(["compare", before, lower])
      assert out =~ "LOST tenant.a.users 3 2"

      assert {out, 1} = counts(["compare", before, missing])
      assert out =~ "LOST tenant.a.records.x 5 missing"

      assert {_, 2} = counts(["compare", empty, equal])
      assert {_, 2} = counts(["compare", before, empty])
      assert {_, 2} = counts(["bogus"])
    end

    test "C3 snapshots are sorted, take the statement on stdin, and a new tenant does not fail compare",
         %{dir: dir} do
      seen = Path.join(dir, "stdin.sql")

      stub =
        write!(
          dir,
          "psql_stub.sh",
          "#!/usr/bin/env bash\ncat > '#{seen}'\nprintf 'tenants 1\\na.x 1\\nb.y 2\\n'\n",
          0o700
        )

      assert {out, 0} = counts(["snapshot"], [{"PSQL", stub}])
      assert out == "a.x 1\nb.y 2\ntenants 1\n"
      assert File.read!(seen) =~ "FROM lines ORDER BY line COLLATE"

      before = write!(dir, "b", out)
      after_file = write!(dir, "a", out <> "tenant.new.users 1\n")
      assert {_, 0} = counts(["compare", before, after_file])

      failing = write!(dir, "fail.sh", "#!/usr/bin/env bash\ncat >/dev/null\nexit 3\n", 0o700)
      assert {_, 1} = counts(["snapshot"], [{"PSQL", failing}])

      # on the real database two snapshots of unchanged data are the same
      assert run_sql!() == run_sql!()
    end
  end

  # ---------------------------------------------------------------------------------------------
  # R1: the realm files
  # ---------------------------------------------------------------------------------------------
  describe "realm files" do
    test "R1 both realms are demo-only, hardened and secret-free" do
      origin = "https://demo.letflow.ai-dala.com"
      role_names = Letflow.Api.Authorization.roles() |> Enum.map(&to_string/1) |> Enum.sort()

      for path <- [@showroom, @platform] do
        raw = File.read!(path)
        realm = Jason.decode!(raw)

        for bad <- ~w(credentials secret smtp qa-) do
          refute String.downcase(raw) =~ bad, "#{path} mentions #{bad}"
        end

        assert realm["bruteForceProtected"] == true
        assert realm["registrationAllowed"] == false
        assert realm["sslRequired"] == "external"
        refute Map.has_key?(realm["attributes"] || %{}, "tenant_id")
        assert realm["roles"]["realm"] |> Enum.map(& &1["name"]) |> Enum.sort() == role_names

        clients = Map.new(realm["clients"], &{&1["clientId"], &1})
        assert Map.keys(clients) |> Enum.sort() == ["letflow-demo-smoke", "letflow-web"]

        web = clients["letflow-web"]
        assert web["directAccessGrantsEnabled"] == false
        assert web["standardFlowEnabled"] == true
        assert Enum.all?(web["redirectUris"], &String.starts_with?(&1, origin <> "/"))
        assert web["webOrigins"] == [origin]

        smoke = clients["letflow-demo-smoke"]
        assert smoke["directAccessGrantsEnabled"] == true
        assert smoke["standardFlowEnabled"] == false
        assert smoke["redirectUris"] == [] and smoke["webOrigins"] == []

        for client <- [web, smoke] do
          mappers = Map.new(client["protocolMappers"], &{&1["name"], &1["config"]})
          assert mappers["realm-roles"]["claim.name"] == "roles"

          assert Enum.any?(
                   Map.values(mappers),
                   &(&1["included.client.audience"] == "letflow-web")
                 )
        end

        for user <- realm["users"] do
          refute Map.has_key?(user, "credentials")
          assert String.ends_with?(user["email"], "@example.com")
        end
      end

      showroom = Jason.decode!(File.read!(@showroom))
      users = Map.new(showroom["users"], &{&1["username"], &1["realmRoles"]})
      assert users["demo-smoke"] == ["TASK_WORKER"]
      refute Enum.any?(Map.values(users), &("PLATFORM_ADMIN" in &1))

      platform = Jason.decode!(File.read!(@platform))

      assert [%{"username" => "demo-platform-admin", "realmRoles" => ["PLATFORM_ADMIN"]}] =
               platform["users"]

      assert showroom["realm"] == "demo-showroom" and platform["realm"] == "demo-platform"
    end
  end

  # ---------------------------------------------------------------------------------------------
  # D1: the README
  # ---------------------------------------------------------------------------------------------
  describe "README" do
    test "D1 cites real env vars, names both realms and clients, and its O8 grep still finds nothing" do
      readme = File.read!(@readme)
      runtime = File.read!("config/runtime.exs")
      tenant_config = File.read!("lib/letflow/routers/tenant_config.ex")

      for var <-
            ~w(OIDC_KEYCLOAK_BASE_URL OIDC_CLIENT_ID CORS_ALLOWED_ORIGINS LETFLOW_PLATFORM_TENANT_ID) do
        assert readme =~ var
        assert runtime =~ var, "#{var} is not read by config/runtime.exs"
      end

      assert readme =~ "BPM_IDP_BASE_URL" and tenant_config =~ "BPM_IDP_BASE_URL"

      assert readme =~ "LETFLOW_DEFAULT_TENANT_SLUG" and
               tenant_config =~ "LETFLOW_DEFAULT_TENANT_SLUG"

      assert readme =~
               "VITE_OIDC_AUTHORITY=https://auth-demo.letflow.ai-dala.com/realms/demo-showroom"

      assert readme =~ "CORS_ALLOWED_ORIGINS=https://demo.letflow.ai-dala.com"

      for needle <- [
            "demo-showroom",
            "demo-platform",
            "letflow-web",
            "letflow-demo-smoke",
            "?realm=showroom",
            "bpm-default"
          ] do
        assert readme =~ needle
      end

      # T-1482: the numbered first-install order and the distinct smoke code
      assert readme =~ "## First install: the exact order"
      assert readme =~ "tenant not seeded yet" and readme =~ "exit **3**"
      assert readme =~ "SMOKE_TENANT_SLUG"
      assert readme =~ ~r/^1\. \*\*Empty DB boot/m and readme =~ ~r/^7\. \*\*Smoke/m

      assert readme =~ "No separate internal Keycloak URL"
      assert readme =~ "no web rebuild per promote"
      refute readme =~ ~r/password\s*[:=]\s*"?[A-Za-z0-9]{6,}/i

      need_tools!(~w(grep))

      {out, status} =
        System.cmd(
          "grep",
          ~w(-rn --include=*.ex --include=*.exs --include=*.ts --include=*.tsx --include=*.dart) ++
            [
              "send_chunked\\|Plug.Conn.chunk\\|WebSockAdapter\\|EventSource\\|WebSocket\\|text/event-stream",
              "lib",
              Path.join("web", "src"),
              Path.join(["apps", "mobile", "lib"])
            ],
          stderr_to_stdout: true
        )

      assert status == 1 and out == "",
             "the README says there is no websocket/SSE, but grep found: #{out}"
    end
  end

  # ---------------------------------------------------------------------------------------------
  # B1 / E1: the platform bootstrap
  # ---------------------------------------------------------------------------------------------
  describe "demo_platform_bootstrap.sh" do
    test "B1 create uses rpc once, finish uses eval backfill before check, bad input exits 2" do
      need_tools!(~w(bash))
      dir = scratch!()
      log = Path.join(dir, "argv.log")

      stub =
        write!(
          dir,
          "release_stub.sh",
          "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> '#{log}'\n[ \"$1\" = rpc ] && echo PLATFORM_TENANT_ID=stub\nexit 0\n",
          0o700
        )

      env = [{"RELEASE_CMD", stub}]

      assert {out, 0} =
               System.cmd("bash", [@bootstrap, "create"], env: env, stderr_to_stdout: true)

      assert out =~ "PLATFORM_TENANT_ID=stub"
      assert {_, 0} = System.cmd("bash", [@bootstrap, "finish"], env: env, stderr_to_stdout: true)

      calls = File.read!(log) |> String.split("\n", trim: true)
      assert hd(calls) |> String.starts_with?("rpc ")
      assert Enum.count(calls, &String.starts_with?(&1, "rpc ")) == 1
      assert Enum.any?(calls, &(&1 =~ "provision_and_migrate"))

      assert Enum.take(calls, -2) == [
               "eval Letflow.Release.backfill_platform_roles()",
               "eval Letflow.Release.check_platform_role_groups()"
             ]

      assert {_, 2} = System.cmd("bash", [@bootstrap, "bogus"], env: env, stderr_to_stdout: true)
      assert {_, 2} = System.cmd("bash", [@bootstrap], env: env, stderr_to_stdout: true)

      failing = write!(dir, "fail.sh", "#!/usr/bin/env bash\nexit 1\n", 0o700)

      assert {_, 1} =
               System.cmd("bash", [@bootstrap, "finish"],
                 env: [{"RELEASE_CMD", failing}],
                 stderr_to_stdout: true
               )
    end

    @tag timeout: 300_000
    test "E1 the create expression is repeatable and the backfill gives the pinned tenant its PLATFORM_ADMIN group" do
      need_tools!(~w(bash))
      Letflow.LedgerFixture.setup_auto_mode!()
      {expr, 0} = System.cmd("bash", [@bootstrap, "--print-elixir"])

      run = fn ->
        ExUnit.CaptureIO.capture_io(fn -> Code.eval_string(expr) end)
      end

      out1 = run.()
      assert [_, id] = Regex.run(~r/PLATFORM_TENANT_ID=([0-9a-f-]{36})/, out1)
      on_exit(fn -> Letflow.EntityWritesFixture.drop_committed_tenant!(id) end)

      out2 = run.()
      assert out2 =~ "PLATFORM_TENANT_ID=#{id}"

      assert {:ok, tenant} = Letflow.Identity.get_tenant_by_slug("platform")
      assert tenant.id == id and tenant.idp_realm_id == "demo-platform"

      assert %{rows: [[1]]} =
               Repo.query!("SELECT count(*) FROM public.tenants WHERE slug = 'platform'")

      {:ok, schema} = Letflow.TenantProvisioning.schema_name_for_tenant(id)

      assert %{rows: [[1]]} =
               Repo.query!(
                 "SELECT count(*) FROM information_schema.schemata WHERE schema_name = $1",
                 [schema]
               )

      Letflow.Support.PlatformTenantFixture.pin!(id)
      assert {:ok, _} = Letflow.Release.backfill_platform_roles(start: false, halt: false)
      regs = Letflow.TenantProvisioning.list_registrations() |> Enum.filter(&(&1.tenant_id == id))
      assert {:ok, []} = Letflow.Identity.RoleBackfill.missing_role_groups(registrations: regs)
    end
  end
end
