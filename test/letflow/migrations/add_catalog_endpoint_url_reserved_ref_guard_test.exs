defmodule Letflow.Migrations.AddCatalogEndpointUrlReservedRefGuardTest do
  @moduledoc """
  GH #2638 T1: the pre-flight and the NOT VALID + VALIDATE sequence of
  `priv/repo/migrations/20261017100001_add_catalog_endpoint_url_reserved_ref_guard.exs`,
  run against real Postgres. Design:
  `lib/letflow/design/gh2638-catalog-endpoint-sys-db-guard.md` (rev 2) section 6, T1.
  Spec: `test/specs/GH-2638.md`.

  The migration is GLOBAL (no `prefix:`), so the tenant-replay mechanism of the other
  migration tests does not fit. This file calls `Ecto.Migrator.run/4` with an explicit
  one-entry migration list and no prefix. Like `definitions/migrations_test.exs`, it runs in
  `Sandbox` `:auto` mode (the migrator takes a lock on `schema_migrations` that a sandboxed
  pool does not hand out) and therefore commits real rows; `on_exit/1` deletes every
  `gh2638-mig-` row and, if the version row is missing, runs the migration `:up` again so the
  shared test DB ends fully migrated. `async: false`: while the constraints are dropped no
  other module may write a `_sys` URL, which holds because every catalog test module is
  `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox

  @version 20_261_017_100_001
  @migration Letflow.Repo.Migrations.AddCatalogEndpointUrlReservedRefGuard
  @live_check "chk_service_catalog_endpoint_url_no_reserved_ref"
  @versions_check "chk_service_catalog_versions_endpoint_url_no_reserved_ref"

  # Held in a variable only so the secrecy assertions below have something to look for.
  @secret_name "gh2638secretname"
  @violating_url "https://example.test/{{variables._sys.#{@secret_name}}}"

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261017100001_add_catalog_endpoint_url_reserved_ref_guard.exs",
                    __DIR__
                  )

  # `priv/repo/migrations` is not compiled with the app; load the module once, by path.
  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@migration_path)
    :ok
  end

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(&restore!/0)
    :ok
  end

  defp migrate(direction),
    do: Ecto.Migrator.run(Repo, [{@version, @migration}], direction, all: true, log: false)

  defp restore! do
    delete_mig_rows!()

    if version_rows() == 0 do
      migrate(:up)
    end
  end

  defp delete_mig_rows! do
    Repo.query!("DELETE FROM service_catalog_versions WHERE service_id LIKE 'gh2638-mig-%'")
    Repo.query!("DELETE FROM service_catalog WHERE service_id LIKE 'gh2638-mig-%'")
  end

  defp version_rows do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM schema_migrations WHERE version = $1", [@version])

    n
  end

  # {conname, table, convalidated}, sorted.
  defp constraints do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT conname, conrelid::regclass::text, convalidated
        FROM pg_constraint WHERE conname = ANY($1) ORDER BY conname
        """,
        [[@live_check, @versions_check]]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp insert_violating_rows! do
    Repo.query!(
      """
      INSERT INTO service_catalog
        (service_id, endpoint_url, required_auth, timeout_ms, scope, created_at, updated_at,
         published_at)
      VALUES ('gh2638-mig-live', $1, 'NONE', 5000, 'global', now(), now(), now())
      """,
      [@violating_url]
    )

    Repo.query!(
      """
      INSERT INTO service_catalog_versions
        (version_id, service_id, version, endpoint_url, required_auth, timeout_ms,
         published_at, retired_at)
      VALUES (gen_random_uuid(), 'gh2638-mig-ver', '1', $1, 'NONE', 5000, now(), now())
      """,
      [@violating_url]
    )
  end

  test "pre-flight aborts on a violating row (counts only); once clean, up validates both CHECKs; down/up is reversible" do
    # The shared test DB starts fully migrated.
    assert [
             {@live_check, "service_catalog", true},
             {@versions_check, "service_catalog_versions", true}
           ] = constraints()

    # (1) down: both constraints and the schema_migrations row are gone.
    assert migrate(:down) == [@version]
    assert constraints() == []
    assert version_rows() == 0

    # (2) committed violating rows in BOTH tables (possible only because the CHECKs are gone).
    insert_violating_rows!()

    # (3) up raises; the DDL transaction rolls everything back.
    error = assert_raise Postgrex.Error, fn -> migrate(:up) end

    pg_message = error.postgres.message
    assert pg_message =~ "1 service_catalog and 1 service_catalog_versions row(s)"
    refute pg_message =~ "_sys"
    refute pg_message =~ @secret_name
    refute pg_message =~ "example.test"
    refute Exception.message(error) =~ @secret_name
    refute Exception.message(error) =~ "example.test"

    assert constraints() == []
    assert version_rows() == 0

    # (4) remove the violating rows, (5) up succeeds, both validated.
    delete_mig_rows!()
    assert migrate(:up) == [@version]

    assert [
             {@live_check, "service_catalog", true},
             {@versions_check, "service_catalog_versions", true}
           ] = constraints()

    assert version_rows() == 1

    # (6) reversibility.
    assert migrate(:down) == [@version]
    assert constraints() == []
    assert migrate(:up) == [@version]
    assert [{@live_check, _, true}, {@versions_check, _, true}] = constraints()
  end

  test "pre-flight counts a violation in only one table (live table clean, versions dirty)" do
    assert migrate(:down) == [@version]

    Repo.query!(
      """
      INSERT INTO service_catalog_versions
        (version_id, service_id, version, endpoint_url, required_auth, timeout_ms,
         published_at, retired_at)
      VALUES (gen_random_uuid(), 'gh2638-mig-ver', '1', $1, 'NONE', 5000, now(), now())
      """,
      [@violating_url]
    )

    error = assert_raise Postgrex.Error, fn -> migrate(:up) end
    assert error.postgres.message =~ "0 service_catalog and 1 service_catalog_versions row(s)"
    assert constraints() == []
  end
end
