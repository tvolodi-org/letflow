defmodule Letflow.Release.RestoreSmoke do
  @moduledoc """
  T-1568 -- the app-side smoke of the restore test (`scripts/backup/restore_test.sh`, step 6).

  Run through the release against a RESTORED database (`DATABASE_URL` points at the scratch copy):

      bin/letflow eval "Letflow.Release.restore_smoke()"

  It proves "this code can read this restored data": the platform tables are readable, every
  tenant registered in `tenant_schemas` has a readable `tenant_modules` and `events` table, and the
  database holds no migration version that this build does not know (a dump one deploy old has
  PENDING migrations, which is reported, not a failure). It is not a full HTTP boot: a throwaway
  container has no IdP and no secrets (see `docs/runbooks/backup-restore.md`, drill checklist).

  ## Scoping (INV-1, INV-6, INV-7)

  Operator/offline path with no route and no token. Tenant schema names come only from the
  `tenant_schemas` registry (never from argv or env), must match `^[a-z0-9_]{1,63}$`, and are
  quoted as identifiers; a name that does not match is refused with a token and never executed.

  ## Output (INV-4)

  Counts and fixed tokens only. A failure is a token (`tenant_schema_unreadable`,
  `unknown_migration_in_db`, ...), never an exception string, so no server detail or record
  content reaches the log.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @schema_name ~r/\A[a-z0-9_]{1,63}\z/
  @unknown_file "** FILE NOT FOUND **"

  @type summary :: %{
          required(:tenants) => non_neg_integer(),
          required(:schemas) => non_neg_integer(),
          required(:pending_migrations) => non_neg_integer(),
          required(:failures) => [atom()]
        }

  @doc """
  Reads the restored data. Options (tests): `:registrations` (default every registered tenant).
  Returns `{:ok, summary}` or `{:error, summary}` (`summary.failures` lists the tokens).
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, summary()}
  def run(opts \\ []) do
    registrations =
      Keyword.get_lazy(opts, :registrations, &TenantProvisioning.list_registrations/0)

    {tenants, tenant_failures} = count_tenants()
    {schemas, schema_failures} = check_schemas(registrations)
    {pending, migration_failures} = check_migrations()

    failures = tenant_failures ++ schema_failures ++ migration_failures

    summary = %{
      tenants: tenants,
      schemas: schemas,
      pending_migrations: pending,
      failures: Enum.uniq(failures)
    }

    if failures == [], do: {:ok, summary}, else: {:error, summary}
  end

  @doc "The single report line: fixed tokens and counts."
  @spec format_line({:ok | :error, summary()}) :: String.t()
  def format_line({status, summary}) do
    base =
      "tenants=#{summary.tenants} schemas=#{summary.schemas} " <>
        "pending_migrations=#{summary.pending_migrations}"

    case status do
      :ok -> "smoke=ok " <> base
      :error -> "smoke=failed " <> base <> " reasons=" <> Enum.join(summary.failures, ",")
    end
  end

  defp count_tenants do
    case Repo.query("SELECT count(*) FROM public.tenants") do
      {:ok, %{rows: [[n]]}} -> {n, []}
      _ -> {0, [:tenants_unreadable]}
    end
  rescue
    _exception -> {0, [:tenants_unreadable]}
  end

  defp check_schemas(registrations) do
    Enum.reduce(registrations, {0, []}, fn registration, {ok_count, failures} ->
      case check_schema(registration.schema_name) do
        :ok -> {ok_count + 1, failures}
        {:error, token} -> {ok_count, [token | failures]}
      end
    end)
  end

  defp check_schema(name) when is_binary(name) do
    if Regex.match?(@schema_name, name) do
      read_tenant_tables(name)
    else
      {:error, :tenant_schema_name_refused}
    end
  end

  defp check_schema(_name), do: {:error, :tenant_schema_name_refused}

  # `name` matched @schema_name above; Ecto quotes the prefix as an identifier itself, so no SQL
  # text is built here (INV-7).
  defp read_tenant_tables(name) do
    _ = Repo.aggregate(from(t in "tenant_modules", prefix: ^name), :count)
    _ = Repo.aggregate(from(t in "events", prefix: ^name), :count)
    :ok
  rescue
    _exception -> {:error, :tenant_schema_unreadable}
  end

  defp check_migrations do
    migrations = Ecto.Migrator.migrations(Repo)
    pending = Enum.count(migrations, fn {status, _version, _name} -> status == :down end)

    unknown =
      Enum.any?(migrations, fn {status, _version, name} ->
        status == :up and name == @unknown_file
      end)

    {pending, if(unknown, do: [:unknown_migration_in_db], else: [])}
  rescue
    _exception -> {0, [:migrations_unreadable]}
  end
end
