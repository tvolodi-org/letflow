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

  GH 2579 adds the PLATFORM_ADMIN token inventory and the explicit re-mint act:

      bin/letflow eval "Letflow.Release.platform_admin_token_inventory()"
      bin/letflow eval "Letflow.Release.reissue_platform_admin_token(\"<tenant>\", \"<token>\", \"<operator>\", cause: \"<reason>\", plaintext_file: \"<path>\")"

  Their output is ids, schema names, timestamps and counts; a tenant id and a schema name are not
  secrets. Neither prints a token value, hash or name. The re-mint writes the new value to the
  `plaintext_file` it is given and never to stdout. See `docs/runbooks/platform-admin-token-reissue.md`.
  """

  alias Letflow.Identity.PlatformAdminTokens
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

  @doc """
  GH 2579 -- read-only inventory of the standing PLATFORM_ADMIN tokens with no expiry, per
  registered tenant. Prints one `PA_TOKEN_NO_EXPIRY` line per token (ids and timestamps, never the
  value, hash or name), one `TENANT` line per tenant and one `SUMMARY` line. A tenant that fails
  is counted in `errored` and the others still run. Options: `:registrations` (default every
  registered tenant), `:halt` (default `true`: `System.halt(1)` when a tenant errored), `:start`
  (default `true`).
  """
  @spec platform_admin_token_inventory(keyword()) :: {:ok | :error, map()}
  def platform_admin_token_inventory(opts \\ []) do
    maybe_start(opts)

    registrations =
      Keyword.get_lazy(opts, :registrations, &TenantProvisioning.list_registrations/0)

    summary =
      Enum.reduce(
        registrations,
        %{non_expiring_platform_admin: 0, legacy_no_issuer: 0, errored: 0},
        &inventory_tenant/2
      )

    IO.puts(
      "SUMMARY tenants=#{length(registrations)} " <>
        "non_expiring_platform_admin=#{summary.non_expiring_platform_admin} " <>
        "legacy_no_issuer=#{summary.legacy_no_issuer} errored=#{summary.errored}"
    )

    status = if summary.errored == 0, do: :ok, else: :error
    halt_or_return({status, summary}, opts)
  end

  defp inventory_tenant(registration, acc) do
    rows = PlatformAdminTokens.inventory(registration.schema_name)
    Enum.each(rows, &IO.puts(format_inventory_row(registration, &1)))
    legacy = Enum.count(rows, &is_nil(&1.issuer_user_id))

    IO.puts(
      "TENANT tenant=#{registration.tenant_id} schema=#{registration.schema_name} " <>
        "non_expiring_platform_admin=#{length(rows)} legacy_no_issuer=#{legacy} errored=0"
    )

    %{
      acc
      | non_expiring_platform_admin: acc.non_expiring_platform_admin + length(rows),
        legacy_no_issuer: acc.legacy_no_issuer + legacy
    }
  rescue
    # A failure is a count, not a reason string (the module's INV-4 output rule).
    _exception ->
      IO.puts(
        "TENANT tenant=#{registration.tenant_id} schema=#{registration.schema_name} errored=1"
      )

      %{acc | errored: acc.errored + 1}
  end

  defp format_inventory_row(registration, row) do
    "PA_TOKEN_NO_EXPIRY tenant=#{registration.tenant_id} schema=#{registration.schema_name} " <>
      "token_id=#{row.id} owner_user_id=#{row.owner_user_id} " <>
      "issuer_user_id=#{row.issuer_user_id || "legacy"} " <>
      "created_at=#{DateTime.to_iso8601(row.created_at)} " <>
      "last_used_at=#{if row.last_used_at, do: DateTime.to_iso8601(row.last_used_at), else: "never"}"
  end

  @doc """
  GH 2579 -- the explicit act for ONE non-expiring PLATFORM_ADMIN token: mints a replacement
  owned by the same user with an expiry inside the cap, writes its value to `:plaintext_file`
  (created exclusively, never printed), and revokes the old token. Both audit entries carry the
  `:cause`, the operator as actor and one trace id. See `Letflow.Identity.PlatformAdminTokens`
  and `docs/runbooks/platform-admin-token-reissue.md`.

  Options: `:cause` (required), `:days` (default the cap), `:plaintext_file` (required), and for
  tests `:halt` (default `true`), `:start` (default `true`), `:write_plaintext`.
  Prints one `REISSUE` line on success, one `ERROR <reason>` line on failure.
  """
  @spec reissue_platform_admin_token(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reissue_platform_admin_token(tenant_id, token_id, operator_id, opts \\ []) do
    maybe_start(opts)
    core_opts = Keyword.take(opts, [:cause, :days, :plaintext_file, :write_plaintext])

    result =
      Letflow.Obs.Logger.with_trace(fn ->
        PlatformAdminTokens.reissue(tenant_id, token_id, operator_id, core_opts)
      end)

    case result do
      {:ok, done} ->
        IO.puts(
          "REISSUE old_token_id=#{done.old_token_id} new_token_id=#{done.new_token_id} " <>
            "owner_user_id=#{done.owner_user_id} " <>
            "expires_at=#{DateTime.to_iso8601(done.expires_at)} cause_recorded=true " <>
            "plaintext_file=#{done.plaintext_file}"
        )

      {:error, reason} ->
        IO.puts("ERROR #{reason_label(reason)}")
    end

    halt_or_return(result, opts)
  end

  defp reason_label(%Ecto.Changeset{}), do: "changeset_invalid"
  defp reason_label(reason), do: inspect(reason)

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
