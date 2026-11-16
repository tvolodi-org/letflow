defmodule Letflow.Modules.Codes.Import do
  @moduledoc """
  The import function of `code_tag` (G12 part 1, GH #4569 / REQ-850, manifest `:import_functions`): one
  row of a file, called by the core through `Letflow.Modules.Catalog.call_import_function/5` as
  `row(prefix, entry, ctx)`. Route: `POST /api/v1/entities/records/code_tag/import`; access is the
  core rule (TENANT_ADMIN imports, a STOREKEEPER is refused).

  A code is identified by its VALUE (model rule R2), not by the row's external ref: the `code_tag`
  definition has no external-ref fields, so the ref pair of the row is only the route's row key.

  Per row, in this order:

    1. a `status` cell is `{:field_not_allowed, "status"}`: an imported code is always `not_assigned`;
    2. `value` must pass the rule of `Letflow.Modules.Codes.Writes.receive_codes/3` (non-empty valid
       text without a NUL byte; a blank or absent cell fails), else `:value_invalid`; `kind` must be
       `barcode`, `qr`, `epc` or `tid`, else `:kind_invalid`;
    3. a live code with that value and the same kind is `:unchanged` (nothing written); with another
       kind it is `:value_taken` (a code is never changed by import);
    4. otherwise one `not_assigned` `code_tag` and one audit entry `code.received` are written in
       one transaction under the module's tenant advisory lock, the way `receive_codes/3` writes them.

  Refusal atoms are constants (rendered by the route without cell text). `ctx.dry_run` is accepted and
  unused: the core owns the rollback. No effect outside `prefix`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Modules.Codes
  alias Letflow.Repo

  @kinds ~w(barcode qr epc tid)

  @spec row(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, %{record_id: Ecto.UUID.t(), outcome: :created | :unchanged}} | {:error, term()}
  def row(prefix, %{entity_type: "code_tag", field_values: cells}, ctx)
      when is_binary(prefix) and is_map(cells) do
    value = Map.get(cells, "value")
    kind = Map.get(cells, "kind")

    cond do
      Map.has_key?(cells, "status") -> {:error, {:field_not_allowed, "status"}}
      not valid_value?(value) -> {:error, :value_invalid}
      kind not in @kinds -> {:error, :kind_invalid}
      true -> persist(prefix, value, kind, ctx)
    end
  end

  # One transaction under the same advisory lock as `Writes` (keyed by the schema and the text
  # `codes`), so the existence check and the write are one step. A Records refusal before the
  # database wrote nothing; a database refusal aborted the transaction and only a rollback ends it.
  defp persist(prefix, value, kind, ctx) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [prefix <> ":codes"])

        case existing(prefix, value) do
          %Latest{record_id: id, field_values: %{"kind" => ^kind}} ->
            {:ok, %{record_id: id, outcome: :unchanged}}

          %Latest{} ->
            {:error, :value_taken}

          nil ->
            create(prefix, value, kind, ctx)
        end
      end)

    case result do
      {:ok, inner} -> inner
      {:error, {:error, _} = err} -> err
      {:error, other} -> {:error, other}
    end
  end

  defp create(prefix, value, kind, ctx) do
    fv = %{"value" => value, "kind" => kind, "status" => "not_assigned"}

    attrs = %{
      entity_type: "code_tag",
      field_values: fv,
      actor_id: ctx.actor_id,
      idempotency_key: ctx.idempotency_key
    }

    if replay?(prefix, ctx.idempotency_key) do
      {:error, :idempotency_key_reuse}
    else
      # scope-all: SEC-518-R1 (codes module, tenant-wide types; own-record system path)
      case Records.create_record(attrs, prefix, ManagedTypes.owner_for!(Codes)) do
        {:ok, %{record: record}} ->
          case audit(prefix, ctx.actor_id, record.record_id, fv) do
            :ok -> {:ok, %{record_id: record.record_id, outcome: :created}}
            {:error, _} = err -> Repo.rollback(err)
          end

        {:error, reason} ->
          if aborted?(), do: Repo.rollback({:error, reason}), else: {:error, reason}
      end
    end
  end

  defp existing(prefix, value) do
    Repo.one(
      from(l in Latest,
        where:
          l.entity_type == "code_tag" and l.deleted == false and
            fragment("?->>'value' = ?", l.field_values, ^value),
        limit: 1
      ),
      prefix: prefix
    )
  end

  defp replay?(prefix, idem) when is_binary(idem),
    do:
      Repo.exists?(from(i in IdempotencyRecord, where: i.idempotency_key == ^idem),
        prefix: prefix
      )

  defp replay?(_prefix, _idem), do: false

  defp aborted? do
    match?({:error, _}, Repo.query("SELECT 1"))
  rescue
    _ -> true
  end

  # INV-8: Audit raises on a database failure; the transaction is already aborted then.
  defp audit(prefix, actor_id, record_id, after_state) do
    entry = %{
      actor_id: actor_id,
      action: "code.received",
      resource_type: "code_tag",
      resource_id: record_id,
      before_state: nil,
      after_state: after_state
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :audit_failed}
    end
  rescue
    _ -> {:error, :audit_failed}
  end

  defp valid_value?(v),
    do: is_binary(v) and v != "" and String.valid?(v) and not String.contains?(v, <<0>>)
end
