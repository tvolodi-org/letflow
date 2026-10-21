defmodule Letflow.Support.TenantFixturePoolTest do
  @moduledoc """
  Isolation proof for the module-scoped pooled tenant (ISS-1042 / Q-1042 / GH #2381).

  Spec: `test/specs/ISS-1042.md`. Design (spec of record):
  `lib/letflow/design/iss1042-pooled-tenant-fixture.md` section 9 -- the class ids M1..M22
  below are the design's own enumeration, not new ones.

  Real Postgres throughout (`Letflow.DataCase`, DIRECTIVE T-1): every dirty state is
  *constructed* by real SQL against a real pooled tenant schema, then the next acquire is
  checked by reading the database directly (`assert_pristine!/1`), not only by the pool's
  own report.

  ## No ordering assumption (design 9.1 / 9.2)

  Every test begins by asserting the slot is pristine and ends by leaving data behind, so a
  leak from ANY earlier test is caught by whichever test runs next, in any order. The
  deterministic boundary proof does not rely on that: `recycle_pool!/0` simulates the test
  boundary inside ONE test (acquire -> mutate -> report dirty -> recycle -> acquire ->
  pristine).

  ## Hooks

  `after_verify` / `after_guard` run in the pool WORKER, so a test drives them through
  `:persistent_term` (module-keyed), never through its own process dictionary.

  ## Audit (design 6.2) for this module

  Spawned processes are `Task`s (and a lock/transaction holder `Task`) that are always
  awaited or released before the test body returns; no `lib/` fire-and-forget worker is
  reachable (only `Repo`, `TenantFixture` and `TenantTemplate` are called); no ETS /
  `Application.put_env` / telemetry state is touched.
  """

  use Letflow.DataCase, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Letflow.Test.TenantTemplate
  alias Letflow.TenantFixture

  @a [slug_prefix: "pool-a", display_name: "Pool A"]
  @b [slug_prefix: "pool-b", display_name: "Pool B"]

  # Two occurrences of shape A and one of shape B (design 9: "two slot_specs of different
  # shapes plus a second occurrence of one shape for M11").
  setup_all context do
    TenantFixture.start_pool!(context,
      slots: [@a, @a, @b],
      parity_check: true,
      hooks: [
        after_verify: &__MODULE__.hook_after_verify/1,
        after_guard: &__MODULE__.hook_after_guard/1
      ]
    )
  end

  setup context do
    :ok = TenantFixture.attach_pool!(context)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :after_verify})
      :persistent_term.erase({__MODULE__, :after_guard})
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

      # the parent rows of the event_history_retirement_outcomes writer (not tenant-keyed)
      Repo.query!("DELETE FROM public.event_history_retirements WHERE year = 2099 AND month = 1")
    end)

    :ok
  end

  # -- worker-side hooks (run in the pool worker) ----------------------------------------

  def hook_after_verify(schema_name), do: run_hook(:after_verify, schema_name)
  def hook_after_guard(schema_name), do: run_hook(:after_guard, schema_name)

  defp run_hook(name, schema_name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      fun when is_function(fun, 1) -> fun.(schema_name)
      _none -> :ok
    end
  end

  defp put_hook(name, fun), do: :persistent_term.put({__MODULE__, name}, fun)
  defp clear_hook(name), do: :persistent_term.erase({__MODULE__, name})

  # -- small helpers ---------------------------------------------------------------------

  defp q!(sql), do: Repo.query!(sql)
  defp q!(sql, params), do: Repo.query!(sql, params)

  defp scalar!(sql, params), do: q!(sql, params).rows |> hd() |> hd()

  defp uniq, do: System.unique_integer([:positive])

  defp fx(:a), do: TenantFixture.provisioned_tenant!(@a)
  defp fx(:b), do: TenantFixture.provisioned_tenant!(@b)

  defp stats(ctx), do: TenantFixture.pool_stats(ctx.tenant_pool)

  defp new_reasons(before_stats, after_stats),
    do: Enum.drop(after_stats.fallback_reasons, length(before_stats.fallback_reasons))

  defp in_task(fun), do: fun |> Task.async() |> Task.await(60_000)

  defp in_task_or_here(:test, fun), do: fun.()
  defp in_task_or_here(:task, fun), do: in_task(fun)

  defp tr(schema), do: ~s("#{schema}")

  defp template_seed_md5(table) do
    scalar!(
      "SELECT md5(coalesce(string_agg(t::text, '|' ORDER BY t::text), '')) " <>
        "FROM #{TenantTemplate.template_schema_name()}.#{table} t",
      []
    )
  end

  defp seed_md5(schema, table) do
    scalar!(
      "SELECT md5(coalesce(string_agg(t::text, '|' ORDER BY t::text), '')) " <>
        "FROM #{tr(schema)}.#{table} t",
      []
    )
  end

  # Independent oracle (does not use the pool's own probe): every base table of the schema
  # with its true row count, via query_to_xml.
  defp row_counts(schema) do
    q!(
      """
      SELECT table_name,
             (xpath('/row/c/text()',
                    query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name),
                                 false, true, '')))[1]::text::int AS n
      FROM information_schema.tables
      WHERE table_schema = $1 AND table_type = 'BASE TABLE'
      ORDER BY 1
      """,
      [schema]
    ).rows
    |> Map.new(fn [table, n] -> {table, n} end)
  end

  defp nonseed_rows(schema) do
    schema
    |> row_counts()
    |> Enum.reject(fn {table, n} ->
      n == 0 or table in ["event_type_registry", "schema_migrations", "script_policy"]
    end)
    |> Enum.sort()
  end

  defp called_sequences(schema) do
    q!(
      "SELECT sequencename FROM pg_sequences WHERE schemaname = $1 AND last_value IS NOT NULL " <>
        "ORDER BY 1",
      [schema]
    ).rows
    |> List.flatten()
  end

  @public_keyed_tables ~w(event_history_retirement_outcomes secrets tenant_login_directory tenant_memberships)

  defp public_rows(tenant_id) do
    id = Ecto.UUID.dump!(tenant_id)

    for table <- @public_keyed_tables,
        n = scalar!("SELECT count(*) FROM public.#{table} WHERE tenant_id = $1", [id]),
        n > 0,
        do: {table, n}
  end

  defp trigger_state(schema) do
    q!(
      """
      SELECT c.relname, t.tgname, t.tgenabled::text
      FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND NOT t.tgisinternal ORDER BY 1, 2
      """,
      [schema]
    ).rows
  end

  defp assert_parity!(schema),
    do: TenantTemplate.assert_clone_parity!(TenantTemplate.template_schema_name(), schema)

  # The pristine contract of design 9.1(i): the pool's own report AND direct reads.
  defp assert_pristine!(fixture) do
    schema = fixture.schema_name

    assert %{
             clean?: true,
             dirty_tables: [],
             dirty_sequences: [],
             seeds_diverged: [],
             definition_drift: [],
             public_keyed_rows: [],
             tenant_row_diverged: false
           } = TenantFixture.pool_dirty_report(fixture)

    assert nonseed_rows(schema) == [], "a non-seed table holds rows in a pristine slot"
    assert called_sequences(schema) == []
    assert seed_md5(schema, "event_type_registry") == template_seed_md5("event_type_registry")
    assert seed_md5(schema, "schema_migrations") == template_seed_md5("schema_migrations")
    assert public_rows(fixture.tenant_id) == []

    assert [fixture.tenant.display_name, to_string(fixture.tenant.status)] ==
             scalar_row(
               "SELECT display_name, status FROM public.tenants WHERE id = $1",
               [Ecto.UUID.dump!(fixture.tenant_id)]
             )

    :ok
  end

  defp scalar_row(sql, params), do: q!(sql, params).rows |> hd()

  # -- writers -----------------------------------------------------------------------------
  # Each returns the list of tenant-schema tables it leaves rows in.

  defp write!(:groups, s) do
    q!(
      "INSERT INTO #{tr(s)}.groups (id, name, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1, now(), now())",
      ["g-#{uniq()}"]
    )

    ["groups"]
  end

  defp write!(:users, s) do
    q!(
      "INSERT INTO #{tr(s)}.users (id, username, display_name, email, password_hash, " <>
        "inserted_at, updated_at) VALUES (gen_random_uuid(), $1, 'u', $2, 'x', now(), now())",
      ["u-#{uniq()}", "u-#{uniq()}@example.test"]
    )

    ["users"]
  end

  # design M1: groups <- group_members -> users, tenant_role -> groups
  defp write!(:fk_chain, s) do
    n = uniq()
    # ISS-1058: ids are generated per call so the writer is repeatable in one schema between
    # resets (a generated list may draw :fk_chain twice; literal PKs raised 23505 mid-iteration).
    gid = Ecto.UUID.dump!(Ecto.UUID.generate())
    uid = Ecto.UUID.dump!(Ecto.UUID.generate())

    q!(
      "INSERT INTO #{tr(s)}.groups (id, name, inserted_at, updated_at) " <>
        "VALUES ($1, $2, now(), now())",
      [gid, "chain-g-#{n}"]
    )

    q!(
      "INSERT INTO #{tr(s)}.users (id, username, display_name, email, password_hash, " <>
        "inserted_at, updated_at) VALUES ($1, $2, 'u', $3, 'x', now(), now())",
      [uid, "chain-u-#{n}", "chain-#{n}@example.test"]
    )

    q!(
      "INSERT INTO #{tr(s)}.group_members (group_id, user_id, inserted_at) VALUES " <>
        "($1, $2, now())",
      [gid, uid]
    )

    q!(
      "INSERT INTO #{tr(s)}.tenant_role (id, name, group_id, inserted_at, kind) VALUES " <>
        "(gen_random_uuid(), $1, $2, now(), 'custom')",
      ["chain-r-#{n}", gid]
    )

    ["group_members", "groups", "tenant_role", "users"]
  end

  defp write!(:events, s) do
    q!(
      "INSERT INTO #{tr(s)}.events (event_id, instance_id, event_type, actor_id, " <>
        "sequence_number, idempotency_key) VALUES (gen_random_uuid(), gen_random_uuid(), " <>
        "'POOL_TEST', gen_random_uuid(), 1, $1)",
      ["idem-#{uniq()}"]
    )

    ["events"]
  end

  defp write!(:process_definitions, s) do
    q!(
      "INSERT INTO #{tr(s)}.process_definitions (id, name, version, created_by, created_at, " <>
        "updated_at) VALUES (gen_random_uuid(), $1, '1', gen_random_uuid(), now(), now())",
      ["pd-#{uniq()}"]
    )

    ["process_definitions"]
  end

  defp write!(:audit_entries, s) do
    q!(
      "INSERT INTO #{tr(s)}.audit_entries (id, tenant_id, action, resource_type, resource_id, " <>
        "timestamp, chain_hash, inserted_at) VALUES (gen_random_uuid(), gen_random_uuid(), " <>
        "'pool', 'pool', 'r', now(), 'h', now())"
    )

    ["audit_entries"]
  end

  defp write!(:tenant_modules, s) do
    q!(
      "INSERT INTO #{tr(s)}.tenant_modules (id, module_id, version, installed_at) " <>
        "VALUES (gen_random_uuid(), $1, '1', now())",
      ["m-#{uniq()}"]
    )

    ["tenant_modules"]
  end

  defp write!(:correlation_cursors, s) do
    q!(
      "INSERT INTO #{tr(s)}.correlation_cursors (correlation_id, tenant_id, created_at, " <>
        "updated_at) VALUES ($1, gen_random_uuid(), now(), now())",
      ["c-#{uniq()}"]
    )

    ["correlation_cursors"]
  end

  defp write!(:definition_sequence, s) do
    q!("INSERT INTO #{tr(s)}.definition_sequence (tenant_id) VALUES (gen_random_uuid())")
    ["definition_sequence"]
  end

  # design M2: the sequence advances and no row remains
  defp write!(:seq_only, s) do
    q!("SELECT nextval('#{tr(s)}.events_global_seq_seq')")
    []
  end

  defp insert_group!(schema), do: write!(:groups, schema)

  defp write_public!(tenant_id) do
    tid = Ecto.UUID.dump!(tenant_id)
    n = uniq()

    q!(
      "INSERT INTO public.tenant_login_directory (email_key, tenant_id, key_id, inserted_at) " <>
        "VALUES (decode(md5(random()::text) || md5(random()::text), 'hex'), $1, 'test-a', now())",
      [tid]
    )

    q!(
      "INSERT INTO public.tenant_memberships (id, subject_key, tenant_id, inserted_at, " <>
        "updated_at) VALUES (gen_random_uuid(), $1, $2, now(), now())",
      ["sub-#{n}", tid]
    )

    # FK-less keyed table, found by the `tenant_id` column-name rule only (design 5.1 (b)).
    q!(
      "INSERT INTO public.secrets (id, tenant_id, namespace, name, key_id, purpose, algorithm, " <>
        "wrapped_key_algorithm, ciphertext, wrapped_data_key, nonce, wrap_nonce, auth_tag, " <>
        "wrap_auth_tag, aad, wrapping_key_ref, created_at, created_by) VALUES " <>
        "(gen_random_uuid(), $1, 'pool', $2, 1, 'p', 'a', 'w', decode('00','hex'), " <>
        "decode('00','hex'), decode('00','hex'), decode('00','hex'), decode('00','hex'), " <>
        "decode('00','hex'), decode('00','hex'), 'ref', now(), 'pool-test')",
      [tid, "s-#{n}"]
    )

    # FK to tenants with `on_delete: :nothing`, behind a parent that is not tenant-keyed.
    retirement_id = Ecto.UUID.bingenerate()

    q!(
      "INSERT INTO public.event_history_retirements (id, year, month, status, requested_by, " <>
        "started_at) VALUES ($1, 2099, 1, 'completed', gen_random_uuid(), now())",
      [retirement_id]
    )

    q!(
      "INSERT INTO public.event_history_retirement_outcomes (id, retirement_id, tenant_id) " <>
        "VALUES (gen_random_uuid(), $1, $2)",
      [retirement_id, tid]
    )

    @public_keyed_tables |> Enum.sort() |> Enum.map(&{&1, 1})
  end

  defp write_tenant_rows!(tenant_id) do
    id = Ecto.UUID.dump!(tenant_id)

    q!(
      "UPDATE public.tenants SET status = 'inactive', display_name = 'mutated', " <>
        "settings = '{\"pool\":\"leak\"}'::jsonb WHERE id = $1",
      [id]
    )

    q!(
      "UPDATE public.tenant_schemas SET migrations_applied_at = " <>
        "coalesce(migrations_applied_at, now()) + interval '1 day' WHERE tenant_id = $1",
      [id]
    )
  end

  defp tenant_row_text(tenant_id) do
    id = Ecto.UUID.dump!(tenant_id)

    {scalar!("SELECT to_jsonb(t)::text FROM public.tenants t WHERE t.id = $1", [id]),
     scalar!("SELECT to_jsonb(r)::text FROM public.tenant_schemas r WHERE r.tenant_id = $1", [id])}
  end

  # Writes every row-level class (M1..M7 and M5) and returns the report the pool must give.
  defp mutate_everything!(fixture, via) do
    schema = fixture.schema_name

    in_task_or_here(via, fn ->
      write!(:fk_chain, schema)
      write!(:events, schema)
      write!(:seq_only, schema)

      # M3: seed UPDATE + DELETE + extra INSERT
      q!(
        "UPDATE #{tr(schema)}.event_type_registry SET description = 'leak' " <>
          "WHERE id = (SELECT id FROM #{tr(schema)}.event_type_registry ORDER BY id LIMIT 1)"
      )

      q!(
        "DELETE FROM #{tr(schema)}.event_type_registry " <>
          "WHERE id = (SELECT id FROM #{tr(schema)}.event_type_registry ORDER BY id DESC LIMIT 1)"
      )

      q!(
        "INSERT INTO #{tr(schema)}.event_type_registry (id, name, schema_version, json_schema, " <>
          "inserted_at, updated_at) VALUES (gen_random_uuid(), $1, 1, '{}'::jsonb, now(), now())",
        ["ZZ_POOL_EXTRA_#{uniq()}"]
      )

      # M4: a schema_migrations version row removed
      q!(
        "DELETE FROM #{tr(schema)}.schema_migrations WHERE version = " <>
          "(SELECT min(version) FROM #{tr(schema)}.schema_migrations)"
      )

      write_public!(fixture.tenant_id)
      write_tenant_rows!(fixture.tenant_id)
    end)

    %{
      dirty_tables: ["events", "group_members", "groups", "tenant_role", "users"],
      dirty_sequences: ["events_global_seq_seq"],
      seeds_diverged: ["event_type_registry", "schema_migrations"],
      definition_drift: [],
      public_keyed_rows: @public_keyed_tables |> Enum.sort() |> Enum.map(&{&1, 1}),
      tenant_row_diverged: true,
      clean?: false
    }
  end

  defp assert_report(actual, expected) do
    assert Map.update!(actual, :public_keyed_rows, &Enum.sort/1) == expected
  end

  # Holds a committed-in-nothing transaction open on a non-sandbox connection.
  defp hold_transaction(parent, sql_after_begin) do
    Task.async(fn ->
      Repo.transaction(
        fn ->
          Enum.each(sql_after_begin, &Repo.query!/1)
          send(parent, {:holding, self()})

          receive do
            :release -> :ok
          after
            60_000 -> :timeout
          end
        end,
        timeout: 120_000
      )
    end)
  end

  # ===========================================================================================
  # 9.1 / 9.2 -- cross-test and boundary proof for every row-level class (M1..M7)
  # ===========================================================================================

  describe "row-level leak classes: cross-test proof (design 9.1, no ordering assumption)" do
    for n <- 1..3, via <- [:test, :task] do
      test "leave-everything-behind test #{n} via #{via}: starts pristine, leaves data" do
        a = fx(:a)
        a2 = fx(:a)
        b = fx(:b)

        for fixture <- [a, a2, b], do: assert_pristine!(fixture)

        expected = mutate_everything!(a, unquote(via))
        # the "teeth" check: detection SEES the mutation, so "pristine next" is not vacuous
        assert_report(TenantFixture.pool_dirty_report(a), expected)

        # the other two slots are untouched (M11)
        assert %{clean?: true} = TenantFixture.pool_dirty_report(a2)
        assert %{clean?: true} = TenantFixture.pool_dirty_report(b)
      end
    end
  end

  describe "M1..M7 boundary proof (design 9.2)" do
    test "one test: acquire, mutate everything, report dirty, recycle, acquire, pristine", ctx do
      a = fx(:a)
      assert_pristine!(a)
      before = stats(ctx)
      expected = mutate_everything!(a, :test)
      assert_report(TenantFixture.pool_dirty_report(a), expected)

      TenantFixture.recycle_pool!()
      again = fx(:a)

      assert again.schema_name == a.schema_name
      assert_pristine!(again)
      assert_parity!(again.schema_name)

      after_stats = stats(ctx)
      # data-only dirt is RESET in place, never a rebuild
      assert after_stats.resets == before.resets + 1
      assert after_stats.rebuilds == before.rebuilds
      assert after_stats.generations[a.schema_name] == before.generations[a.schema_name]
    end

    test "M1: an FK chain is emptied through the explicit FK closure, in place", ctx do
      a = fx(:a)
      assert_pristine!(a)
      before = stats(ctx)
      write!(:fk_chain, a.schema_name)

      assert Enum.map(nonseed_rows(a.schema_name), &elem(&1, 0)) ==
               ["group_members", "groups", "tenant_role", "users"]

      TenantFixture.recycle_pool!()
      log = capture_log([level: :info], fn -> assert_pristine!(fx(:a)) end)

      after_stats = stats(ctx)
      assert after_stats.resets == before.resets + 1
      assert after_stats.rebuilds == before.rebuilds
      assert log =~ "phase=pool_acquire"
      assert log =~ "outcome=reset"
    end

    test "M1b: only `groups` dirty still truncates its referencing tables (closure_added)",
         ctx do
      a = fx(:a)
      assert_pristine!(a)
      before = stats(ctx)
      insert_group!(a.schema_name)
      assert %{dirty_tables: ["groups"]} = TenantFixture.pool_dirty_report(a)

      TenantFixture.recycle_pool!()
      log = capture_log([level: :info], fn -> assert_pristine!(fx(:a)) end)

      after_stats = stats(ctx)
      assert after_stats.resets == before.resets + 1

      assert after_stats.rebuilds == before.rebuilds,
             "closure missing -> TRUNCATE raised -> rebuilt"

      # tenant_role and group_members reference groups: exactly those two are added
      assert log =~ "phase=pool_reset"
      assert log =~ "dirty_tables=1 closure_added=2"
    end

    test "M2a: row inserted then DELETEd, sequence advanced, table empty", ctx do
      a = fx(:a)
      assert_pristine!(a)
      before = stats(ctx)

      write!(:events, a.schema_name)
      q!("DELETE FROM #{tr(a.schema_name)}.events")

      assert %{dirty_tables: [], dirty_sequences: ["events_global_seq_seq"], clean?: false} =
               TenantFixture.pool_dirty_report(a)

      TenantFixture.recycle_pool!()
      again = fx(:a)
      assert_pristine!(again)
      assert_parity!(again.schema_name)

      # the next insert is numbered from the start again
      write!(:events, again.schema_name)

      assert scalar!("SELECT global_seq FROM #{tr(again.schema_name)}.events", []) == 1
      assert stats(ctx).rebuilds == before.rebuilds
    end

    test "M2b: nextval only, no row was ever written", ctx do
      a = fx(:a)
      assert_pristine!(a)
      before = stats(ctx)
      write!(:seq_only, a.schema_name)

      assert %{dirty_tables: [], dirty_sequences: ["events_global_seq_seq"]} =
               TenantFixture.pool_dirty_report(a)

      TenantFixture.recycle_pool!()
      again = fx(:a)
      assert_pristine!(again)

      write!(:events, again.schema_name)
      assert scalar!("SELECT global_seq FROM #{tr(again.schema_name)}.events", []) == 1
      assert stats(ctx).rebuilds == before.rebuilds
    end

    test "M3: seed table UPDATE / DELETE / extra INSERT is restored from the template", ctx do
      a = fx(:a)
      assert_pristine!(a)
      before = stats(ctx)
      s = tr(a.schema_name)

      q!("UPDATE #{s}.event_type_registry SET description = 'leak'")
      q!("DELETE FROM #{s}.event_type_registry WHERE name = 'INSTANCE_STARTED'")

      q!(
        "INSERT INTO #{s}.event_type_registry (id, name, schema_version, json_schema, " <>
          "inserted_at, updated_at) VALUES (gen_random_uuid(), 'ZZ_EXTRA', 1, '{}', now(), now())"
      )

      assert %{seeds_diverged: ["event_type_registry"], dirty_tables: []} =
               TenantFixture.pool_dirty_report(a)

      TenantFixture.recycle_pool!()
      again = fx(:a)
      assert_pristine!(again)

      assert scalar!("SELECT count(*) FROM #{s}.event_type_registry", []) ==
               scalar!(
                 "SELECT count(*) FROM #{TenantTemplate.template_schema_name()}.event_type_registry",
                 []
               )

      assert stats(ctx).rebuilds == before.rebuilds
    end

    test "M3b: an emptied seed table is re-seeded, never left empty" do
      a = fx(:a)
      assert_pristine!(a)
      q!("TRUNCATE #{tr(a.schema_name)}.event_type_registry")
      assert %{seeds_diverged: ["event_type_registry"]} = TenantFixture.pool_dirty_report(a)

      TenantFixture.recycle_pool!()
      again = fx(:a)
      assert_pristine!(again)
      assert scalar!("SELECT count(*) FROM #{tr(again.schema_name)}.event_type_registry", []) > 0
    end

    test "M4: a deleted schema_migrations version row is restored" do
      a = fx(:a)
      assert_pristine!(a)
      s = tr(a.schema_name)

      q!(
        "DELETE FROM #{s}.schema_migrations WHERE version = (SELECT max(version) FROM #{s}.schema_migrations)"
      )

      assert %{seeds_diverged: ["schema_migrations"]} = TenantFixture.pool_dirty_report(a)

      TenantFixture.recycle_pool!()
      assert_pristine!(fx(:a))
    end

    test "M5: tenant-keyed public rows (incl. FK-less secrets) are deleted; others' are not",
         ctx do
      before = stats(ctx)
      a = fx(:a)
      b = fx(:b)
      assert_pristine!(a)
      assert_pristine!(b)

      expected = write_public!(a.tenant_id)
      write_public!(b.tenant_id)

      assert %{public_keyed_rows: rows, clean?: false} = TenantFixture.pool_dirty_report(a)
      assert Enum.sort(rows) == expected

      TenantFixture.recycle_pool!()
      again = fx(:a)

      assert public_rows(again.tenant_id) == []
      assert %{public_keyed_rows: []} = TenantFixture.pool_dirty_report(again)

      # slot B's keyed rows were not acquired, so they were not touched: the DELETE is
      # scoped by tenant id, not by table
      assert public_rows(b.tenant_id) |> Enum.sort() == expected

      again_b = fx(:b)
      assert public_rows(again_b.tenant_id) == []
      assert stats(ctx).rebuilds == before.rebuilds
    end

    test "M5b: the pool discovers keyed public tables from the catalog (design 5.1)", ctx do
      %{public_keyed: keyed} = :sys.get_state(ctx.tenant_pool.worker)
      discovered = keyed |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      # an independent formulation of the 5.1 rule
      %{rows: fk_rows} =
        q!("""
        SELECT DISTINCT c.relname
        FROM pg_constraint k
        JOIN pg_class c ON c.oid = k.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
        WHERE k.contype = 'f' AND k.confrelid = 'public.tenants'::regclass
        """)

      %{rows: name_rows} =
        q!("""
        SELECT DISTINCT c.relname
        FROM information_schema.columns col
        JOIN pg_class c ON c.relname = col.table_name AND c.relkind IN ('r', 'p')
        JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
        WHERE col.table_schema = 'public' AND col.data_type = 'uuid'
          AND (col.column_name IN ('tenant_id', 'owner_tenant_id')
               OR col.column_name LIKE '%\\_tenant\\_id')
        """)

      expected =
        (List.flatten(fk_rows) ++ List.flatten(name_rows))
        |> Enum.uniq()
        |> Kernel.--(["tenants", "tenant_schemas", "schema_migrations"])
        |> Enum.sort()

      assert discovered == expected

      for table <- @public_keyed_tables,
          do: assert(table in discovered, "#{table} must be discovered")

      refute "tenants" in discovered
      refute "tenant_schemas" in discovered

      # children-before-parents among the keyed tables (so the DELETE order cannot trip an FK)
      %{rows: edges} =
        q!(
          """
          SELECT cr.relname, pr.relname
          FROM pg_constraint k
          JOIN pg_class cr ON cr.oid = k.conrelid
          JOIN pg_class pr ON pr.oid = k.confrelid
          JOIN pg_namespace cn ON cn.oid = cr.relnamespace AND cn.nspname = 'public'
          JOIN pg_namespace pn ON pn.oid = pr.relnamespace AND pn.nspname = 'public'
          WHERE k.contype = 'f' AND cr.relname = ANY ($1::text[]) AND pr.relname = ANY ($1::text[])
            AND cr.oid <> pr.oid
          """,
          [discovered]
        )

      order = keyed |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      for [child, parent] <- edges do
        assert Enum.find_index(order, &(&1 == child)) < Enum.find_index(order, &(&1 == parent)),
               "#{child} must be deleted before #{parent}"
      end
    end

    test "M6: a changed tenants row is restored from its snapshot" do
      a = fx(:a)
      assert_pristine!(a)
      before = tenant_row_text(a.tenant_id)

      id = Ecto.UUID.dump!(a.tenant_id)

      q!(
        "UPDATE public.tenants SET status = 'inactive', display_name = 'mutated', " <>
          "settings = '{\"pool\":\"leak\"}'::jsonb WHERE id = $1",
        [id]
      )

      assert %{tenant_row_diverged: true, clean?: false} = TenantFixture.pool_dirty_report(a)
      refute tenant_row_text(a.tenant_id) == before

      TenantFixture.recycle_pool!()
      again = fx(:a)
      assert tenant_row_text(again.tenant_id) == before
      assert_pristine!(again)
    end

    test "M7: a changed tenant_schemas (Registration) row is restored from its snapshot" do
      a = fx(:a)
      assert_pristine!(a)
      {_tenant, registration_before} = tenant_row_text(a.tenant_id)
      id = Ecto.UUID.dump!(a.tenant_id)

      q!(
        "UPDATE public.tenant_schemas SET migrations_applied_at = " <>
          "coalesce(migrations_applied_at, now()) + interval '1 day' WHERE tenant_id = $1",
        [id]
      )

      assert %{tenant_row_diverged: true} = TenantFixture.pool_dirty_report(a)

      TenantFixture.recycle_pool!()
      again = fx(:a)
      {_tenant, registration_after} = tenant_row_text(again.tenant_id)
      assert registration_after == registration_before
      assert_pristine!(again)
    end
  end

  # ===========================================================================================
  # M8, M15..M21 -- committed DEFINITION drift with unchanged counts (F1): always a rebuild
  # ===========================================================================================

  @definition_mutations [
    m8a_new_table: [~s|CREATE TABLE "%S".zz_probe (id integer)|],
    m8b_dropped_trigger: [~s|DROP TRIGGER audit_entries_no_update ON "%S".audit_entries|],
    m15_disable_trigger: [
      ~s|ALTER TABLE "%S".audit_entries DISABLE TRIGGER audit_entries_no_update|
    ],
    m15b_disable_internal_ri_triggers: [~s|ALTER TABLE "%S".group_members DISABLE TRIGGER ALL|],
    m16a_column_default: [~s|ALTER TABLE "%S".groups ALTER COLUMN display_name SET DEFAULT 'x'|],
    m16b_not_null_dropped: [~s|ALTER TABLE "%S".groups ALTER COLUMN name DROP NOT NULL|],
    m16c_column_type: [~s|ALTER TABLE "%S".groups ALTER COLUMN description TYPE text|],
    m17_index_recreated_same_name: [
      ~s|DROP INDEX "%S".tenant_role_kind_index|,
      ~s|CREATE UNIQUE INDEX tenant_role_kind_index ON "%S".tenant_role (kind)|
    ],
    m18_constraint_recreated_same_name: [
      ~s|ALTER TABLE "%S".tenant_role DROP CONSTRAINT tenant_role_group_id_fkey|,
      ~s|ALTER TABLE "%S".tenant_role ADD CONSTRAINT tenant_role_group_id_fkey | <>
        ~s|FOREIGN KEY (group_id) REFERENCES "%S".groups(id) ON DELETE CASCADE|
    ],
    # MATCH FULL changes only pg_get_constraintdef: the RI trigger functions are the same
    # ones, so class G cannot see it (class K must).
    m18b_constraint_match_full: [
      ~s|ALTER TABLE "%S".tenant_role DROP CONSTRAINT tenant_role_group_id_fkey|,
      ~s|ALTER TABLE "%S".tenant_role ADD CONSTRAINT tenant_role_group_id_fkey | <>
        ~s|FOREIGN KEY (group_id) REFERENCES "%S".groups(id) MATCH FULL|
    ],
    m19_sequence_parameters: [~s|ALTER SEQUENCE "%S".events_global_seq_seq INCREMENT BY 7|],
    m19b_sequence_owned_by_none: [~s|ALTER SEQUENCE "%S".events_global_seq_seq OWNED BY NONE|],
    m20a_table_comment: [~s|COMMENT ON TABLE "%S".groups IS 'x'|],
    m20b_column_comment: [~s|COMMENT ON COLUMN "%S".groups.id IS 'x'|],
    m21_trigger_function_body: [
      ~s|CREATE OR REPLACE FUNCTION "%S".audit_entries_immutable() RETURNS trigger | <>
        ~s|LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END; $$|
    ]
  ]

  describe "definition drift is rebuilt, never repaired in place (design 9.3 M8, M15..M21)" do
    for {name, statements} <- @definition_mutations do
      test "#{name}: detected by the digest, slot rebuilt, structure equals a clone", ctx do
        a = fx(:a)
        assert_pristine!(a)
        schema = a.schema_name
        before = stats(ctx)
        triggers_before = trigger_state(schema)

        # data written by the SAME test as well: a rebuild must discard it too
        in_task(fn ->
          for sql <- unquote(statements) do
            q!(String.replace(sql, "%S", schema))
          end
        end)

        report = TenantFixture.pool_dirty_report(a)
        assert report.definition_drift != [], "the digest did not see #{unquote(name)}"
        assert report.clean? == false

        if unquote(name) in [:m15_disable_trigger, :m8b_dropped_trigger] do
          # teeth: a names+counts fingerprint of triggers would be unchanged for M15
          assert trigger_state(schema) != triggers_before
        end

        TenantFixture.recycle_pool!()
        again = fx(:a)

        assert again.schema_name == schema
        after_stats = stats(ctx)
        assert after_stats.rebuilds == before.rebuilds + 1
        assert after_stats.generations[schema] == before.generations[schema] + 1
        assert :definition_drift in new_reasons(before, after_stats)

        assert_pristine!(again)
        assert_parity!(schema)
        assert trigger_state(schema) == triggers_before
      end
    end

    test "M15: after the rebuild the immutability trigger is enabled and raises again" do
      a = fx(:a)
      assert_pristine!(a)
      s = tr(a.schema_name)
      write!(:audit_entries, a.schema_name)

      q!("ALTER TABLE #{s}.audit_entries DISABLE TRIGGER audit_entries_no_update")
      # with the trigger disabled the UPDATE succeeds: the only difference is `tgenabled`
      q!("UPDATE #{s}.audit_entries SET action = 'tampered'")

      TenantFixture.recycle_pool!()
      again = fx(:a)
      assert_pristine!(again)

      write!(:audit_entries, again.schema_name)

      assert_raise Postgrex.Error, ~r/audit_entries is immutable/, fn ->
        q!("UPDATE #{tr(again.schema_name)}.audit_entries SET action = 'tampered'")
      end
    end

    test "M18: after the rebuild the FK is not ON DELETE CASCADE again" do
      a = fx(:a)
      s = a.schema_name

      q!(~s|ALTER TABLE "#{s}".tenant_role DROP CONSTRAINT tenant_role_group_id_fkey|)

      q!(
        ~s|ALTER TABLE "#{s}".tenant_role ADD CONSTRAINT tenant_role_group_id_fkey | <>
          ~s|FOREIGN KEY (group_id) REFERENCES "#{s}".groups(id) ON DELETE CASCADE|
      )

      TenantFixture.recycle_pool!()
      again = fx(:a)

      assert scalar!(
               "SELECT confdeltype::text FROM pg_constraint WHERE conname = " <>
                 "'tenant_role_group_id_fkey' AND connamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1)",
               [again.schema_name]
             ) == "a"
    end

    test "M19: after the rebuild the sequence increment is 1 again" do
      a = fx(:a)
      q!(~s|ALTER SEQUENCE "#{a.schema_name}".events_global_seq_seq INCREMENT BY 7|)
      TenantFixture.recycle_pool!()
      again = fx(:a)

      assert scalar!(
               "SELECT seqincrement FROM pg_sequence WHERE seqrelid = $1::text::regclass",
               ["#{tr(again.schema_name)}.events_global_seq_seq"]
             ) == 1
    end

    test "M20: after the rebuild the comments are NULL again" do
      a = fx(:a)
      q!(~s|COMMENT ON TABLE "#{a.schema_name}".groups IS 'x'|)
      TenantFixture.recycle_pool!()
      again = fx(:a)

      assert scalar!("SELECT obj_description($1::text::regclass, 'pg_class')", [
               "#{tr(again.schema_name)}.groups"
             ]) == nil
    end
  end

  # ===========================================================================================
  # M9 fail-safe, M10 late writer, M13 post-verify writers, M14 straggler
  # ===========================================================================================

  describe "fail-safe and writers outside the test (design 9.3 M9, M10, M13, M14)" do
    test "M9: a lock the reset cannot take times out; the result is a rebuild or a raise, never dirt",
         ctx do
      a = fx(:a)
      assert_pristine!(a)
      schema = a.schema_name
      insert_group!(schema)
      TenantFixture.recycle_pool!()
      before = stats(ctx)

      # SHARE blocks the reset's TRUNCATE (ACCESS EXCLUSIVE) but not the probes. The last
      # statement text does not name the schema, so fence A does not see this holder.
      holder =
        hold_transaction(self(), [
          ~s|SET LOCAL search_path TO "#{schema}"|,
          "LOCK TABLE groups IN SHARE MODE",
          "SELECT 1"
        ])

      assert_receive {:holding, holder_pid}, 15_000

      # Release only once the rebuild's DROP SCHEMA is itself waiting on the lock, i.e. once
      # the reset has provably timed out (event-driven; the deadline is a bound, not a sleep).
      releaser =
        Task.async(fn ->
          deadline = System.monotonic_time(:millisecond) + 25_000
          wait_for_drop_waiter(schema, deadline)
          send(holder_pid, :release)
        end)

      log = capture_log([level: :info], fn -> send(self(), {:result, fx(:a)}) end)
      assert_received {:result, result}
      Task.await(releaser, 60_000)
      assert {:ok, :ok} = Task.await(holder, 60_000)

      # the reset gave up because of the server-side lock_timeout, not because the client
      # connection timed out 15 s later
      assert log =~ "lock timeout"

      after_stats = stats(ctx)
      assert result.schema_name == schema

      assert after_stats.rebuilds == before.rebuilds + 1,
             "the reset did not time out into a rebuild"

      assert :verify_failed in new_reasons(before, after_stats)
      assert_pristine!(result)
    end

    test "M10: a late writer between tests (test process or spawned) is caught by the next acquire",
         ctx do
      a = fx(:a)
      assert_pristine!(a)
      TenantFixture.recycle_pool!()

      # simulated stragglers that write AFTER the "test" returned
      insert_group!(a.schema_name)
      in_task(fn -> write!(:events, a.schema_name) end)
      write_public!(a.tenant_id)

      before = stats(ctx)
      again = fx(:a)
      assert_pristine!(again)
      assert stats(ctx).resets == before.resets + 1
    end

    test "M13a: a writer after verify is caught by the final guard; the returned tenant is empty",
         ctx do
      a = fx(:a)
      assert_pristine!(a)
      TenantFixture.recycle_pool!()
      before = stats(ctx)

      counter = :counters.new(1, [])

      put_hook(:after_verify, fn schema ->
        if :counters.get(counter, 1) == 0 do
          :counters.add(counter, 1, 1)
          Repo.query!("SELECT nextval('#{tr(schema)}.events_global_seq_seq')")
          write!(:groups, schema)
        end
      end)

      again = fx(:a)
      clear_hook(:after_verify)

      after_stats = stats(ctx)
      assert after_stats.final_guard_resets == before.final_guard_resets + 1
      assert :final_guard in new_reasons(before, after_stats)
      assert_pristine!(again)
    end

    test "M13b: a persistent writer makes the acquire raise pool_straggler; no map is returned" do
      a = fx(:a)
      TenantFixture.recycle_pool!()
      schema = a.schema_name

      put_hook(:after_verify, fn schema -> write!(:groups, schema) end)

      e = assert_raise ExUnit.AssertionError, fn -> fx(:a) end
      clear_hook(:after_verify)

      assert e.message =~ "pool_straggler"
      assert e.message =~ schema

      # containment: the next acquire (writer gone) is pristine again
      assert_pristine!(fx(:a))
    end

    test "M13c: a write after the final guard is visible to the owner only; next acquire pristine" do
      assert_pristine!(fx(:a))
      TenantFixture.recycle_pool!()

      put_hook(:after_guard, fn schema -> write!(:groups, schema) end)
      again = fx(:a)
      clear_hook(:after_guard)

      # not detectable by construction (RR-1): documented, asserted
      assert nonseed_rows(again.schema_name) == [{"groups", 1}]
      assert %{dirty_tables: ["groups"], clean?: false} = TenantFixture.pool_dirty_report(again)

      TenantFixture.recycle_pool!()
      assert_pristine!(fx(:a))
    end

    test "M14: an idle-in-transaction straggler makes pool_end_fence!/0 raise, naming it" do
      a = fx(:a)
      assert_pristine!(a)
      schema = a.schema_name

      holder =
        hold_transaction(self(), [
          "INSERT INTO #{tr(schema)}.groups (id, name, inserted_at, updated_at) " <>
            "VALUES (gen_random_uuid(), 'straggler', now(), now())"
        ])

      assert_receive {:holding, holder_pid}, 15_000

      e = assert_raise ExUnit.AssertionError, fn -> TenantFixture.pool_end_fence!() end
      assert e.message =~ schema
      assert e.message =~ "idle in transaction"
      assert e.message =~ "backend pid="
      assert e.message =~ "groups"

      # fence A at the next acquire refuses it too (it never waves a straggler through)
      e2 = assert_raise ExUnit.AssertionError, fn -> fx(:a) end
      assert e2.message =~ "pool_straggler"

      send(holder_pid, :release)
      assert {:ok, :ok} = Task.await(holder, 30_000)

      # released and committed: its row is dirt, the next acquire is pristine
      TenantFixture.recycle_pool!()
      assert_pristine!(fx(:a))
    end
  end

  defp wait_for_drop_waiter(schema, deadline) do
    waiting =
      scalar!(
        """
        SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event_type = 'Lock'
          AND query LIKE 'DROP SCHEMA%' AND strpos(query, $1) > 0
        """,
        [schema]
      )

    cond do
      waiting > 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :deadline

      true ->
        Process.sleep(20)
        wait_for_drop_waiter(schema, deadline)
    end
  end

  # ===========================================================================================
  # M11 / M12 / M22 -- bleed, default path, argument rejection
  # ===========================================================================================

  describe "slots, default path, rejection (design 9.3 M11, M12, M22, section 8)" do
    test "M11: dirt in one slot does not touch, or reset, the others", ctx do
      a = fx(:a)
      a2 = fx(:a)
      b = fx(:b)
      assert Enum.uniq([a.schema_name, a2.schema_name, b.schema_name]) |> length() == 3
      assert Enum.uniq([a.tenant_id, a2.tenant_id, b.tenant_id]) |> length() == 3

      write!(:fk_chain, a.schema_name)
      assert %{clean?: true} = TenantFixture.pool_dirty_report(a2)
      assert %{clean?: true} = TenantFixture.pool_dirty_report(b)
      assert nonseed_rows(a2.schema_name) == []
      assert nonseed_rows(b.schema_name) == []

      before = stats(ctx)
      TenantFixture.recycle_pool!()
      for shape <- [:a, :a, :b], do: assert_pristine!(fx(shape))

      after_stats = stats(ctx)
      assert after_stats.resets == before.resets + 1, "only slot A may have been reset"
      assert after_stats.rebuilds == before.rebuilds
      assert after_stats.dirty_tables_truncated == before.dirty_tables_truncated + 4
    end

    test "M12: pool: false, template: :replay and teardown: false take the unchanged default path",
         ctx do
      pooled = fx(:a)
      slot_schemas = Map.keys(stats(ctx).generations)

      # Registered BEFORE any default-path provisioning: ExUnit runs on_exit callbacks in
      # reverse order, so this one runs AFTER the fixture's own per-test teardown.
      key = {__MODULE__, :default_path, make_ref()}
      :persistent_term.put(key, [])

      on_exit(fn ->
        for {schema, tenant_id, teardown?} <- :persistent_term.get(key) do
          Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

          if teardown? do
            assert scalar!(
                     "SELECT count(*) FROM information_schema.schemata WHERE schema_name = $1",
                     [schema]
                   ) == 0,
                   "the default path's own teardown must drop #{schema}"

            assert scalar!("SELECT count(*) FROM public.tenants WHERE id = $1", [
                     Ecto.UUID.dump!(tenant_id)
                   ]) == 0
          else
            drop_tenant!(schema, tenant_id)
          end
        end

        :persistent_term.erase(key)
      end)

      for opts <- [
            Keyword.put(@a, :pool, false),
            Keyword.put(@a, :teardown, false),
            Keyword.put(@a, :template, :replay)
          ] do
        default = TenantFixture.provisioned_tenant!(opts)

        :persistent_term.put(key, [
          {default.schema_name, default.tenant_id, opts[:teardown] != false}
          | :persistent_term.get(key)
        ])

        refute default.schema_name in slot_schemas
        refute default.schema_name == pooled.schema_name
        assert Map.keys(default) |> Enum.sort() == [:schema_name, :tenant, :tenant_id]

        # a real, complete tenant on the ordinary path
        assert scalar!(
                 "SELECT count(*) FROM information_schema.tables WHERE table_schema = $1",
                 [default.schema_name]
               ) > 40
      end

      # the pooled slot itself was not disturbed by any of that
      assert_pristine!(pooled)
    end

    test "M22: a second attach_pool!/1 in an attached process raises, handing out nothing",
         ctx do
      before = stats(ctx)
      assert_raise ArgumentError, ~r/twice/, fn -> TenantFixture.attach_pool!(ctx) end
      assert stats(ctx).acquires == before.acquires
    end

    test "an undeclared shape raises ArgumentError instead of cloning, and hands out nothing",
         ctx do
      before = stats(ctx)

      assert_raise ArgumentError, ~r/did not declare/, fn ->
        TenantFixture.provisioned_tenant!(slug_prefix: "pool-never-declared")
      end

      # a third occurrence of a shape declared twice
      _a = fx(:a)
      _a2 = fx(:a)

      assert_raise ArgumentError, ~r/did not declare/, fn -> fx(:a) end

      assert stats(ctx).clones == before.clones, "no slot may be cloned lazily from a test"
      assert stats(ctx).slots == 3
    end

    test "async / unknown-async / empty / unknown-key / duplicate pools are rejected, loudly",
         ctx do
      assert_raise ArgumentError, ~r/async: false/, fn ->
        TenantFixture.start_pool!(%{module: __MODULE__, async: true}, slots: [@a])
      end

      assert_raise ArgumentError, ~r/async: false/, fn ->
        TenantFixture.start_pool!(%{module: __MODULE__}, slots: [@a])
      end

      assert_raise ArgumentError, ~r/non-empty :slots/, fn ->
        TenantFixture.start_pool!(%{module: __MODULE__, async: false}, slots: [])
      end

      assert_raise ArgumentError, ~r/unknown slot_spec keys/, fn ->
        TenantFixture.start_pool!(%{module: __MODULE__, async: false}, slots: [[bogus: 1]])
      end

      assert_raise ArgumentError, ~r/already registered/, fn ->
        TenantFixture.start_pool!(Map.put(ctx, :async, false), slots: [@a])
      end

      assert_raise ArgumentError, ~r/async: false/, fn ->
        TenantFixture.attach_pool!(%{async: true, tenant_pool: ctx.tenant_pool})
      end

      assert_raise ArgumentError, ~r/no :tenant_pool/, fn ->
        TenantFixture.attach_pool!(%{async: false})
      end
    end
  end

  defp drop_tenant!(schema, tenant_id) do
    id = Ecto.UUID.dump!(tenant_id)
    Repo.query!(~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|)
    Repo.query!("DELETE FROM public.tenant_schemas WHERE tenant_id = $1", [id])
    Repo.query!("DELETE FROM public.tenants WHERE id = $1", [id])
  end

  # ===========================================================================================
  # Rebuild bookkeeping (design 4.6 / INV-P8)
  # ===========================================================================================

  describe "rebuild refreshes the baseline, the Registration snapshot and the generation" do
    test "after a rebuild the next acquire is clean and does not rebuild again", ctx do
      a = fx(:a)
      assert_pristine!(a)
      s = a.schema_name
      reg_id_before = registration_id(a.tenant_id)

      q!(~s|CREATE TABLE "#{s}".zz_probe (id integer)|)
      TenantFixture.recycle_pool!()

      before = stats(ctx)
      rebuilt = fx(:a)
      assert_pristine!(rebuilt)

      assert registration_id(a.tenant_id) != reg_id_before,
             "premise: a rebuild inserts a NEW Registration row"

      mid = stats(ctx)
      assert mid.rebuilds == before.rebuilds + 1
      assert mid.generations[s] == before.generations[s] + 1

      # the SECOND acquire proves the snapshot and baseline were refreshed: a stale
      # registration snapshot would read as a diverged row forever and rebuild again
      TenantFixture.recycle_pool!()
      reg_id_mid = registration_id(a.tenant_id)
      again = fx(:a)
      assert_pristine!(again)

      final = stats(ctx)
      assert final.rebuilds == mid.rebuilds
      assert final.resets == mid.resets
      assert final.generations[s] == mid.generations[s]
      assert registration_id(a.tenant_id) == reg_id_mid
    end

    test "a rebuilt slot is re-baselined: a SECOND, different drift is detected and rebuilt",
         ctx do
      a = fx(:a)
      s = a.schema_name
      q!(~s|COMMENT ON TABLE "#{s}".groups IS 'first'|)
      TenantFixture.recycle_pool!()
      _ = fx(:a)

      before = stats(ctx)
      q!(~s|COMMENT ON TABLE "#{s}".groups IS 'second'|)
      TenantFixture.recycle_pool!()
      again = fx(:a)

      assert stats(ctx).generations[s] == before.generations[s] + 1
      assert_pristine!(again)
    end

    test "design 4.4: a seed re-copy that cannot reproduce the baseline fails verify and rebuilds",
         ctx do
      a = fx(:a)
      assert_pristine!(a)
      s = a.schema_name
      before = stats(ctx)

      # Simulates "the live template was rebuilt mid-module": the slot's baseline remembers
      # a seed digest that a re-copy from the template can no longer produce. (The shared
      # template is deliberately NOT touched: a crash mid-test would poison later runs.)
      :sys.replace_state(ctx.tenant_pool.worker, fn state ->
        update_in(state.slots, fn slots ->
          Map.new(slots, fn {key, slot} ->
            if slot.schema_name == s do
              stale =
                put_in(slot.baseline.state.seed_digests["event_type_registry"], {999, "stale"})

              {key, stale}
            else
              {key, slot}
            end
          end)
        end)
      end)

      TenantFixture.recycle_pool!()
      again = fx(:a)

      after_stats = stats(ctx)
      assert after_stats.rebuilds == before.rebuilds + 1, "verify did not reject the re-copy"
      assert :verify_failed in new_reasons(before, after_stats)
      assert after_stats.generations[s] == before.generations[s] + 1
      assert_pristine!(again)

      # the rebuild replaced the baseline with the truth: the next acquire is clean
      TenantFixture.recycle_pool!()
      assert_pristine!(fx(:a))
      assert stats(ctx).rebuilds == after_stats.rebuilds
    end
  end

  defp registration_id(tenant_id),
    do:
      scalar!("SELECT id FROM public.tenant_schemas WHERE tenant_id = $1", [
        Ecto.UUID.dump!(tenant_id)
      ])

  # ===========================================================================================
  # Property: any subset of writers, from the test process or a Task, is gone next acquire
  # ===========================================================================================

  # ISS-1058 (Q-1058 / GH #2406): the whole body of the property, shared with the fixed
  # regression cases below so they cannot drift apart.
  #
  # Starts with `recycle_pool!/0`: StreamData re-runs the body in the SAME test process
  # (shrinking), and an aborted attempt never reaches its closing recycle, so the per-process
  # claims map would leak and `fx(:a)` would claim the SECOND declared @a slot. The recycle
  # changes no slot data (reset stays lazy at acquire), it only gives every attempt the
  # precondition the first one has: empty claims.
  defp assert_boundary_invisible!(writers, via) do
    TenantFixture.recycle_pool!()

    a = fx(:a)
    assert %{clean?: true} = TenantFixture.pool_dirty_report(a)

    touched =
      in_task_or_here(via, fn ->
        Enum.flat_map(writers, &write!(&1, a.schema_name))
      end)
      |> Enum.uniq()
      |> Enum.sort()

    report = TenantFixture.pool_dirty_report(a)
    assert report.dirty_tables == touched

    if Enum.any?(writers, &(&1 in [:events, :seq_only])) do
      assert report.dirty_sequences == ["events_global_seq_seq"]
    end

    TenantFixture.recycle_pool!()
    again = fx(:a)

    # Before any content assertion: the schema inspected below must be the one that was
    # written to. Otherwise a leaked claims map makes `again` a different slot and the content
    # assertions read a neighbouring slot (the misleading [{"groups", 1}] of ISS-1058).
    assert again.schema_name == a.schema_name,
           "post-boundary claim attached a different slot (#{again.schema_name} vs written " <>
             "#{a.schema_name}); the claims map leaked or slots were reordered"

    assert %{clean?: true} = TenantFixture.pool_dirty_report(again)
    assert nonseed_rows(a.schema_name) == []
    assert called_sequences(a.schema_name) == []
    TenantFixture.recycle_pool!()
    :ok
  end

  # Deterministic stand-in for an iteration aborted by an in-body raise: one claim made and
  # left in the claims map, one row left in that slot, no recycle.
  defp abort_attempt! do
    a = fx(:a)
    write!(:groups, a.schema_name)
    gid = Ecto.UUID.dump!(Ecto.UUID.generate())

    ins = fn ->
      Repo.query!(
        "INSERT INTO #{tr(a.schema_name)}.groups (id, name, inserted_at, updated_at) " <>
          "VALUES ($1, $2, now(), now())",
        [gid, "abort-#{uniq()}"]
      )
    end

    ins.()

    assert_raise Postgrex.Error, ~r/unique|23505/, fn ->
      # a failed statement outside a transaction does not poison the connection
      ins.()
    end

    :ok
  end

  describe "property (design 9.1 generalised)" do
    @prop_writers [
      :groups,
      :users,
      :fk_chain,
      :events,
      :process_definitions,
      :audit_entries,
      :tenant_modules,
      :correlation_cursors,
      :definition_sequence,
      :seq_only
    ]

    test "any set of row writers is invisible after the boundary, and never rebuilds",
         %{tenant_pool: pool} do
      rebuilds = TenantFixture.pool_stats(pool).rebuilds

      check all(
              writers <- list_of(member_of(@prop_writers), min_length: 1, max_length: 5),
              via <- member_of([:test, :task]),
              max_runs: 12
            ) do
        assert_boundary_invisible!(writers, via)
      end

      assert TenantFixture.pool_stats(pool).rebuilds == rebuilds
    end
  end

  # ISS-1058 (Q-1058 / GH #2406; docs/issues/ISS-1058.yaml). ExUnit's --seed is not a property
  # parameter, so the failing seeds are pinned by encoding their failing sequences:
  # seed 193355 (local, 56/57) and seed 40898 (CI run 38235738863, shard 3/3 partition 11).
  # Root cause: duplicate :fk_chain raised 23505 inside an iteration, the abort skipped the
  # closing recycle, the leaked claims map made the shrink re-run claim slot 2 and assert on
  # slot 1's schema (test defect, no pool hole).
  describe "ISS-1058 claims leak after an aborted iteration" do
    test "C1 [:fk_chain, :fk_chain] via :test" do
      assert_boundary_invisible!([:fk_chain, :fk_chain], :test)
    end

    test "C1b [:fk_chain, :fk_chain] via :task" do
      assert_boundary_invisible!([:fk_chain, :fk_chain], :task)
    end

    test "C2 aborted attempt, then [:groups] via :test (seed 193355 shrunk case)" do
      abort_attempt!()
      assert_boundary_invisible!([:groups], :test)
    end

    test "C3 two aborted attempts, then [:groups] via :test (seed 40898 tail)" do
      abort_attempt!()
      abort_attempt!()
      assert_boundary_invisible!([:groups], :test)
    end

    test "C4 claims are positional: after an abort fx(:a) is the other slot, recycle resets" do
      first = fx(:a)
      TenantFixture.recycle_pool!()
      assert fx(:a).schema_name == first.schema_name
      TenantFixture.recycle_pool!()

      abort_attempt!()
      assert fx(:a).schema_name != first.schema_name
      TenantFixture.recycle_pool!()
      assert fx(:a).schema_name == first.schema_name
    end
  end

  # ISS-1061 (Q-1054 / GH #2400; docs/issues/ISS-1061.yaml). The pool's reset/drop paths
  # must never run against a database that is not the configured test database. Refusal
  # tests use a fresh module atom so no pool is registered and nothing leaks.
  describe "ISS-1061 database guard" do
    @wrong_db "letflow_test_not_this_db"

    test "T1 the guard accepts the real configured database" do
      assert :ok == TenantFixture.assert_test_database!()
      assert :ok == TenantFixture.assert_test_database!(Repo.config()[:database])
    end

    test "T2 a mismatching database name is refused, naming both databases" do
      actual = Repo.query!("SELECT current_database()").rows |> hd() |> hd()

      error =
        assert_raise ArgumentError, ~r/but the configured test database is/, fn ->
          TenantFixture.assert_test_database!(@wrong_db)
        end

      assert error.message =~ inspect(actual)
      assert error.message =~ inspect(@wrong_db)
    end

    test "T3 a non-letflow_test expected name is refused before any comparison" do
      assert_raise ArgumentError, ~r/is not a letflow_test\* database/, fn ->
        TenantFixture.assert_test_database!("letflow_dev")
      end
    end

    test "T4 start_pool!/2 refuses before provisioning, cloning or registering anything",
         ctx do
      fresh = Module.concat(__MODULE__, "GuardRefusal#{System.unique_integer([:positive])}")
      slug = "guard-refusal-#{System.unique_integer([:positive])}"

      count = fn sql -> Repo.query!(sql).rows |> hd() |> hd() end
      schemas = "SELECT count(*) FROM pg_namespace WHERE nspname LIKE 'tenant_%'"
      tenants = "SELECT count(*) FROM public.tenants"
      slug_rows = "SELECT count(*) FROM public.tenants WHERE slug LIKE '#{slug}%'"

      before = {count.(schemas), count.(tenants)}
      stats_before = TenantFixture.pool_stats(ctx.tenant_pool)

      assert_raise ArgumentError, ~r/but the configured test database is/, fn ->
        TenantFixture.start_pool!(%{module: fresh, async: false},
          slots: [[slug_prefix: slug, display_name: "Guard Refusal"]],
          expected_database: @wrong_db
        )
      end

      assert Process.whereis(TenantFixture.pool_name(fresh)) == nil
      assert count.(slug_rows) == 0
      assert {count.(schemas), count.(tenants)} == before
      assert TenantFixture.pool_stats(ctx.tenant_pool) == stats_before
    end

    test "T5 the worker's own init refuses a mismatching database" do
      fresh = Module.concat(__MODULE__, "GuardWorker#{System.unique_integer([:positive])}")

      capture_log(fn -> send(self(), {:result, start_unguarded(fresh)}) end)

      assert_received {:result, {:error, {%ArgumentError{message: message}, _stack}}}
      assert message =~ "but the configured test database is"
    end
  end

  defp start_unguarded(module) do
    result =
      GenServer.start(Letflow.TenantFixture.Pool, %{
        module: module,
        expected_database: "letflow_test_not_this_db"
      })

    # A mutant that lets the worker start must not leak a live, unregistered process.
    with {:ok, pid} <- result, do: GenServer.stop(pid)
    result
  end
end

defmodule Letflow.Support.TenantFixturePoolMisorderTest do
  @moduledoc """
  M22 (design 3.1 / REVIEWER R3): a pooled module whose per-test setup does NOT attach.

  `provisioned_tenant!/1` must raise `ArgumentError` rather than silently clone per test.
  The detection rests on `owning_module/0` and `test_process?/0`, which rescue to
  nil / false when ExUnit's internals change; that would silently DISABLE the rejection
  (falling back to a per-test clone: slower, not unsafe). This module therefore asserts
  that the rejection still FIRES against the installed ExUnit.
  """

  use Letflow.DataCase, async: false

  alias Letflow.TenantFixture

  # Audit (design 6.2): no spawn, no lib/ worker; only TenantFixture is called.
  setup_all context do
    TenantFixture.start_pool!(context, slots: [[slug_prefix: "pool-misorder"]])
  end

  # Deliberately NO `setup` that calls attach_pool!/1.

  test "provisioned_tenant!/1 without attach_pool!/1 raises (the rejection still fires)" do
    e =
      assert_raise ArgumentError, fn ->
        TenantFixture.provisioned_tenant!(slug_prefix: "pool-misorder")
      end

    assert e.message =~ "before attach_pool!/1"
    assert e.message =~ "FIRST setup"
    assert e.message =~ inspect(__MODULE__)
  end

  test "after the rejection, attaching then claiming works and nothing was double-handed",
       ctx do
    assert_raise ArgumentError, ~r/before attach_pool!/, fn ->
      TenantFixture.provisioned_tenant!(slug_prefix: "pool-misorder")
    end

    assert TenantFixture.pool_stats(ctx.tenant_pool).acquires == 0

    :ok = TenantFixture.attach_pool!(ctx)
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: "pool-misorder")

    assert %{clean?: true} = TenantFixture.pool_dirty_report(fixture)
    assert TenantFixture.pool_stats(ctx.tenant_pool).acquires == 1
  end

  test "pool: false is NOT rejected (only a poolable call is)", ctx do
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: "pool-misorder", pool: false)
    refute fixture.schema_name in Map.keys(TenantFixture.pool_stats(ctx.tenant_pool).generations)
  end
