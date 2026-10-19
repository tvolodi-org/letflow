defmodule Letflow.ScopeEnforcement.ShadowWindowTest do
  @moduledoc """
  REQ-519 slice 2f-a (GH #2535), AC 11 and AC 12 (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` section 4.6 and tests
  T-E1..T-E16, SEC S-4/S-5, SEC code-gate merge conditions of step-16, REVIEWER step-17; spec
  `test/specs/REQ-519-2f-a.md`): `Letflow.ScopeEnforcement.ShadowWindow` and the two reads it
  stands on, `Letflow.Api.Scope.ShadowEvidence.counts_by_day/3` and
  `Letflow.Audit.latest_matching/4`.

  Time is never read from the wall clock for a decision: the tenant is flipped `off -> shadow`
  through the REAL flip once (a genuine audit entry, so `t0` is a server timestamp), and every
  evaluation passes an explicit `now` that is `t0` plus a whole number of seconds. The shadow
  duration is compared on whole seconds (`DateTime.diff(now, t0, :second)`), so a boundary is
  tested at `-1 s`, `0` and `+0 s`, never at a sub-second offset. Persisted counters are seeded
  directly into `scope_shadow_counters` for the dates of the window of that `now`.

    * T-E1..T-E5: each of the five criteria alone refuses, and all satisfied passes, including the
      exact boundaries (`>=` on the duration, `>=` on the request total, 99 vs 100);
    * T-E6: the shadow start is the LATEST transition into `shadow` (shadow -> off -> shadow
      restarts it; a latest transition that left `shadow`, another tenant's entry, another action
      or another resource type never count);
    * T-E7: the partial-day rule (both end dates inclusive and counted in full, dates outside the
      window never counted);
    * T-E8..T-E10: thresholds come from the application env ONLY, invalid or below-1 values fall
      back to the DEFAULT, the defaults are the module attributes (7 / 100 / 90) and no config
      file sets them, `min_days > retention_days` fails `configuration`;
    * T-E11..T-E14, T-E16: the injected clock, the closed reason set, `counts_by_day/3` equals the
      per-day sums of `counts_between/3` in ONE statement, the `evidence_scope` constant, the
      flush before the gate reads.

  T-E15 (the AC 12 sentence verbatim in `docs/roles.md`) belongs to 2f-b, which writes the docs;
  here the sentence itself is pinned.

  `async: false`: real tenant schemas, committed writes, VM-global application env, the named
  shadow-evidence process.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Scope.ShadowEvidence
  alias Letflow.ScopeEnforcement
  alias Letflow.ScopeEnforcement.ShadowWindow
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Test.RuntimeConfigEval
  alias Letflow.TestSupport.QueryCount

  @scope "tenant_wide_and_admin_plane_routes_only"
  @sentence "The shadow period proves only the denials of tenant-wide and admin-plane routes; denials on the data path (compiler predicate, 404 equivalence, writes, bulk and import, F1) are proven by the REQ-518 tests and the end-to-end suite, not by shadow."
  @reasons [
    :role_not_held,
    :no_grant_rows,
    :not_tenant_wide,
    :out_of_scope,
    :unresolvable,
    :grants_unavailable
  ]
  @all_true %{
    duration: true,
    requests: true,
    every_day_has_requests: true,
    no_blocking_would_deny: true,
    configuration: true
  }
  @threshold_keys [
    :scope_shadow_min_days,
    :scope_shadow_min_requests,
    :scope_shadow_retention_days
  ]

  # --- helpers ---------------------------------------------------------------------------------

  defp eval(fx, now), do: ShadowWindow.evaluate(fx.tenant_id, fx.schema_name, now)

  defp last_date(now), do: DateTime.to_date(now)
  defp first_date(now), do: Date.add(DateTime.to_date(now), -7)

  defp prod_config do
    vars =
      Map.put(
        RuntimeConfigEval.valid_base(),
        "DATABASE_URL",
        "ecto://u:p@localhost/letflow_prod"
      )

    {outcome, _stderr} = RuntimeConfigEval.evaluate(vars, :prod)

    case outcome do
      {:ok, runtime} ->
        RuntimeConfigEval.merged(runtime, :prod)

      {:raised, message, _formatted} ->
        flunk("the production configuration did not evaluate: #{message}")
    end
  end

  # --- T-E1..T-E5: the five criteria -----------------------------------------------------------

  describe "T-E1 (a) the shadow duration" do
    test "one second too young refuses on (a) alone; exactly min_days passes (>=, not >)" do
      fx = F.shadow_tenant!("req519-e1")
      young = DateTime.add(fx.now, -1, :second)
      :ok = F.satisfy!(fx, young)

      {report, ok?} = eval(fx, young)

      assert report.criteria == %{@all_true | duration: false}
      refute ok?

      :ok = F.satisfy!(fx, fx.now)
      {report, ok?} = eval(fx, fx.now)

      assert report.criteria == @all_true
      assert ok?
    end

    test "an hour too young refuses; much older passes" do
      fx = F.shadow_tenant!("req519-e1b")
      hour_short = DateTime.add(fx.now, -3_600, :second)
      :ok = F.satisfy!(fx, hour_short)
      {report, ok?} = eval(fx, hour_short)
      assert report.criteria.duration == false
      refute ok?

      old = F.after_days(fx.t0, 30)
      :ok = F.satisfy!(fx, old)
      {report, ok?} = eval(fx, old)
      assert report.criteria.duration == true
      assert ok?
    end

    test "a clock before the shadow start never passes" do
      fx = F.shadow_tenant!("req519-e1c")
      before = F.after_days(fx.t0, -1)
      :ok = F.satisfy!(fx, before)

      {report, ok?} = eval(fx, before)

      assert report.criteria.duration == false
      refute ok?
    end

    test "no flip entry at all (a tenant that was never in shadow) fails (a) closed" do
      fx = F.admin_tenant!("req519-e1d")
      now = DateTime.utc_now()
      :ok = F.satisfy!(fx, now)

      {report, ok?} = eval(fx, now)

      assert report.shadow_since == nil
      assert report.criteria.duration == false
      refute ok?
    end
  end

  describe "T-E2 (b) the request total" do
    test "8 requests (one per date) fail the total alone; 99 fails, 100 passes (>=)" do
      fx = F.shadow_tenant!("req519-e2")
      last = last_date(fx.now)
      :ok = F.seed_requests!(fx, fx.now, 7, 1)

      {report, ok?} = eval(fx, fx.now)
      assert report.requests == 8
      assert report.criteria == %{@all_true | requests: false}
      refute ok?

      :ok = F.put_count!(fx, last, :requests, 92)
      {report, _ok?} = eval(fx, fx.now)
      assert report.requests == 99
      assert report.criteria.requests == false

      :ok = F.put_count!(fx, last, :requests, 93)
      {report, ok?} = eval(fx, fx.now)
      assert report.requests == 100
      assert report.criteria == @all_true
      assert ok?
    end
  end

  describe "T-E3 (b) every date of the window needs requests" do
    test "100 requests on one date and none on the others: the total passes, the every-day rule fails" do
      fx = F.shadow_tenant!("req519-e3")
      :ok = F.put_count!(fx, last_date(fx.now), :requests, 100)

      {report, ok?} = eval(fx, fx.now)

      assert report.requests == 100
      assert report.days_without_requests == 7
      assert report.criteria == %{@all_true | every_day_has_requests: false}
      refute ok?
    end

    test "a stored count of 0 is a day without requests, one request on each date passes the rule" do
      fx = F.shadow_tenant!("req519-e3b")
      :ok = F.seed_requests!(fx, fx.now, 7, 20)
      first = first_date(fx.now)
      :ok = F.put_count!(fx, first, :requests, 0)

      {report, _ok?} = eval(fx, fx.now)
      assert report.days_without_requests == 1
      assert report.criteria.every_day_has_requests == false
      assert report.criteria.requests == true

      :ok = F.put_count!(fx, first, :requests, 1)
      {report, ok?} = eval(fx, fx.now)
      assert report.days_without_requests == 0
      assert report.criteria.every_day_has_requests == true
      assert ok?
    end
  end

  describe "T-E4 (c) no BLOCKING would-deny" do
    test "no_grant_rows and grants_unavailable block (each alone); the other four are reported and never block" do
      cases = [
        {:no_grant_rows, true},
        {:grants_unavailable, true},
        {:role_not_held, false},
        {:not_tenant_wide, false},
        {:out_of_scope, false},
        {:unresolvable, false}
      ]

      for {{reason, blocks?}, index} <- Enum.with_index(cases) do
        fx = F.shadow_tenant!("req519-e4-#{index}")
        :ok = F.satisfy!(fx, fx.now)
        :ok = F.put_count!(fx, last_date(fx.now), reason, 5)

        {report, ok?} = eval(fx, fx.now)

        assert report.would_deny[reason] == 5, "#{reason}: counted in the report"
        assert report.criteria.no_blocking_would_deny == not blocks?, "#{reason}: criterion"
        assert ok? == not blocks?, "#{reason}: verdict"

        others = Map.delete(report.would_deny, reason)
        assert Enum.all?(others, fn {_reason, count} -> count == 0 end)
      end
    end

    test "a blocking denial on ANY date of the window blocks, even a single one" do
      fx = F.shadow_tenant!("req519-e4b")
      :ok = F.satisfy!(fx, fx.now)
      :ok = F.put_count!(fx, Date.add(last_date(fx.now), -3), :no_grant_rows, 1)

      {report, ok?} = eval(fx, fx.now)

      assert report.would_deny.no_grant_rows == 1
      assert report.criteria.no_blocking_would_deny == false
      refute ok?
    end
  end

  describe "T-E5 everything satisfied" do
    test "passes and carries the window, the sums and the scope constant" do
      fx = F.shadow_tenant!("req519-e5")
      :ok = F.satisfy!(fx, fx.now)

      {report, ok?} = eval(fx, fx.now)

      assert ok?
      assert report.criteria == @all_true
      assert report.shadow_since == fx.t0
      assert report.window_to == last_date(fx.now)
      assert report.window_from == first_date(fx.now)
      assert report.requests == 160
      assert report.days_without_requests == 0
      assert Enum.all?(report.would_deny, fn {_reason, count} -> count == 0 end)
      assert report.evidence_scope == @scope

      assert Enum.sort(Map.keys(report)) ==
               Enum.sort([
                 :criteria,
                 :days_without_requests,
                 :evidence_scope,
                 :requests,
                 :shadow_since,
                 :window_from,
                 :window_to,
                 :would_deny
               ])
    end
  end

  # --- T-E6: where the window starts -----------------------------------------------------------

  describe "T-E6 the shadow start comes from the audit chain" do
    test "shadow -> off -> shadow restarts the window: the start is the LATEST entry, not the first" do
      fx = F.shadow_tenant!("req519-e6")
      first_since = fx.t0

      _ = F.flip!(fx, :off, "req519 e6 leave shadow")

      # the latest transition left shadow: no start, fails closed even 30 days later
      far = F.after_days(first_since, 30)
      :ok = F.satisfy!(fx, far)
      {report, ok?} = eval(fx, far)
      assert report.shadow_since == nil
      assert report.criteria.duration == false
      refute ok?

      _ = F.flip!(fx, :shadow, nil)
      second = F.latest_flip_entry!(fx)
      assert second.action == "scope.enforcement_enabled"
      assert DateTime.compare(second.timestamp, first_since) == :gt

      # MU-36: the first entry must not be taken
      {report, _ok?} = eval(fx, far)
      assert report.shadow_since == second.timestamp
      assert report.criteria.duration == true

      young = DateTime.add(F.after_days(second.timestamp, 7), -1, :second)
      :ok = F.satisfy!(fx, young)
      {report, _ok?} = eval(fx, young)
      assert report.criteria.duration == false

      exact = F.after_days(second.timestamp, 7)
      :ok = F.satisfy!(fx, exact)
      {report, ok?} = eval(fx, exact)
      assert report.criteria.duration == true
      assert ok?
    end

    test "entries of another tenant, another action or another resource type never start the window" do
      fx = F.shadow_tenant!("req519-e6b")
      :ok = F.satisfy!(fx, fx.now)
      later = DateTime.add(fx.t0, 60, :second)

      for {action, resource_type, resource_id} <- [
            {"scope.enforcement_enabled", "tenant", Ecto.UUID.generate()},
            {"scope.enforcement_refused", "tenant", fx.tenant_id},
            {"scope.enforcement_enabled", "tenant_role", fx.tenant_id}
          ] do
        _ =
          F.raw_entry!(fx, %{
            action: action,
            resource_type: resource_type,
            resource_id: resource_id,
            timestamp: later,
            after_state: %{"mode" => "shadow"}
          })
      end

      {report, ok?} = eval(fx, fx.now)

      assert report.shadow_since == fx.t0
      assert ok?
    end

    test "a later flip entry whose mode is not shadow (or has no mode) fails (a) closed" do
      fx = F.shadow_tenant!("req519-e6c")
      :ok = F.satisfy!(fx, fx.now)
      later = DateTime.add(fx.t0, 60, :second)

      _ =
        F.raw_entry!(fx, %{
          action: "scope.enforcement_enabled",
          resource_type: "tenant",
          resource_id: fx.tenant_id,
          timestamp: later,
          after_state: %{"mode" => "on"}
        })

      {report, ok?} = eval(fx, fx.now)
      assert report.shadow_since == nil
      assert report.criteria.duration == false
      refute ok?

      _ =
        F.raw_entry!(fx, %{
          action: "scope.enforcement_disabled",
          resource_type: "tenant",
          resource_id: fx.tenant_id,
          timestamp: DateTime.add(later, 60, :second),
          after_state: %{"reason" => "no mode key"}
        })

      {report, _ok?} = eval(fx, fx.now)
      assert report.shadow_since == nil
      assert report.criteria.duration == false
    end
  end

  # --- T-E7: the partial-day rule --------------------------------------------------------------

  describe "T-E7 the window dates" do
    test "both end dates are inclusive and counted in full; dates outside are never counted" do
      fx = F.shadow_tenant!("req519-e7")
      from = first_date(fx.now)
      to = last_date(fx.now)
      :ok = F.satisfy!(fx, fx.now)

      # outside the window on both sides: neither requests nor denials may leak in
      for day <- [Date.add(from, -1), Date.add(to, 1)] do
        :ok = F.put_count!(fx, day, :no_grant_rows, 9)
        :ok = F.put_count!(fx, day, :requests, 1_000)
      end

      {report, ok?} = eval(fx, fx.now)
      assert ok?
      assert report.requests == 160
      assert report.would_deny.no_grant_rows == 0
      assert report.window_from == from
      assert report.window_to == to

      # the first date (the shadow start's own date) counts in full
      :ok = F.put_count!(fx, from, :no_grant_rows, 1)
      {report, _ok?} = eval(fx, fx.now)
      assert report.would_deny.no_grant_rows == 1
      assert report.criteria.no_blocking_would_deny == false
      :ok = F.put_count!(fx, from, :no_grant_rows, 0)

      # the last date counts in full too
      :ok = F.put_count!(fx, to, :no_grant_rows, 1)
      {report, _ok?} = eval(fx, fx.now)
      assert report.would_deny.no_grant_rows == 1
      assert report.criteria.no_blocking_would_deny == false
      :ok = F.put_count!(fx, to, :no_grant_rows, 0)

      # a quiet date inside the window is not replaced by traffic outside it
      :ok = F.put_count!(fx, from, :requests, 0)
      {report, ok?} = eval(fx, fx.now)
      assert report.days_without_requests == 1
      assert report.criteria.every_day_has_requests == false
      assert report.requests == 140
      refute ok?
    end

    test "min_days + 1 dates are in the window for the default 7 and for a lowered value" do
      fx = F.shadow_tenant!("req519-e7b")
      :ok = F.satisfy!(fx, fx.now)
      {report, _ok?} = eval(fx, fx.now)
      assert Date.diff(report.window_to, report.window_from) == 7

      F.with_env(:scope_shadow_min_days, 2, fn ->
        {report, _ok?} = eval(fx, fx.now)
        assert Date.diff(report.window_to, report.window_from) == 2
        assert report.requests == 60
      end)
    end
  end

  # --- T-E8..T-E10: thresholds -----------------------------------------------------------------

  describe "T-E8 no request field or attrs key sets a threshold" do
    test "the API takes no thresholds: arities, and unknown flip attrs change nothing" do
      Code.ensure_loaded!(ShadowWindow)
      assert function_exported?(ShadowWindow, :evaluate, 3)
      refute function_exported?(ShadowWindow, :evaluate, 4)
      assert function_exported?(ShadowWindow, :thresholds, 0)
      refute function_exported?(ShadowWindow, :thresholds, 1)

      fx = F.admin_tenant!("req519-e8")
      before = ShadowWindow.thresholds()

      extra = %{
        min_days: 1,
        min_requests: 1,
        retention_days: 1,
        scope_shadow_min_days: 1,
        now: ~U[2000-01-01 00:00:00Z]
      }

      assert {:ok, %{mode: :shadow, changed: true}} =
               ScopeEnforcement.flip(
                 fx.tenant_id,
                 fx.schema_name,
                 :shadow,
                 Map.merge(F.attrs(fx, nil), extra)
               )

      assert ShadowWindow.thresholds() == before
    end
  end

  describe "T-E9 thresholds come from the application env, invalid values fall back to the default" do
    test "the defaults are the module attributes: 7 days, 100 requests, 90 days retention" do
      F.with_env(:scope_shadow_min_days, :unset, fn ->
        F.with_env(:scope_shadow_min_requests, :unset, fn ->
          F.with_env(:scope_shadow_retention_days, :unset, fn ->
            assert ShadowWindow.thresholds() == %{
                     min_days: 7,
                     min_requests: 100,
                     retention_days: 90
                   }
          end)
        end)
      end)
    end

    test "a non-integer or below-1 value is replaced by the DEFAULT (never by the floor); a valid integer is used" do
      keys = [
        {:scope_shadow_min_days, :min_days, 7},
        {:scope_shadow_min_requests, :min_requests, 100},
        {:scope_shadow_retention_days, :retention_days, 90}
      ]

      for {key, field, default} <- keys do
        for bad <- [0, -1, -100, 2.5, "7", nil, :seven, [], %{}] do
          F.with_env(key, bad, fn ->
            assert Map.fetch!(ShadowWindow.thresholds(), field) == default,
                   "#{key}=#{inspect(bad)} must fall back to #{default}"
          end)
        end

        for good <- [1, 3, 500] do
          F.with_env(key, good, fn ->
            assert Map.fetch!(ShadowWindow.thresholds(), field) == good
          end)
        end

        F.with_env(key, :unset, fn ->
          assert Map.fetch!(ShadowWindow.thresholds(), field) == default
        end)
      end
    end

    test "a lowered min_requests is honoured by the evaluation (the env really is the source)" do
      fx = F.shadow_tenant!("req519-e9")
      :ok = F.seed_requests!(fx, fx.now, 7, 1)

      {report, _ok?} = eval(fx, fx.now)
      assert report.criteria.requests == false

      F.with_env(:scope_shadow_min_requests, 8, fn ->
        {report, ok?} = eval(fx, fx.now)
        assert report.criteria.requests == true
        assert ok?
      end)
    end
  end

  describe "T-E9b the thresholds are set nowhere but the ShadowWindow module attributes" do
    setup do
      RuntimeConfigEval.isolate_env()
      :ok
    end

    test "the PRODUCTION configuration (config.exs + prod.exs + runtime.exs) sets none of the three keys" do
      letflow = prod_config() |> Keyword.get(:letflow, [])

      for key <- @threshold_keys do
        refute Keyword.has_key?(letflow, key), "#{key} is set in the production configuration"
      end
    end

    test "no config file names a threshold key or a threshold environment variable" do
      files = Path.wildcard("config/*.exs")
      assert "config/runtime.exs" in files
      assert "config/prod.exs" in files
      assert "config/test.exs" in files

      for path <- files, key <- @threshold_keys do
        refute File.read!(path) =~ Atom.to_string(key), "#{path} names #{key}"
      end

      for path <- files do
        refute File.read!(path) =~ ~r/SCOPE_SHADOW_(MIN|RETENTION)/i,
               "#{path} reads a threshold environment variable"
      end
    end

    test "lib names the threshold keys only in ShadowWindow (and the pruner's retention read and prose)" do
      lib_files = Path.wildcard("lib/**/*.ex")
      assert lib_files != []

      naming = fn key ->
        lib_files
        |> Enum.filter(&(File.read!(&1) =~ Atom.to_string(key)))
        |> Enum.sort()
      end

      window = "lib/letflow/scope_enforcement/shadow_window.ex"
      pruner = "lib/letflow/api/scope/shadow_evidence.ex"

      for key <- @threshold_keys do
        assert window in naming.(key)
        assert naming.(key) -- [window, pruner] == [], "#{key} is named outside ShadowWindow"
      end

      # the pruner reads ONLY its retention key
      pruner_text = File.read!(pruner)
      refute pruner_text =~ ~r/Application\.\w+\(\s*:letflow,\s*:scope_shadow_min_/

      # nothing reads the keys from the OS environment
      refute File.read!(window) =~ "System.get_env"
    end
  end

  describe "T-E10 the configuration criterion" do
    test "min_days > retention_days fails `configuration` (and only it); equal passes" do
      fx = F.shadow_tenant!("req519-e10")
      now = F.after_days(fx.t0, 3)
      :ok = F.seed_requests!(fx, now, 3, 50)

      F.with_env(:scope_shadow_min_days, 3, fn ->
        F.with_env(:scope_shadow_retention_days, 2, fn ->
          {report, ok?} = eval(fx, now)
          assert report.criteria == %{@all_true | configuration: false}
          refute ok?
        end)

        F.with_env(:scope_shadow_retention_days, 3, fn ->
          {report, ok?} = eval(fx, now)
          assert report.criteria == @all_true
          assert ok?
        end)
      end)
    end
  end

  # --- T-E11..T-E16 ----------------------------------------------------------------------------

  describe "T-E11 the injected clock" do
    test "the window follows the instant that is passed in" do
      fx = F.shadow_tenant!("req519-e11")
      a = F.after_days(fx.t0, 9)
      b = F.after_days(fx.t0, 20)

      {report_a, _} = eval(fx, a)
      {report_b, _} = eval(fx, b)

      assert report_a.window_to == DateTime.to_date(a)
      assert report_b.window_to == DateTime.to_date(b)
      assert report_a.window_from == Date.add(DateTime.to_date(a), -7)
      assert report_b.window_from == Date.add(DateTime.to_date(b), -7)
    end

    test "only a DateTime is accepted as the clock" do
      fx = F.admin_tenant!("req519-e11b")

      # opaque values, so the compiler's type checker does not (rightly) flag the bad calls
      text_clock = F.opaque("2026-01-01T00:00:00Z")
      no_clock = F.opaque(nil)

      assert_raise FunctionClauseError, fn ->
        ShadowWindow.evaluate(fx.tenant_id, fx.schema_name, text_clock)
      end

      assert_raise FunctionClauseError, fn ->
        ShadowWindow.evaluate(fx.tenant_id, fx.schema_name, no_clock)
      end
    end
  end

  describe "T-E12 the reason set" do
    test "the closed six-value set is exposed in order and the report carries exactly those keys" do
      assert ShadowEvidence.reasons() == @reasons

      fx = F.shadow_tenant!("req519-e12")
      {report, _ok?} = eval(fx, fx.now)

      assert Enum.sort(Map.keys(report.would_deny)) == Enum.sort(@reasons)
    end
  end

  describe "T-E13 counts_by_day/3" do
    test "equals the per-day sums of counts_between/3, absent days are absent, bounds inclusive" do
      fx = F.admin_tenant!("req519-e13")
      schema = fx.schema_name
      d1 = ~D[2026-02-10]
      d2 = ~D[2026-02-11]
      d3 = ~D[2026-02-12]
      d4 = ~D[2026-02-13]

      :ok = F.put_count!(fx, d1, :requests, 5)
      :ok = F.put_count!(fx, d1, :no_grant_rows, 2)
      :ok = F.put_count!(fx, d2, :requests, 7)
      :ok = F.put_count!(fx, d4, :out_of_scope, 1)
      :ok = F.put_count!(fx, Date.add(d1, -1), :requests, 99)
      :ok = F.put_count!(fx, Date.add(d4, 1), :requests, 99)

      by_day = ShadowEvidence.counts_by_day(schema, d1, d4)

      assert Enum.sort(Map.keys(by_day), Date) == [d1, d2, d4]
      refute Map.has_key?(by_day, d3)

      for day <- [d1, d2, d4] do
        assert by_day[day] == ShadowEvidence.counts_between(schema, day, day)
      end

      assert by_day[d1] == %{
               requests: 5,
               no_grant_rows: 2,
               role_not_held: 0,
               not_tenant_wide: 0,
               out_of_scope: 0,
               unresolvable: 0,
               grants_unavailable: 0
             }

      # a single day, both bounds inclusive
      assert Map.keys(ShadowEvidence.counts_by_day(schema, d2, d2)) == [d2]
      assert ShadowEvidence.counts_by_day(schema, ~D[2026-03-01], ~D[2026-03-09]) == %{}
    end

    test "is ONE statement, and ShadowWindow.evaluate/3 is two (no N+1 per day)" do
      fx = F.shadow_tenant!("req519-e13b")
      :ok = F.satisfy!(fx, fx.now)

      {_by_day, statements} =
        QueryCount.count_statements(fn ->
          ShadowEvidence.counts_by_day(fx.schema_name, first_date(fx.now), last_date(fx.now))
        end)

      assert statements == 1

      {{_report, true}, statements} = QueryCount.count_statements(fn -> eval(fx, fx.now) end)

      # one audit read for the shadow start, one grouped counter read
      assert statements == 2
    end

    test "validates the prefix like counts_between/3" do
      for bad <- ["public", "tenant_xyz", "tenant_" <> String.duplicate("A", 32), ""] do
        error =
          assert_raise ArgumentError, fn ->
            ShadowEvidence.counts_by_day(bad, ~D[2026-01-01], ~D[2026-01-02])
          end

        assert error.message == "invalid tenant schema prefix"
      end
    end
  end

  describe "T-E14 / T-E15 the statement of scope (AC 12)" do
    test "the constant is carried by the report and the audit shape" do
      assert ShadowWindow.evidence_scope() == @scope

      fx = F.shadow_tenant!("req519-e14")
      {report, _ok?} = eval(fx, fx.now)
      assert report.evidence_scope == @scope
    end

    test "the sentence docs/roles.md must carry (2f-b) is pinned verbatim at its source" do
      assert ShadowWindow.scope_sentence() == @sentence
    end
  end

  describe "T-E16 the flush before the gate reads" do
    test "a request counted just before the evaluation is visible after flush_evidence/0" do
      fx = F.admin_tenant!("req519-e16")
      schema = fx.schema_name
      today = Date.utc_today()

      for _n <- 1..3, do: :ok = ShadowEvidence.record(schema, :requests, today)

      # the in-memory counters are not persisted yet (the periodic flush is one hour in tests)
      assert ShadowEvidence.counts_by_day(schema, today, today) == %{}

      assert ShadowWindow.flush_evidence() == :ok

      by_day = ShadowEvidence.counts_by_day(schema, today, today)
      assert by_day[today].requests == 3
    end

    test "flush_evidence/0 returns :ok when there is nothing to flush" do
      assert ShadowWindow.flush_evidence() == :ok
    end
  end
end
