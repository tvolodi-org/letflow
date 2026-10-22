defmodule Mix.Tasks.Letflow.BackfillScriptHmacSecrets do
  @shortdoc "Creates the per-tenant script-input HMAC key for tenants provisioned before GH 2534 7b-1"

  @moduledoc """
  GH 2534 PR 7b-1 (decision 0053 D9, advisor Q2): creates the per-tenant script-input HMAC key
  (`sec://tenant/<slug>/platform/script-input-hmac`, `Letflow.Scripts.HmacSecret`) for every
  tenant registered in `Letflow.TenantProvisioning.list_registrations/0` that has none. New
  tenants get it at provisioning; the key is never created lazily during a script run.

  Chosen over the boot-time tenant migration replay because `Letflow.Secrets.put/2` needs the
  tenant row and the master key, and must not run inside a schema migration's transaction.

  ## Usage

      mix letflow.backfill_script_hmac_secrets

  Release form (no Mix): `bin/letflow eval "Letflow.Release.backfill_script_hmac_secrets()"`
  (`Letflow.Release`, GH #2567). No arguments. Idempotent: a tenant that already has an
  active key is left alone. Prints counts only, never a key. Exits non-zero if any tenant fails.
  """

  use Mix.Task

  alias Letflow.Scripts.HmacSecret.Backfill
  alias Letflow.TenantProvisioning

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(_args) do
    Mix.Task.run("app.start")

    {created, present, failed} = backfill(TenantProvisioning.list_registrations())

    Mix.shell().info(
      "GH 2534 script HMAC backfill: #{created} key(s) created, #{present} tenant(s) already had one, " <>
        "#{length(failed)} failure(s)"
    )

    if failed != [] do
      Mix.shell().error("Failed tenant_ids: #{Enum.join(failed, ", ")}")
      System.halt(1)
    end

    :ok
  end

  @doc """
  Delegates to `Letflow.Scripts.HmacSecret.Backfill.run/1` (the core shared with the release
  wrapper); returns `{created, already_present, failed_tenant_ids}`.
  """
  @spec backfill([%{required(:tenant_id) => Ecto.UUID.t()}]) ::
          {non_neg_integer(), non_neg_integer(), [Ecto.UUID.t()]}
  defdelegate backfill(registrations), to: Backfill, as: :run
end