end

defmodule Letflow.Support.TenantFixturePoolFirstAcquireTest do
  @moduledoc """
  F5 / INV-P12: the FIRST acquire of a slot runs the full proof, exactly like every later
  one. A slot is dirtied between creation and its first acquire (data in one slot,
  definition drift in the other); a "status :clean -> skip" optimisation would hand both
  out dirty.

  One test only, so which test is "first" cannot depend on ExUnit's order.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.TenantFixture

  @x [slug_prefix: "pool-fa-x"]
  @y [slug_prefix: "pool-fa-y"]

  # Audit (design 6.2): no spawn, no lib/ worker; only TenantFixture and Repo are called.
  setup_all context do
    [tenant_pool: pool] = TenantFixture.start_pool!(context, slots: [@x, @y])
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    slots = :sys.get_state(pool.worker).slots
    {_k, x} = Enum.find(slots, fn {{shape, _}, _} -> shape.slug_prefix == "pool-fa-x" end)
    {_k, y} = Enum.find(slots, fn {{shape, _}, _} -> shape.slug_prefix == "pool-fa-y" end)

    # X: data dirt (row + advanced sequence + a tenant-keyed public row)
    Repo.query!(
      ~s|INSERT INTO "#{x.schema_name}".groups (id, name, inserted_at, updated_at) | <>
        ~s|VALUES (gen_random_uuid(), 'first', now(), now())|
    )

    Repo.query!(~s|SELECT nextval('"#{x.schema_name}".events_global_seq_seq')|)

    Repo.query!(
      "INSERT INTO public.tenant_memberships (id, subject_key, tenant_id, inserted_at, " <>
        "updated_at) VALUES (gen_random_uuid(), 'fa-sub', $1, now(), now())",
      [Ecto.UUID.dump!(x.tenant_id)]
    )

    # Y: definition drift whose counts are unchanged (only `tgenabled` flips)
    Repo.query!(
      ~s|ALTER TABLE "#{y.schema_name}".audit_entries DISABLE TRIGGER audit_entries_no_update|
    )

    [tenant_pool: pool, x_schema: x.schema_name, y_schema: y.schema_name, x_tenant: x.tenant_id]
  end

  setup context do
    TenantFixture.attach_pool!(context)
  end

  test "both slots are proven at their first acquire: X is reset in place, Y is rebuilt", ctx do
    before = TenantFixture.pool_stats(ctx.tenant_pool)
    assert before.acquires == 0
    assert before.rebuilds == 0

    log =
      capture_log([level: :info], fn ->
        x = TenantFixture.provisioned_tenant!(@x)
        y = TenantFixture.provisioned_tenant!(@y)

        assert x.schema_name == ctx.x_schema
        assert y.schema_name == ctx.y_schema
        assert %{clean?: true} = TenantFixture.pool_dirty_report(x)
        assert %{clean?: true} = TenantFixture.pool_dirty_report(y)
      end)

    stats = TenantFixture.pool_stats(ctx.tenant_pool)
    assert stats.resets == 1
    assert stats.rebuilds == 1
    assert stats.generations[ctx.x_schema] == 0
    assert stats.generations[ctx.y_schema] == 1
    assert :definition_drift in stats.fallback_reasons

    assert log =~ ~r/phase=pool_acquire slot=#{ctx.x_schema} outcome=reset/
    assert log =~ ~r/phase=pool_acquire slot=#{ctx.y_schema} outcome=rebuilt/

    # the keyed public row of X is gone too
    assert Repo.query!("SELECT count(*) FROM public.tenant_memberships WHERE tenant_id = $1", [
             Ecto.UUID.dump!(ctx.x_tenant)
           ]).rows == [[0]]

    # the trigger of Y is enabled again
    assert Repo.query!(
             "SELECT tgenabled::text FROM pg_trigger t WHERE tgname = 'audit_entries_no_update' " <>
               "AND tgrelid = $1::text::regclass",
             [~s|"#{ctx.y_schema}".audit_entries|]
           ).rows == [["O"]]
  end
end

defmodule Letflow.Support.TenantFixturePoolTeardownTest do
  @moduledoc """
  F6 / INV-P9 (design 3.4): module-end teardown when NO test ever called
  `provisioned_tenant!/1`.

  `DataCase` leaves the Sandbox mode at `{:shared, dead_test_pid}` after the last test, and
  `provisioned_tenant!/1` (which flips to `:auto`) never ran, so the pool's teardown must
  set `:auto` FIRST or its statements raise `DBConnection.OwnershipError` and the schemas
  leak. The pooled tenant also owns tenant-keyed public rows, which teardown must delete
  before the `Tenant` row, or the `Tenant` delete violates an FK.

  The checker `on_exit` is registered BEFORE `start_pool!/2`, so ExUnit (reverse order) runs
  it AFTER the pool's own teardown; it cleans up anything left so a failure here cannot
  leak into the database, then asserts nothing was left.
  """

  use Letflow.DataCase, async: false

  alias Letflow.TenantFixture

  # Audit (design 6.2): no spawn, no lib/ worker; only TenantFixture and Repo are called.
  setup_all context do
    on_exit(fn -> check_everything_is_gone!() end)

    [tenant_pool: pool] =
      TenantFixture.start_pool!(context, slots: [[slug_prefix: "pool-td"]])

    slot = :sys.get_state(pool.worker).slots |> Map.values() |> hd()
    :persistent_term.put({__MODULE__, :slot}, {slot.schema_name, slot.tenant_id})

    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    # tenant-keyed public state and slot data the teardown must remove
    Repo.query!(
      "INSERT INTO public.tenant_memberships (id, subject_key, tenant_id, inserted_at, " <>
        "updated_at) VALUES (gen_random_uuid(), 'td-sub', $1, now(), now())",
      [Ecto.UUID.dump!(slot.tenant_id)]
    )

    Repo.query!(
      ~s|INSERT INTO "#{slot.schema_name}".groups (id, name, inserted_at, updated_at) | <>
        ~s|VALUES (gen_random_uuid(), 'td', now(), now())|
    )

    [tenant_pool: pool]
  end

  setup context do
    TenantFixture.attach_pool!(context)
  end

  test "a module that never provisions a tenant still has a valid pool to tear down", ctx do
    # deliberately no provisioned_tenant!/1 and no pool_stats/1 / pool_dirty_report/1 (those
    # set Sandbox :auto themselves): the mode stays {:shared, this pid} until teardown
    assert Process.alive?(ctx.tenant_pool.worker)
  end

  defp check_everything_is_gone! do
    {schema, tenant_id} = :persistent_term.get({__MODULE__, :slot})
    :persistent_term.erase({__MODULE__, :slot})
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
    id = Ecto.UUID.dump!(tenant_id)

    left = %{
      schema:
        Repo.query!("SELECT count(*) FROM information_schema.schemata WHERE schema_name = $1", [
          schema
        ]).rows,
      registration:
        Repo.query!("SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1", [id]).rows,
      tenant: Repo.query!("SELECT count(*) FROM public.tenants WHERE id = $1", [id]).rows,
      membership:
        Repo.query!("SELECT count(*) FROM public.tenant_memberships WHERE tenant_id = $1", [id]).rows
    }

    # never leave debris behind, whatever the verdict
    Repo.query!(~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|)
    Repo.query!("DELETE FROM public.tenant_memberships WHERE tenant_id = $1", [id])
    Repo.query!("DELETE FROM public.tenant_schemas WHERE tenant_id = $1", [id])
    Repo.query!("DELETE FROM public.tenants WHERE id = $1", [id])

    if left != %{schema: [[0]], registration: [[0]], tenant: [[0]], membership: [[0]]} do
      raise ExUnit.AssertionError,
        message: "pool teardown left state behind (INV-P9): #{inspect(left)}"
    end
  end
end
