defmodule Letflow.Modules.CatalogItems.Import do
  @moduledoc """
  The import function of the catalog masters (GH #3602 / REQ-651, decision 0077 D5): one row of a
  file for `catalog_uom`, `catalog_item` or `catalog_counterparty`, called by the core through
  `Letflow.Modules.Catalog.call_import_function/5` as `row(prefix, entry, ctx)`. This is the only
  file of the module that holds the module's Owner (`ManagedTypes.owner_for!/1`, 0050 D7).

  Per row:

    1. a reference field (a module constant, `catalog_item.base_uom_id` -> `catalog_uom`) holds the
       external id of the target under the SAME external-ref system as the row. It is resolved in
       this tenant (`prefix` is the only tenant datum) to the record id of the live target:
       none, a deleted target, a cell that is not text, or a record id (which matches no external
       id) is `{:reference_not_found, field}`; a target with `active` false is
       `{:reference_inactive, field}`. The `field` is a constant here, never cell text.
    2. the row's external ref is written into the type's own `external_ref_system` and
       `external_ref_id` fields (the ref of the row wins over anything given in the cells), so the
       record-level key (REQ-505) and the unique field pair (0057 D1) hold the same values;
    3. `Records.upsert_record_by_external_ref/3` with the module's Owner writes the row. Values are
       validated by the type's definition as for any write; a missing required reference cell is
       left to that validation.

    4. audit (GH #3739 / REQ-706, decision 0078 D8): a row whose outcome is `:created` or `:updated`
       writes exactly one entry, `catalog_uom.created`, `catalog_uom.updated`, `catalog_item.created`,
       `catalog_item.updated`, `catalog_counterparty.created` or `catalog_counterparty.updated`, with
       the stored field values before (nil on create) and after the row, through
       `Letflow.Audit.insert_entry/3` in the same transaction as the record write (the form of
       `Letflow.Modules.CatalogItems.Lots`). `:unchanged`, a refused row and a replay of a claimed
       idempotency key write none. An audit failure rolls the row back: `{:error, :audit_failed}`.

  `ctx.dry_run` is accepted and unused: the core owns the rollback. No effect outside `prefix`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Entities.ExternalRef
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Modules.CatalogItems
  alias Letflow.Repo

  @references %{"catalog_item" => [{"base_uom_id", "catalog_uom"}]}

  @spec row(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, %{record_id: Ecto.UUID.t(), outcome: :created | :updated | :unchanged}}
          | {:error, term()}
  def row(prefix, %{entity_type: type, external_ref: %ExternalRef{} = ref} = entry, ctx)
      when is_binary(prefix) do
    with {:ok, field_values} <- resolve_references(type, entry.field_values, ref, prefix) do
      attrs = %{
        entity_type: type,
        external_ref: ExternalRef.to_payload(ref),
        field_values:
          Map.merge(field_values, %{
            "external_ref_system" => ref.system,
            "external_ref_id" => ref.id
          }),
        actor_id: ctx.actor_id,
        idempotency_key: ctx.idempotency_key
      }

      persist(prefix, type, ref, attrs, ctx)
    end
  end

  # A claimed idempotency key goes to Records alone (it detects a replay by failing its own multi,
  # which a surrounding transaction cannot survive) and writes no second entry. Otherwise the
  # record write and its entry run in one transaction under a per-tenant lock, so the "before"
  # state read is the state the write replaces. A Records refusal wrote nothing and is returned
  # without a rollback (a rollback would also poison the dry run's outer transaction).
  defp persist(prefix, type, ref, attrs, ctx) do
    if replay?(prefix, ctx.idempotency_key) do
      upsert(prefix, attrs)
    else
      result =
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            prefix <> ":catalog_masters_import"
          ])

          before = stored(type, ref, prefix)

          case upsert(prefix, attrs) do
            {:ok, %{outcome: outcome} = ok} when outcome in [:created, :updated] ->
              case audit(prefix, ctx.actor_id, type, ok, before, stored(type, ref, prefix)) do
                :ok -> {:ok, ok}
                {:error, _} = err -> Repo.rollback(err)
              end

            {:error, _} = refused ->
              # A refusal before the database leaves the transaction usable and wrote nothing; one
              # from the database (a unique constraint) aborted it, which only a rollback can end.
              if aborted?(), do: Repo.rollback(refused), else: refused

            other ->
              other
          end
        end)

      case result do
        {:ok, inner} -> inner
        {:error, {:error, _} = err} -> err
        {:error, other} -> {:error, other}
      end
    end
  end

  defp aborted? do
    match?({:error, _}, Repo.query("SELECT 1"))
  rescue
    _ -> true
  end

  defp upsert(prefix, attrs) do
    # scope-all: SEC-518-R1 (catalog_items module, tenant-wide types; import_scope_check/6 refuses a scoped caller)
    case Records.upsert_record_by_external_ref(
           attrs,
           prefix,
           ManagedTypes.owner_for!(CatalogItems)
         ) do
      {:ok, %{record: %Latest{record_id: record_id}, outcome: outcome}} ->
        {:ok, %{record_id: record_id, outcome: outcome}}

      {:error, _reason} = error ->
        error
    end
  end

  defp replay?(prefix, idem) when is_binary(idem),
    do:
      Repo.exists?(from(i in IdempotencyRecord, where: i.idempotency_key == ^idem),
        prefix: prefix
      )

  defp replay?(_prefix, _idem), do: false

  defp stored(type, ref, prefix) do
    case Latest.get_by_external_ref(type, ref.system, ref.id, prefix) do
      {:ok, %Latest{deleted: false, field_values: fv}} -> fv
      _ -> nil
    end
  end

  # INV-8: Audit raises on a database failure; the transaction is already aborted then, so the
  # rescue only turns the raise into a refusal and runs no further query.
  defp audit(
         prefix,
         actor_id,
         type,
         %{record_id: record_id, outcome: outcome},
         before,
         after_state
       ) do
    entry = %{
      actor_id: actor_id,
      action: "#{type}.#{outcome}",
      resource_type: type,
      resource_id: record_id,
      before_state: if(outcome == :created, do: nil, else: before),
      after_state: after_state
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :audit_failed}
    end
  rescue
    _ -> {:error, :audit_failed}
  end

  defp resolve_references(type, field_values, ref, prefix) do
    @references
    |> Map.get(type, [])
    |> Enum.reduce_while({:ok, field_values}, fn {field, target}, {:ok, acc} ->
      case Map.fetch(acc, field) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, cell} ->
          case resolve(cell, target, field, ref.system, prefix) do
            {:ok, record_id} -> {:cont, {:ok, Map.put(acc, field, record_id)}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  @doc false
  def resolve(cell, target, field, system, prefix) when is_binary(cell) do
    case Latest.get_by_external_ref(target, system, cell, prefix) do
      {:ok, %Latest{deleted: false, field_values: %{"active" => false}}} ->
        {:error, {:reference_inactive, field}}

      {:ok, %Latest{deleted: false, record_id: record_id}} ->
        {:ok, record_id}

      _absent_or_deleted ->
        {:error, {:reference_not_found, field}}
    end
  end

  def resolve(_cell, _target, field, _system, _prefix),
    do: {:error, {:reference_not_found, field}}
end
