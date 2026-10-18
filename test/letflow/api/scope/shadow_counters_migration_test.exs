defmodule Letflow.Api.Scope.ShadowCountersMigrationTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2b, AC 22 (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 4.7.1; spec
  `test/specs/REQ-517-2b.md`, T-H shape, 0006 D2 and the C6 replay/clone oracle): the tenant table
  `scope_shadow_counters` created by migration `20261018200002`.

    * registered in `TenantProvisioning`'s manifest (it is a tenant-scoped migration); the PUBLIC
      migration `20261018200001` is deliberately NOT;
    * the table: columns, types and nullability; NO `tenant_id` column (0006 D2); composite primary
      key `(day, metric)` named `scope_shadow_counters_pkey`; `count >= 0` and the seven-value
      `metric` CHECK, each by its explicit name; the constraints REFUSE a negative count, an
      unknown metric and a duplicate `(day, metric)`;
    * it exists on a CLONED and on a REPLAYED tenant; `down` drops it, `up` recreates it, and
      `up` is a no-op on a public (unprefixed) run (the `if prefix()` guard).

  Runs `Ecto.Migrator.run/4` with the tenant prefix, as `TenantProvisioning.replay_migrations/2`.
  `async: false`: raw DDL against dedicated tenant schemas.
  """

  use Letflow.DataCase, async: false

  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_018_200_002
  @public_version 20_261_018_200_001
  @migration Letflow.Repo.Migrations.CreateScopeShadowCounters
  @metrics ~w(requests role_not_held no_grant_rows not_tenant_wide out_of_scope unresolvable grants_unavailable)

  setup do
    # Loads every manifest migration module (they are not compiled into the app).
    migrations = TenantProvisioning.tenant_scoped_migrations()
    {:ok, migrations: migrations}
  end

  defp migrate(schema, direction) do
    Ecto.Migrator.run(Repo, [{@version, @migration}], direction,
      all: true,
      prefix: schema,
      log: false
    )
  end

  defp regclass(schema) do
    %{rows: [[value]]} =
      Repo.query!("SELECT to_regclass($1)::text", [~s|"#{schema}".scope_shadow_counters|])

    value
  end

  # {column => {data_type, nullable?}}
  defp columns(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, data_type, is_nullable FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'scope_shadow_counters'",
        [schema]
      )

    Map.new(rows, fn [name, type, nullable] -> {name, {type, nullable == "YES"}} end)
  end

  defp constraints(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT c.conname, c.contype::text, pg_get_constraintdef(c.oid) FROM pg_constraint c " <>
          "JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace " <>
          "WHERE n.nspname = $1 AND t.relname = 'scope_shadow_counters'",
        [schema]
      )

    Map.new(rows, fn [name, type, definition] -> {name, {type, definition}} end)
  end

  defp insert(schema, day, metric, count) do
    Repo.query(
      ~s|INSERT INTO "#{schema}".scope_shadow_counters (day, metric, count, updated_at) | <>
        "VALUES ($1, $2, $3, $4)",
      [day, metric, count, NaiveDateTime.utc_now()]
    )
  end

  # ===========================================================================================
  test "the tenant-scoped migration is registered in the manifest; the public widening one is not",
       %{
         migrations: migrations
       } do
    assert {@version, @migration} in migrations
    refute Enum.any?(migrations, fn {version, _module} -> version == @public_version end)
  end

  describe "the table shape" do
    for {template, label} <- [{:clone, "cloned"}, {:replay, "replayed"}] do
      test "a #{label} tenant has the columns, no tenant_id, the named primary key and both CHECKs" do
        fx =
          TenantFixture.provisioned_tenant!(
            slug_prefix: "r517-shape-#{unquote(label)}",
            template: unquote(template)
          )

        schema = fx.schema_name

        assert columns(schema) == %{
                 "day" => {"date", false},
                 "metric" => {"text", false},
                 "count" => {"bigint", false},
                 "updated_at" => {"timestamp without time zone", false}
               }

        refute Map.has_key?(columns(schema), "tenant_id")

        constraints = constraints(schema)

        assert {"p", pk} = constraints["scope_shadow_counters_pkey"]
        assert pk =~ "PRIMARY KEY (day, metric)"

        assert {"c", count_check} = constraints["scope_shadow_counters_count_check"]
        assert count_check =~ "count >= 0"

        assert {"c", metric_check} = constraints["scope_shadow_counters_metric_check"]
        for metric <- @metrics, do: assert(metric_check =~ "'#{metric}'", metric_check)

        assert Enum.sort(Map.keys(constraints)) ==
                 Enum.sort([
                   "scope_shadow_counters_pkey",
                   "scope_shadow_counters_count_check",
                   "scope_shadow_counters_metric_check"
                 ])
      end
    end

    test "the count defaults to 0 and every constraint name is under the 63-byte limit" do
      fx = TenantFixture.provisioned_tenant!(slug_prefix: "r517-shape-default")
      schema = fx.schema_name

      assert {:ok, _} =
               Repo.query(
                 ~s|INSERT INTO "#{schema}".scope_shadow_counters (day, metric, updated_at) | <>
                   "VALUES ($1, 'requests', $2)",
                 [~D[2026-04-01], NaiveDateTime.utc_now()]
               )

      assert %{rows: [[0]]} =
               Repo.query!(~s|SELECT "count" FROM "#{schema}".scope_shadow_counters|)

      for name <- Map.keys(constraints(schema)), do: assert(byte_size(name) < 63)
    end
  end

  describe "the constraints refuse bad rows" do
    setup do
      fx = TenantFixture.provisioned_tenant!(slug_prefix: "r517-constraints")
      {:ok, schema: fx.schema_name}
    end

    test "all seven metrics are accepted", %{schema: schema} do
      for metric <- @metrics do
        assert {:ok, %{num_rows: 1}} = insert(schema, ~D[2026-04-02], metric, 1), metric
      end
    end

    test "a negative count violates scope_shadow_counters_count_check", %{schema: schema} do
      assert {:error,
              %Postgrex.Error{postgres: %{constraint: "scope_shadow_counters_count_check"}}} =
               insert(schema, ~D[2026-04-02], "requests", -1)
    end

    test "an unknown metric violates scope_shadow_counters_metric_check", %{schema: schema} do
      for metric <- ["bogus", "REQUESTS", "", "requests "] do
        assert {:error,
                %Postgrex.Error{postgres: %{constraint: "scope_shadow_counters_metric_check"}}} =
                 insert(schema, ~D[2026-04-02], metric, 1),
               inspect(metric)
      end
    end

    test "a second row for the same (day, metric) violates the primary key; another day or metric is fine",
         %{schema: schema} do
      assert {:ok, _} = insert(schema, ~D[2026-04-02], "requests", 1)

      assert {:error, %Postgrex.Error{postgres: %{constraint: "scope_shadow_counters_pkey"}}} =
               insert(schema, ~D[2026-04-02], "requests", 2)

      assert {:ok, _} = insert(schema, ~D[2026-04-03], "requests", 2)
      assert {:ok, _} = insert(schema, ~D[2026-04-02], "out_of_scope", 2)
    end
  end

  describe "apply and rollback" do
    test "down drops the table, up recreates it with the same constraints; the public (unprefixed) guard is a no-op" do
      fx = TenantFixture.provisioned_tenant!(slug_prefix: "r517-updown")
      schema = fx.schema_name
      assert regclass(schema) != nil
      before_constraints = constraints(schema)

      assert migrate(schema, :down) == [@version]
      assert regclass(schema) == nil

      assert migrate(schema, :up) == [@version]
      assert regclass(schema) != nil
      assert constraints(schema) == before_constraints

      # the if prefix() guard: nothing is created in the public schema by this migration
      %{rows: [[public_table]]} =
        Repo.query!("SELECT to_regclass('public.scope_shadow_counters')::text")

      assert public_table == nil
    end
  end
end
