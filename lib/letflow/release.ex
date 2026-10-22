defmodule Letflow.Release do
  @moduledoc """
  GH #2567 -- operator backfills for a release, which has no Mix. Run them with

      bin/letflow eval "Letflow.Release.backfill_script_hmac_secrets()"
      bin/letflow eval "Letflow.Release.backfill_login_directory()"

  Each wrapper delegates to the same core function as its Mix task
  (`Letflow.Scripts.HmacSecret.Backfill.run/1`,
  `Letflow.LoginDirectory.Backfill.run/1`), so the two paths cannot drift. Calling a
  `Mix.Tasks.*` module from a release is not supported; use these.

  Each wrapper loads the app, starts the few applications `Letflow.Repo` needs and the Repo
  itself (small pool), and nothing else: no endpoint, no pollers, so it is safe next to a
  running node. Then it prints counts and exits non-zero (`System.halt(1)`) if any tenant
  failed. Do not call them through `rpc`: the halt would stop the live node.

  ## Output (INV-4)

  Counts and fixed tokens only: tenants processed, created, already present, failed. Never a key,
  a pepper, an email address or a tenant id; a failure is a count, not a reason string. Both
  backfills are idempotent: a re-run creates nothing.

  See `docs/runbooks/release-backfills.md`. `Letflow.Release.IdempotencySquats` and the other
  `Letflow.Release.*` modules are separate operator entry points.
  """

  alias Letflow.LoginDirectory.Backfill, as: LoginDirectoryBackfill
  alias Letflow.Scripts.HmacSecret.Backfill, as: HmacSecretBackfill
  alias Letflow.TenantProvisioning

  @app :letflow
  @repo_apps [:crypto, :ssl, :telemetry, :ecto_sql, :postgrex]

  @type summary :: %{
          required(:processed) => non_neg_integer(),
          required(:created) => non_neg_integer(),
          required(:already_present) => non_neg_integer(),
          required(:failed) => non_neg_integer()
        }

  @doc """
  Creates the per-tenant script-input HMAC key for every registered tenant that has none
  (GH 2534 7b-1). Options (for tests): `:registrations` (default every registered tenant),
  `:halt` (default `true`), `:start` (default `true`).
  """
  @spec backfill_script_hmac_secrets(keyword()) :: {:ok | :error, summary()}
  def backfill_script_hmac_secrets(opts \\ []) do
    maybe_start(opts)

    registrations =
      Keyword.get_lazy(opts, :registrations, &TenantProvisioning.list_registrations/0)

    {created, present, failed} =
      HmacSecretBackfill.run(registrations)

    summary = %{
      processed: length(registrations),
      created: created,
      already_present: present,
      failed: length(failed)
    }

    finish("script HMAC backfill", summary, opts)
  end

  @doc """
  Backfills the platform tenant-login directory from every registered tenant's active users
  (REQ-435). `already_present` is the user keys that already had a row. Options: `:dry_run`
  (default `false`), plus the test options of `backfill_script_hmac_secrets/1`.
  """
  @spec backfill_login_directory(keyword()) :: {:ok | :error, summary()}
  def backfill_login_directory(opts \\ []) do
    maybe_start(opts)

    case LoginDirectoryBackfill.run(dry_run: Keyword.get(opts, :dry_run, false)) do
      {:ok, %{tenants: tenants, failed: failed}} ->
        keys = Enum.sum(Enum.map(tenants, & &1.keys))
        inserted = Enum.sum(Enum.map(tenants, & &1.inserted))

        summary = %{
          processed: length(tenants) + length(failed),
          created: inserted,
          already_present: keys - inserted,
          failed: length(failed)
        }

        finish("login directory backfill", summary, opts)

      {:error, :pepper_unavailable} ->
        IO.puts("login directory backfill: the login directory pepper configuration is missing")
        halt_or_return({:error, empty_summary(1)}, opts)
    end
  end

  defp empty_summary(failed), do: %{processed: 0, created: 0, already_present: 0, failed: failed}

  defp finish(label, summary, opts) do
    IO.puts(
      "#{label}: #{summary.processed} tenant(s) processed, #{summary.created} created, " <>
        "#{summary.already_present} already present, #{summary.failed} failed"
    )

    status = if summary.failed == 0, do: :ok, else: :error
    halt_or_return({status, summary}, opts)
  end

  defp halt_or_return({:error, _} = result, opts) do
    if Keyword.get(opts, :halt, true), do: System.halt(1), else: result
  end

  defp halt_or_return(result, _opts), do: result

  defp maybe_start(opts) do
    if Keyword.get(opts, :start, true), do: start_repo()
  end

  # Only what the Repo needs, never `Application.ensure_all_started(:letflow)`.
  defp start_repo do
    Application.load(@app)
    Enum.each(@repo_apps, &Application.ensure_all_started/1)

    case Letflow.Repo.start_link(pool_size: 2) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
