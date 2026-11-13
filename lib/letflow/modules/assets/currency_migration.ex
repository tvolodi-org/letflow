defmodule Letflow.Modules.Assets.CurrencyMigration do
  @moduledoc """
  Slice C3 of the currency directory (REQ-825, GH #4392, design `docs/design/currency-directory.md`
  section 6, owner decision D-134): moves the free-text currency of module `assets` into the core
  directory (`Letflow.Currencies`) without loss. Run from a release through
  `Letflow.Release.Currencies.normalize/1`; nothing runs at boot. QA only: a run on a real tenant is
  announced to the portfolio manager first (the operator's rule, not enforced here).

  Per tenant with an active `assets` install:

    1. when no `tenant_currencies` row is the tenant currency and the assets setting `currency`
       maps by `Letflow.Currencies.normalize/1`, that code becomes the tenant currency (and active)
       through `Letflow.Currencies.switch/4`; an unknown setting value is counted
       (`unknown_setting`) and nothing is written for it;
    2. every live `assets_card` whose `currency` is not empty and not already exactly a code of the
       platform list is rewritten to the mapped code through `Records.update_record/3` with the
       assets owner (one record event, so the old text stays in the history) and one audit entry
       `assets.card_currency_migrated`, in one transaction per card. An unknown value stays as
       stored and its record id is listed in `unknown_card_ids`.

  The report never carries a currency text (tenant data, INV-4 spirit), only counts and record ids.
  A second run changes nothing; `dry_run: true` writes nothing and reports the same counts. The
  tenant comes only from the registered schema name (INV-1); every query passes `prefix`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Currencies
  alias Letflow.Currencies.Catalog
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @system_actor_id "00000000-0000-0000-0000-000000000000"

  @type tenant_report :: %{
          schema_name: String.t(),
          settings_set: non_neg_integer(),
          unknown_setting: non_neg_integer(),
          cards_rewritten: non_neg_integer(),
          cards_unknown: non_neg_integer(),
          already_ok: non_neg_integer(),
          failed: non_neg_integer(),
          unknown_card_ids: [String.t()]
        }

  @type report :: %{
          dry_run: boolean(),
          tenants: [tenant_report()],
          failed_total: non_neg_integer()
        }

  @doc """
  Sweeps every registered tenant that has an active `assets` install. Only `dry_run` and
  `actor_id` (the operator's user id, kept in the switch row and the audit entries) are read.
  """
  @spec run(keyword()) :: {:ok, report()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true
    actor_id = Keyword.get(opts, :actor_id) || @system_actor_id

    tenants =
      Letflow.Obs.Logger.with_trace(fn ->
        for %Registration{schema_name: schema} <- TenantProvisioning.list_registrations(),
            assets_active?(schema) do
          run_tenant(schema, dry_run?, actor_id)
        end
      end)

    {:ok,
     %{
       dry_run: dry_run?,
       tenants: tenants,
       failed_total: Enum.sum(Enum.map(tenants, & &1.failed))
     }}
  end

  @doc "One tenant schema. Never raises: a failure is counted in `failed`."
  @spec run_tenant(String.t(), boolean(), String.t()) :: tenant_report()
  def run_tenant(schema, dry_run?, actor_id) when is_binary(schema) do
    schema
    |> empty()
    |> migrate_setting(schema, dry_run?, actor_id)
    |> migrate_cards(schema, dry_run?, actor_id)
  rescue
    # INV-8: a tenant that cannot be read is a counted failure, never a halt of the sweep.
    _ -> %{empty(schema) | failed: 1}
  end

  defp empty(schema) do
    %{
      schema_name: schema,
      settings_set: 0,
      unknown_setting: 0,
      cards_rewritten: 0,
      cards_unknown: 0,
      already_ok: 0,
      failed: 0,
      unknown_card_ids: []
    }
  end

  # --- step 1: the setting ---------------------------------------------------------------

  defp migrate_setting(report, schema, dry_run?, actor_id) do
    with false <- tenant_currency_row?(schema),
         %TenantModule{settings: %{"currency" => text}} when is_binary(text) <- assets_row(schema) do
      case Currencies.normalize(text) do
        {:ok, code} -> set_tenant_currency(report, schema, code, dry_run?, actor_id)
        :unknown -> bump(report, :unknown_setting)
      end
    else
      _ -> report
    end
  end

  defp set_tenant_currency(report, _schema, _code, true, _actor_id),
    do: bump(report, :settings_set)

  defp set_tenant_currency(report, schema, code, false, actor_id) do
    case Currencies.switch(schema, code, %{"active" => true, "tenant_currency" => true}, actor_id) do
      {:ok, _} -> bump(report, :settings_set)
      _ -> bump(report, :failed)
    end
  end

  defp tenant_currency_row?(schema) do
    Repo.exists?(
      from(s in Currencies.Switch, where: s.tenant_currency == true),
      prefix: schema
    )
  end

  # --- step 2: the cards -----------------------------------------------------------------

  defp migrate_cards(report, schema, dry_run?, actor_id) do
    rows =
      Repo.all(
        from(r in Latest,
          where: r.entity_type == "assets_card" and not r.deleted,
          order_by: r.record_id
        ),
        prefix: schema
      )

    Enum.reduce(rows, report, fn row, acc ->
      migrate_card(acc, schema, row, dry_run?, actor_id)
    end)
  end

  defp migrate_card(report, schema, %Latest{field_values: fv, record_id: id}, dry_run?, actor_id) do
    case Map.get(fv, "currency") do
      text when text in [nil, ""] ->
        report

      text when is_binary(text) ->
        cond do
          Catalog.known?(text) -> bump(report, :already_ok)
          true -> rewrite_or_keep(report, schema, id, fv, text, dry_run?, actor_id)
        end

      _other ->
        keep_unknown(report, id)
    end
  end

  defp rewrite_or_keep(report, schema, id, fv, text, dry_run?, actor_id) do
    case Currencies.normalize(text) do
      :unknown -> keep_unknown(report, id)
      {:ok, _code} when dry_run? -> bump(report, :cards_rewritten)
      {:ok, code} -> rewrite(report, schema, id, fv, code, actor_id)
    end
  end

  defp keep_unknown(report, id) do
    report |> bump(:cards_unknown) |> Map.update!(:unknown_card_ids, &(&1 ++ [id]))
  end

  defp rewrite(report, schema, id, fv, code, actor_id) do
    after_fv = Map.put(fv, "currency", code)

    attrs = %{
      entity_type: "assets_card",
      record_id: id,
      field_values: after_fv,
      actor_id: actor_id,
      idempotency_key: "currency-migration:" <> id
    }

    result =
      Repo.transaction(fn ->
        # scope-all: SEC-518-R1 (assets module, own-record system path; a release task run by the operator)
        with {:ok, _} <-
               Records.update_record(
                 attrs,
                 schema,
                 ManagedTypes.owner_for!(Letflow.Modules.Assets)
               ),
             {:ok, _} <- audit(schema, actor_id, id, fv, after_fv) do
          :ok
        else
          _ -> Repo.rollback(:write_failed)
        end
      end)

    case result do
      {:ok, :ok} -> bump(report, :cards_rewritten)
      _ -> bump(report, :failed)
    end
  end

  # The audit entry names the record and the mapped code only; the old text is in the record event.
  defp audit(schema, actor_id, id, before_fv, after_fv) do
    entry = %{
      actor_id: actor_id,
      action: "assets.card_currency_migrated",
      resource_type: "assets_card",
      resource_id: id,
      before_state: %{"currency_length" => String.length(Map.get(before_fv, "currency", ""))},
      after_state: %{"currency" => Map.get(after_fv, "currency")}
    }

    Audit.insert_entry(Repo, entry, schema)
  end

  # --- helpers ---------------------------------------------------------------------------

  defp assets_row(schema),
    do: Repo.get_by(TenantModule, [module_id: "assets", status: :active], prefix: schema)

  defp assets_active?(schema) do
    match?({:ok, _}, TenantProvisioning.tenant_id_for_schema_name(schema)) and
      match?(%TenantModule{}, assets_row(schema))
  rescue
    _ -> false
  end

  defp bump(report, key), do: Map.update!(report, key, &(&1 + 1))
end
