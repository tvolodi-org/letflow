defmodule Letflow.Api.Scope.ShadowEvidenceTest.FixtureRouter do
  @moduledoc false
  # A test-only router (NOT under test/support: the route inventory never sees it) with one route
  # per scope class behind the same policy key, so the shadow observer can be driven per class.

  use Letflow.Api.AuthorizedRouter

  authz_get "/filtered", :InstancesRead, scope: :filter do
    send_resp(conn, 200, "ok")
  end

  authz_get "/resolver", :InstancesRead,
    scope: {:resolver, {Letflow.Api.RouteScope, :class_of}} do
    send_resp(conn, 200, "ok")
  end

  authz_get "/self-service", :InstancesRead, scope: :self_service do
    send_resp(conn, 200, "ok")
  end

  authz_get "/default", :InstancesRead do
    send_resp(conn, 200, "ok")
  end

  authz_get "/explicit", :InstancesRead, scope: :tenant_wide do
    send_resp(conn, 200, "ok")
  end

  authz_unmatched(:ordinary)
end

defmodule Letflow.Api.Scope.ShadowEvidenceTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2b, AC 22 (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` sections 4.7 and 4.8; spec
  `test/specs/REQ-517-2b.md`, T-H1..T-H10, T-H4b): the persisted shadow evidence,
  `Letflow.Api.Scope.ShadowEvidence` (public ETS counters, a flush process) and the observer that
  feeds it, `Letflow.Api.Scope.Shadow`.

    * the observer: a shadow request records one `requests`; a would-deny also records its reason;
      `{:resolver, _}`, `:filter` and `:self_service` routes are counted as requests only; a
      tenant stored `off` or `on` writes nothing; skipped keys write nothing; no principal counts as
      `grants_unavailable`;
    * the store: `flush/0` persists additively per UTC day, the ETS counter is reduced by exactly
      the flushed amount (increments during a flush are kept), explicit days make separate rows,
      the retention prune deletes only older rows;
    * safety (INV-1, INV-7): hostile or malformed prefix keys placed directly in the table are
      DROPPED and never reach SQL; a flush failure leaves the counters and retries, a dropped table
      or schema discards that prefix; nothing reaches the database on the request path; no tenant
      slug, prefix or user id in logs or metric labels;
    * the process: shutdown flushes, the child is under `Letflow.Supervisor.Infrastructure`, the
      table has the documented shape, `record/3` never raises with the process down.

  `async: false`, as the SEC/REVIEWER gates require: the evidence process is a NAMED SINGLETON
  that writes to the database from its own process. Every tenant here is a provisioned tenant,
  which puts the SQL sandbox in `:auto` mode (real commits visible to that process); the periodic
  timer is set to one hour in `config/test.exs` (`:scope_shadow_flush_interval_ms`) so no timer
  flush can land in another test's state, and each test clears the ETS table first.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Api.Scope.Shadow
  alias Letflow.Api.Scope.ShadowEvidence
  alias Letflow.Api.Scope.ShadowEvidence.Counter
  alias Letflow.Metrics.Registry
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.TenantFixture

  @table :letflow_scope_shadow_evidence
  @infra Letflow.Supervisor.Infrastructure
  @fixture_router Letflow.Api.Scope.ShadowEvidenceTest.FixtureRouter
  @admin "TENANT_ADMIN"
  @reasons ~w(role_not_held no_grant_rows not_tenant_wide out_of_scope unresolvable grants_unavailable)a
  @metrics [:requests | @reasons]
  @wide_from ~D[2000-01-01]
  @wide_to ~D[2100-01-01]

  setup do
    clear_table()
    on_exit(&clear_table/0)
    :ok
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp clear_table do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp tenant!(slug_prefix), do: TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

  # The ETS count of one metric for one prefix, over every day.
  defp ets_total(prefix, metric) do
    @table
    |> :ets.match_object({{prefix, :_, metric}, :_})
    |> Enum.map(fn {_key, count} -> count end)
    |> Enum.sum()
  end

  defp ets_keys(prefix), do: :ets.match_object(@table, {{prefix, :_, :_}, :_})

  # {day, metric} => count of the persisted rows of a tenant.
  defp persisted(fx) do
    Counter
    |> Repo.all(prefix: fx.schema_name)
    |> Map.new(&{{&1.day, &1.metric}, &1.count})
  end

  defp totals(fx), do: ShadowEvidence.counts_between(fx.schema_name, @wide_from, @wide_to)

  defp record_n(prefix, metric, n, day) do
    for _n <- 1..n, do: ShadowEvidence.record(prefix, metric, day)
    :ok
  end

  defp quiet(fun) do
    {result, _log} = with_log(fun)
    result
  end

  defp shadow(router, path, fx, user_id, roles) do
    quiet(fn -> On.call(router, :get, path, fx, user_id, roles, :shadow, nil) end)
  end

  defp with_counter_fault(fx, fun) do
    schema = fx.schema_name
    name = "req517_evidence_fault"

    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".#{name}() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN RAISE EXCEPTION 'injected evidence fault (REQ-517 test)'; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER #{name} BEFORE INSERT OR UPDATE ON "#{schema}".scope_shadow_counters | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".#{name}()|
    )

    try do
      fun.()
    after
      Repo.query!(~s|DROP TRIGGER IF EXISTS #{name} ON "#{schema}".scope_shadow_counters|)
      Repo.query!(~s|DROP FUNCTION IF EXISTS "#{schema}".#{name}()|)
    end
  end

  # Collects every query issued by the evidence process itself while `fun` runs.
  @doc false
  def handle_query(_event, _measurements, metadata, {pid, ref}) do
    send(pid, {:evidence_query, ref, self(), metadata})
    :ok
  end

  defp evidence_queries(fun) do
    ref = make_ref()
    id = {__MODULE__, ref}
    :telemetry.attach(id, [:letflow, :repo, :query], &__MODULE__.handle_query/4, {self(), ref})

    try do
      result = fun.()
      evidence = Process.whereis(ShadowEvidence)
      {result, drain_queries(ref, evidence, [])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain_queries(ref, evidence, acc) do
    receive do
      {:evidence_query, ^ref, ^evidence, metadata} ->
        drain_queries(ref, evidence, [metadata | acc])

      {:evidence_query, ^ref, _other_pid, _metadata} ->
        drain_queries(ref, evidence, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ===========================================================================================
  describe "T-H1 / T-H2 the store: record, flush, persist" do
    test "record/2 increments the ETS counter only; flush/0 persists today's row and empties the counter" do
      fx = tenant!("r517-h1")
      prefix = fx.schema_name

      for _n <- 1..3, do: assert(ShadowEvidence.record(prefix, :requests) == :ok)

      assert ets_total(prefix, :requests) == 3
      # nothing persisted before the flush
      assert persisted(fx) == %{}
      assert totals(fx).requests == 0

      assert ShadowEvidence.flush() == :ok

      assert totals(fx).requests == 3
      assert [{_day, "requests"}] = Map.keys(persisted(fx))
      # exactly the flushed amount was subtracted, the emptied key deleted
      assert ets_keys(prefix) == []
    end

    test "every one of the six reasons is a distinct metric and persists with its count" do
      fx = tenant!("r517-h2")
      prefix = fx.schema_name
      today = Date.utc_today()

      for {reason, n} <- Enum.with_index(@reasons, 1), do: record_n(prefix, reason, n, today)
      record_n(prefix, :requests, 9, today)

      assert :ok = ShadowEvidence.flush()

      expected = %{
        requests: 9,
        role_not_held: 1,
        no_grant_rows: 2,
        not_tenant_wide: 3,
        out_of_scope: 4,
        unresolvable: 5,
        grants_unavailable: 6
      }

      assert totals(fx) == expected

      persisted_metrics = fx |> persisted() |> Map.keys() |> Enum.map(&elem(&1, 1)) |> Enum.sort()
      assert persisted_metrics == @metrics |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    end

    test "an unknown metric, a non-binary prefix and a non-date day are swallowed: :ok, no entry, no raise" do
      assert ShadowEvidence.record("tenant_x", :not_a_metric, Date.utc_today()) == :ok
      assert ShadowEvidence.record(123, :requests, Date.utc_today()) == :ok
      assert ShadowEvidence.record("tenant_x", :requests, "2026-01-01") == :ok
      assert ShadowEvidence.record(nil, nil) == :ok
      assert :ets.tab2list(@table) == []
    end

    test "counts_between/3 zero-fills all seven metrics, is inclusive, and refuses a non-tenant prefix" do
      fx = tenant!("r517-h1c")
      prefix = fx.schema_name

      assert totals(fx) == Map.new(@metrics, &{&1, 0})

      # days relative to today and inside the retention window, so the prune keeps them
      d1 = Date.add(Date.utc_today(), -6)
      d2 = Date.add(d1, 1)
      d3 = Date.add(d1, 2)

      record_n(prefix, :requests, 2, d1)
      record_n(prefix, :requests, 3, d2)
      record_n(prefix, :requests, 5, d3)
      record_n(prefix, :out_of_scope, 1, d2)
      assert :ok = ShadowEvidence.flush()

      requests = fn from, to -> ShadowEvidence.counts_between(prefix, from, to).requests end

      assert requests.(d2, d2) == 3
      assert requests.(d1, d2) == 5
      assert requests.(d2, d3) == 8
      assert requests.(Date.add(d3, 1), Date.add(d3, 5)) == 0
      # from > to is an empty window, not an error
      assert requests.(d3, d1) == 0
      assert ShadowEvidence.counts_between(prefix, d1, d3).out_of_scope == 1

      for bad <- ["public", "tenants", "", "tenant_x", "tenant_#{String.duplicate("A", 32)}"] do
        assert_raise ArgumentError, fn ->
          ShadowEvidence.counts_between(bad, @wide_from, @wide_to)
        end
      end
    end
  end

  # ===========================================================================================
  describe "T-H8 additive upsert and concurrent increments" do
    test "two flushes sum (the upsert adds, it never replaces)" do
      fx = tenant!("r517-h8")
      prefix = fx.schema_name
      day = Date.utc_today()

      record_n(prefix, :requests, 3, day)
      assert :ok = ShadowEvidence.flush()
      assert totals(fx).requests == 3

      record_n(prefix, :requests, 4, day)
      record_n(prefix, :not_tenant_wide, 2, day)
      assert :ok = ShadowEvidence.flush()

      assert totals(fx).requests == 7
      assert totals(fx).not_tenant_wide == 2
      # still one row per (day, metric)
      assert map_size(persisted(fx)) == 2
    end

    test "increments made while flushes run are not lost: the persisted total is exactly what was recorded" do
      fx = tenant!("r517-h8c")
      prefix = fx.schema_name
      day = Date.utc_today()

      tasks =
        for _worker <- 1..4 do
          Task.async(fn -> record_n(prefix, :requests, 500, day) end)
        end

      for _flush <- 1..5, do: ShadowEvidence.flush()
      Task.await_many(tasks, 30_000)
      assert :ok = ShadowEvidence.flush()

      assert totals(fx).requests == 2000
      assert ets_keys(prefix) == []
    end
  end

  # ===========================================================================================
  describe "T-H10 days and retention" do
    test "explicit days make separate rows" do
      fx = tenant!("r517-h10")
      prefix = fx.schema_name

      # inside the retention window (the prune after the flush deletes older rows)
      day_one = Date.add(Date.utc_today(), -3)
      day_two = Date.add(day_one, 1)
      record_n(prefix, :requests, 2, day_one)
      record_n(prefix, :requests, 3, day_two)
      assert :ok = ShadowEvidence.flush()

      assert persisted(fx) == %{
               {day_one, "requests"} => 2,
               {day_two, "requests"} => 3
             }
    end

    test "the prune after a flush deletes only rows older than the retention, keeping today's and a recent day's" do
      fx = tenant!("r517-h10r")
      prefix = fx.schema_name
      today = Date.utc_today()

      record_n(prefix, :requests, 2, today)
      record_n(prefix, :requests, 1, Date.add(today, -5))
      record_n(prefix, :requests, 1, Date.add(today, -89))
      record_n(prefix, :requests, 5, Date.add(today, -100))
      assert :ok = ShadowEvidence.flush()

      days = fx |> persisted() |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.sort(Date)

      assert days == Enum.sort([Date.add(today, -89), Date.add(today, -5), today], Date)
    end

    test "the retention is configurable and its boundary day is kept" do
      Application.put_env(:letflow, :scope_shadow_retention_days, 10)
      on_exit(fn -> Application.delete_env(:letflow, :scope_shadow_retention_days) end)

      fx = tenant!("r517-h10b")
      prefix = fx.schema_name
      today = Date.utc_today()

      record_n(prefix, :requests, 1, Date.add(today, -10))
      record_n(prefix, :requests, 1, Date.add(today, -11))
      assert :ok = ShadowEvidence.flush()

      days = fx |> persisted() |> Map.keys() |> Enum.map(&elem(&1, 0))
      assert days == [Date.add(today, -10)]
    end
  end

  # ===========================================================================================
  describe "T-H4b hostile prefix keys are dropped and never reach SQL (INV-7, SEC D-2)" do
    test "malformed or hostile ETS prefixes are dropped; the valid prefix beside them is persisted; no hostile text appears in any query" do
      fx = tenant!("r517-h4b")
      day = Date.utc_today()
      hex = String.duplicate("a", 32)

      hostile = [
        ~s|tenant_x"; DROP TABLE tenants; --|,
        "public",
        "tenants",
        "",
        "tenant_" <> String.upcase(hex),
        "tenant_" <> String.duplicate("a", 31),
        "tenant_" <> hex <> "x",
        "tenant_" <> hex <> "; DROP SCHEMA public CASCADE",
        "Tenant_" <> hex
      ]

      for prefix <- hostile, do: :ets.insert(@table, {{prefix, day, :requests}, 7})
      :ets.insert(@table, {{fx.schema_name, day, :requests}, 2})

      {result, queries} = evidence_queries(fn -> ShadowEvidence.flush() end)

      assert result == :ok
      assert totals(fx).requests == 2

      for prefix <- hostile do
        assert ets_keys(prefix) == [], "hostile prefix #{inspect(prefix)} was not dropped"
      end

      assert ets_keys(fx.schema_name) == []

      for query <- queries do
        text = query.query <> inspect(Map.get(query, :params))
        refute text =~ "DROP", text
        refute text =~ "tenant_x", text
        refute text =~ "Tenant_", text
      end

      # the public tables are intact and nothing was created in public
      assert %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM tenants")
      assert n >= 1

      assert %{rows: [[nil]]} =
               Repo.query!("SELECT to_regclass('public.scope_shadow_counters')::text")
    end

    test "a hostile prefix alone leaves the table empty and the flush a no-op that still answers :ok" do
      :ets.insert(@table, {{~s|x"; SELECT pg_sleep(60); --|, Date.utc_today(), :requests}, 1})

      {result, queries} = evidence_queries(fn -> ShadowEvidence.flush() end)

      assert result == :ok
      assert queries == []
      assert :ets.tab2list(@table) == []
    end
  end

  # ===========================================================================================
  describe "T-H4 a flush failure never fails the request and loses nothing" do
    test "a failing upsert keeps the counters, logs ONE constant line, record/3 still works; the next flush persists everything" do
      fx = tenant!("r517-h4")
      prefix = fx.schema_name
      day = Date.utc_today()
      record_n(prefix, :requests, 3, day)

      {result, log} =
        with_log(fn -> with_counter_fault(fx, fn -> ShadowEvidence.flush() end) end)

      assert result == {:error, :flush_failed}
      assert ets_total(prefix, :requests) == 3

      lines =
        log
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "scope_shadow_flush_failed"))

      assert [line] = lines
      assert line =~ "scope_shadow_flush_failed class=error"
      # only the constant line is judged: the Ecto QUERY lines in the same capture name the schema
      for secret <- [prefix, fx.tenant_id, fx.tenant.slug], do: refute(line =~ secret)

      # the request path is unaffected by the failed flush, and new counts add to the retained ones
      record_n(prefix, :requests, 2, day)
      assert ets_total(prefix, :requests) == 5

      # retried: nothing was lost
      assert :ok = ShadowEvidence.flush()
      assert totals(fx).requests == 5
      assert ets_keys(prefix) == []
    end

    test "a dropped scope_shadow_counters table discards that prefix's counters (no memory leak), without a failure line" do
      fx = tenant!("r517-h4d")
      prefix = fx.schema_name
      record_n(prefix, :requests, 3, Date.utc_today())
      Repo.query!(~s|DROP TABLE "#{prefix}".scope_shadow_counters|)

      {result, log} = with_log(fn -> ShadowEvidence.flush() end)

      assert result == :ok
      assert ets_keys(prefix) == []
      refute log =~ "scope_shadow_flush_failed"
    end

    test "a well-formed prefix whose schema does not exist is discarded the same way" do
      prefix = "tenant_" <> String.duplicate("0123456789abcdef", 2)
      record_n(prefix, :requests, 3, Date.utc_today())

      {result, log} = with_log(fn -> ShadowEvidence.flush() end)

      assert result == :ok
      assert ets_keys(prefix) == []
      refute log =~ "scope_shadow_flush_failed"
    end
  end

  # ===========================================================================================
  describe "T-H6 nothing on the request path" do
    test "record/3 issues zero queries in the calling process" do
      fx = tenant!("r517-h6")

      {_result, queries} =
        Fixture.capture_repo_queries(fn ->
          for _n <- 1..50, do: ShadowEvidence.record(fx.schema_name, :requests)
        end)

      assert queries == []
    end

    test "a shadow request touches scope_shadow_counters in neither the request process nor the evidence process (N10)" do
      fx = S.tenant!("r517-h6r")
      scoped = On.scoped_holder!(fx, @admin)

      {{_conn, request_queries}, evidence_side} =
        evidence_queries(fn ->
          Fixture.capture_repo_queries(fn ->
            shadow(@fixture_router, "/default", fx, scoped.id, [@admin])
          end)
        end)

      refute Enum.any?(request_queries, &(&1.query =~ "scope_shadow_counters"))
      assert evidence_side == []
      # the observation is in ETS, unflushed
      assert ets_total(fx.schema_name, :requests) == 1
      assert persisted(fx) == %{}
    end
  end

  # ===========================================================================================
  describe "the observer: Letflow.Api.Scope.Shadow records into the store" do
    setup do
      fx = S.tenant!("r517-obs")
      %{fx: fx, prefix: fx.schema_name, scoped: On.scoped_holder!(fx, @admin)}
    end

    test "a tenant-wide holder: one request, no reason (T-H1)", %{fx: fx, prefix: prefix} do
      conn = shadow(@fixture_router, "/default", fx, fx.admin.id, [@admin])

      assert conn.status == 200
      assert ets_total(prefix, :requests) == 1
      for reason <- @reasons, do: assert(ets_total(prefix, reason) == 0, "#{reason}")

      assert :ok = ShadowEvidence.flush()
      assert totals(fx) == Map.merge(Map.new(@metrics, &{&1, 0}), %{requests: 1})
    end

    test "a would-deny: the request AND its reason, both persisted by the flush (T-H2)", %{
      fx: fx,
      prefix: prefix,
      scoped: scoped
    } do
      conn = shadow(@fixture_router, "/default", fx, scoped.id, [@admin])
      # shadow denies nothing
      assert conn.status == 200

      assert ets_total(prefix, :requests) == 1
      assert ets_total(prefix, :not_tenant_wide) == 1

      assert :ok = ShadowEvidence.flush()
      totals = totals(fx)
      assert totals.requests == 1
      assert totals.not_tenant_wide == 1
      assert Enum.sum(Map.values(totals)) == 2
    end

    test "the reason of each shape: no grant row, failed grants load, no principal", %{
      fx: fx,
      prefix: prefix
    } do
      rowless = On.rowless_holder!(fx)
      shadow(@fixture_router, "/default", fx, rowless.id, [@admin])
      assert ets_total(prefix, :no_grant_rows) == 1

      not_loaded =
        fx |> On.ctx(fx.admin.id, [@admin], :shadow) |> Map.put(:scope_grants, :not_loaded)

      quiet(fn -> S.call(@fixture_router, :get, "/default", fx, not_loaded, nil) end)
      assert ets_total(prefix, :grants_unavailable) == 1

      no_principal = fx |> On.ctx(fx.admin.id, [@admin], :shadow) |> Map.delete(:credential)
      quiet(fn -> S.call(@fixture_router, :get, "/default", fx, no_principal, nil) end)
      assert ets_total(prefix, :grants_unavailable) == 2

      assert ets_total(prefix, :requests) == 3
    end

    test "resolver, filter and self_service routes are counted as requests only, even for a scoped caller (T-H7)",
         %{
           fx: fx,
           prefix: prefix,
           scoped: scoped
         } do
      for path <- ["/filtered", "/resolver", "/self-service"] do
        assert shadow(@fixture_router, path, fx, scoped.id, [@admin]).status == 200
      end

      assert ets_total(prefix, :requests) == 3
      for reason <- @reasons, do: assert(ets_total(prefix, reason) == 0, "#{reason}")
    end

    test "an explicit :tenant_wide route is evaluated like the default one", %{
      fx: fx,
      prefix: prefix,
      scoped: scoped
    } do
      shadow(@fixture_router, "/explicit", fx, scoped.id, [@admin])
      assert ets_total(prefix, :requests) == 1
      assert ets_total(prefix, :not_tenant_wide) == 1
    end

    test "a real admin-plane route is evaluated against tenant-wide like any other", %{
      fx: fx,
      prefix: prefix,
      scoped: scoped
    } do
      # real admin-plane route (ScopeEnforcementRead), scoped caller: evaluated as :admin_plane
      shadow(Letflow.Routers.TenantScopeEnforcement, "/", fx, scoped.id, [@admin])
      assert ets_total(prefix, :requests) == 1
      assert ets_total(prefix, :not_tenant_wide) == 1
    end

    test "a tenant stored off or on writes no counter at all (T-H3, N11)", %{
      fx: fx,
      prefix: prefix,
      scoped: scoped
    } do
      for mode <- [:off, :on] do
        quiet(fn ->
          On.call(@fixture_router, :get, "/default", fx, scoped.id, [@admin], mode, nil)
        end)

        quiet(fn ->
          On.call(@fixture_router, :get, "/default", fx, fx.admin.id, [@admin], mode, nil)
        end)
      end

      assert ets_keys(prefix) == []
      assert :ok = ShadowEvidence.flush()
      assert persisted(fx) == %{}
    end

    test "the skipped keys and a coarse deny write nothing", %{
      fx: fx,
      prefix: prefix,
      scoped: scoped
    } do
      # a coarse deny (no role) never reaches the observer
      quiet(fn ->
        On.call(@fixture_router, :get, "/default", fx, scoped.id, [], :shadow, nil)
      end)

      # the unmatched-route catch-all for a tenant admin is the coarse 403
      shadow(@fixture_router, "/no/such/route", fx, scoped.id, [@admin])

      # skipped keys called straight on the observer
      for key <- [:Unknown, :UnmatchedRoute, :UnmatchedPlatformPath, :MetricsRead] do
        conn =
          Plug.Test.conn(:get, "/x")
          |> Plug.Conn.put_private(:policy_key, key)
          |> Plug.Conn.assign(:scoped_opts, prefix: prefix)

        assert Shadow.observe(
                 conn,
                 %Letflow.Api.Authorization.AccessContext{
                   user_id: scoped.id,
                   roles: [:TENANT_ADMIN]
                 },
                 key
               ) == conn
      end

      assert ets_keys(prefix) == []
    end

    test "another tenant's counters are untouched (T-H3)", %{
      fx: fx,
      prefix: prefix,
      scoped: scoped
    } do
      other = tenant!("r517-obs-other")

      shadow(@fixture_router, "/default", fx, scoped.id, [@admin])
      assert :ok = ShadowEvidence.flush()

      assert totals(fx).requests == 1
      assert totals(other) == Map.new(@metrics, &{&1, 0})
      assert persisted(other) == %{}
      assert ets_keys(other.schema_name) == []
      assert ets_keys(prefix) == []
    end

    test "no tenant slug, prefix, tenant id or user id in logs or metric labels (T-H5)", %{
      fx: fx,
      prefix: prefix,
      scoped: scoped
    } do
      {_result, log} =
        with_log(fn ->
          On.call(@fixture_router, :get, "/default", fx, scoped.id, [@admin], :shadow, nil)
          ShadowEvidence.flush()
        end)

      # only the lines written by the shadow/evidence code are judged: the Ecto QUERY debug
      # lines in the same capture legitimately name the schema and bind the user id
      own =
        log
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "scope_shadow"))
        |> Enum.reject(&String.contains?(&1, ~s("scope_shadow_counters")))

      assert own != []

      for secret <- [prefix, fx.tenant_id, fx.tenant.slug, scoped.id, scoped.email],
          line <- own do
        refute String.contains?(line, secret), "the log leaks #{inspect(secret)}: #{line}"
      end

      shadow_counters =
        for {{family, labels}, _count} <- Registry.snapshot().counters,
            family == :scope_shadow_would_deny_total,
            do: labels

      assert shadow_counters != []
      assert Enum.all?(shadow_counters, &(Map.keys(&1) == [:reason]))
    end

    test "a successful observation and flush log nothing at all from the evidence code", %{
      fx: fx,
      scoped: scoped
    } do
      # drive the observer directly so the unrelated request logging is out of the picture
      auth_context = On.ctx(fx, scoped.id, [@admin], :shadow)

      conn =
        Plug.Test.conn(:get, "/x")
        |> Plug.Conn.put_private(:policy_key, :InstancesRead)
        |> Plug.Conn.assign(:auth_context, auth_context)
        |> Plug.Conn.assign(:scoped_opts, prefix: fx.schema_name)

      access = %Letflow.Api.Authorization.AccessContext{
        user_id: scoped.id,
        roles: [:TENANT_ADMIN]
      }

      log =
        capture_log(fn ->
          Shadow.observe(conn, access, :InstancesRead)
          assert :ok = ShadowEvidence.flush()
        end)

      refute log =~ "scope_shadow_flush_failed"
    end
  end

  # ===========================================================================================
  describe "T-H9 the process" do
    test "the table is public, named, a set with write concurrency, owned by the evidence process" do
      owner = Process.whereis(ShadowEvidence)
      assert is_pid(owner)

      assert :ets.info(@table, :named_table) == true
      assert :ets.info(@table, :protection) == :public
      assert :ets.info(@table, :type) == :set
      assert :ets.info(@table, :write_concurrency) == true
      assert :ets.info(@table, :owner) == owner
    end

    test "the child is under Letflow.Supervisor.Infrastructure, permanent, with a 10 s shutdown" do
      assert {ShadowEvidence, pid, :worker, [ShadowEvidence]} =
               List.keyfind(Supervisor.which_children(@infra), ShadowEvidence, 0)

      assert pid == Process.whereis(ShadowEvidence)
      spec = ShadowEvidence.child_spec([])
      assert spec.shutdown == 10_000
      assert Map.get(spec, :restart, :permanent) == :permanent
    end

    test "the periodic tick (a bare :flush message, as the timer sends it) persists the counts without a caller; an unknown message is ignored" do
      fx = tenant!("r517-h9t")
      prefix = fx.schema_name
      pid = Process.whereis(ShadowEvidence)

      record_n(prefix, :requests, 2, Date.utc_today())
      assert persisted(fx) == %{}

      send(pid, :junk)
      send(pid, :flush)
      # a system message is handled in mailbox order, so this returns after the tick was handled
      assert %{} = :sys.get_state(pid)

      assert Process.whereis(ShadowEvidence) == pid
      assert totals(fx).requests == 2
      assert ets_keys(prefix) == []
    end

    test "shutdown flushes unflushed counts (terminate/2); with the process down record/3 and flush/0 do not raise; the restart serves again" do
      fx = tenant!("r517-h9")
      prefix = fx.schema_name
      day = Date.utc_today()
      on_exit(fn -> Supervisor.restart_child(@infra, ShadowEvidence) end)

      record_n(prefix, :requests, 3, day)
      record_n(prefix, :not_tenant_wide, 1, day)
      assert persisted(fx) == %{}

      assert :ok = Supervisor.terminate_child(@infra, ShadowEvidence)

      # the table died with its owner, yet the counts were written on the way out
      assert :ets.whereis(@table) == :undefined
      assert Process.whereis(ShadowEvidence) == nil
      assert ShadowEvidence.record(prefix, :requests) == :ok
      assert ShadowEvidence.flush() == {:error, :not_running}

      assert {:ok, _pid} = Supervisor.restart_child(@infra, ShadowEvidence)
      assert :ets.whereis(@table) != :undefined

      totals = totals(fx)
      assert totals.requests == 3
      assert totals.not_tenant_wide == 1

      assert ShadowEvidence.record(prefix, :requests) == :ok
      assert ets_total(prefix, :requests) == 1
    end
  end
end
