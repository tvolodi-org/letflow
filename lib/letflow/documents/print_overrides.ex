defmodule Letflow.Documents.PrintOverrides do
  @moduledoc """
  Per-tenant print-layout overrides, part 1 of REQ-579 (GH #3289, decision 0068 D3, D7, D8 S2):
  storage and context only; the routes and the permission are part 2.

  An override is one saved layout for a `(type_key, locale)` pair with a status
  `draft -> active -> retired`. `save_draft/3` always inserts a new draft with the next
  server-side `version_no`; `activate/4` turns a draft into the one active row of its pair and
  retires the previous active row in the same transaction; `retire/4` retires an active row.
  `get/2` returns one row with its layout, `list/2` returns metadata only (never `:layout`).
  Every function takes the tenant schema name `prefix` first (INV-1, INV-6), reads only the
  atom keys documented per function from `attrs` (a `tenant_id`, `version_no`, `status` or
  `created_by` in `attrs` is ignored by construction), and answers an absent id, a malformed id
  and (by prefix) another tenant's row identically: `{:error, :not_found}` (INV-5).

  Layouts are validated with `Letflow.Documents.PrintLayout.validate/3` against the type's
  `declared_fields` and the tenant's `entity_field_restrictions`. A layout naming a restricted
  field is refused even on a `DocumentType` with `restricted_fields_allowed`: REQ-579 says a
  restricted field is refused, and that is deliberate. Free fields (the `"_free"` entry of
  `declared_fields`) cannot be named by a layout. A violation is `%{rule, path}` and never carries
  a value. Layout numbers must be integers: the canonical form used for `layout_hash` refuses
  floats, so a layout that passes validation with a float is `{:error, {:unprocessable,
  :invalid_layout}}` (a different shape from `{:invalid_layout, violations}`; part 2 maps both to
  422). `activate/4` re-validates the layout against the current type and restrictions.

  Q3 assumption (recorded in the PR): activation needs two principals. The activator must differ
  from the draft's `created_by`; it is enforced here (`{:conflict, :needs_second_admin}`) and by
  `CHECK (activated_by <> created_by)`. Switching to a single-admin rule later takes a follow-up
  migration and a change here.

  Each successful call writes exactly one audit row in the same transaction
  (`document.print_override_saved`, `_activated`, `_retired`), shaped like
  `Letflow.Documents.Hold`. The payload keys are exactly `override_id`, `type_key`, `locale`,
  `version_no`, `layout_hash`, `actor_id`, `reason_code`: no layout, no free text (decision 0056
  D9). The implicit retirement of the superseded active row (`reason_code "superseded"`) writes
  no audit row of its own. A refusal writes no audit row. Lock order: the override row
  (`FOR UPDATE`), the per-pair advisory lock, then the audit chain row inside
  `Letflow.Audit.insert_entry/3` last. `Audit.insert_entry/3` raises on a database failure; the
  transaction rolls back and the raise propagates, as in `Hold`.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Documents.Canonical
  alias Letflow.Documents.DocumentType
  alias Letflow.Documents.PrintLayout
  alias Letflow.Documents.PrintOverride
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @locales ~w(ru kk default)
  @reason_code_re ~r/^[a-z][a-z0-9_]{0,63}$/
  @free "_free"

  @type violation :: %{rule: atom(), path: list()}
  @type error ::
          {:error, :not_found | :invalid_schema_name}
          | {:error, {:unprocessable, atom()}}
          | {:error, {:invalid_layout, [violation()]}}
          | {:error, {:conflict, :not_a_draft | :not_active | :needs_second_admin}}
          | {:error, term()}

  @doc """
  Saves a new draft. `attrs`: `:type_key`, `:locale` (`ru`, `kk`, `default`), `:layout`.
  The caller is `created_by`.
  """
  @spec save_draft(String.t(), map(), term()) :: {:ok, %PrintOverride{}} | error()
  def save_draft(prefix, attrs, actor_id) when is_binary(prefix) and is_map(attrs) do
    type_key = Map.get(attrs, :type_key)
    locale = Map.get(attrs, :locale)
    layout = Map.get(attrs, :layout)

    with {:ok, actor_id} <- validate_actor(actor_id),
         :ok <- validate_locale(locale),
         :ok <- validate_type_key(type_key),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         :ok <- validate_layout(prefix, type_key, layout),
         {:ok, bytes} <- canonical(layout) do
      hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      now = DateTime.utc_now()

      Repo.transaction(fn ->
        lock_pair(prefix, type_key, locale)

        row =
          Repo.insert!(
            %PrintOverride{
              id: Ecto.UUID.generate(),
              tenant_id: tenant_id,
              type_key: type_key,
              locale: locale,
              version_no: next_version(prefix, type_key, locale),
              status: "draft",
              layout: layout,
              layout_hash: hash,
              layout_schema_version: layout["layout_schema_version"],
              created_by: actor_id,
              reason_code: nil,
              inserted_at: now,
              updated_at: now
            },
            prefix: prefix
          )

        write_event(:saved, prefix, row, actor_id)
        row
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Activates a draft. `attrs`: `:reason_code` (format only). The caller must differ from the
  draft's `created_by`.
  """
  @spec activate(String.t(), term(), map(), term()) :: {:ok, %PrintOverride{}} | error()
  def activate(prefix, id, attrs, actor_id) when is_binary(prefix) do
    with {:ok, code} <- validate_reason(attrs),
         {:ok, actor_id} <- validate_actor(actor_id),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, id} <- cast_id(id) do
      Repo.transaction(fn ->
        case do_activate(prefix, id, code, actor_id) do
          {:ok, row} -> row
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Retires an active override. `attrs`: `:reason_code` (format only). The creator may retire."
  @spec retire(String.t(), term(), map(), term()) :: {:ok, %PrintOverride{}} | error()
  def retire(prefix, id, attrs, actor_id) when is_binary(prefix) do
    with {:ok, code} <- validate_reason(attrs),
         {:ok, actor_id} <- validate_actor(actor_id),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, id} <- cast_id(id) do
      Repo.transaction(fn ->
        case do_retire(prefix, id, code, actor_id) do
          {:ok, row} -> row
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "One override with its layout."
  @spec get(String.t(), term()) :: {:ok, %PrintOverride{}} | {:error, :not_found}
  def get(prefix, id) when is_binary(prefix) do
    with {:ok, id} <- cast_id(id),
         %PrintOverride{} = row <- Repo.get(PrintOverride, id, prefix: prefix) do
      {:ok, row}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Metadata of the overrides (every column except `:layout`), newest version first per pair.
  `filters`: optional `:type_key`, `:locale` (equality; ignored when not strings).
  """
  @spec list(String.t(), map() | keyword()) ::
          {:ok, [map()]} | {:error, :invalid_schema_name}
  def list(prefix, filters \\ %{}) when is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      fields = PrintOverride.metadata_fields()

      query =
        from(o in PrintOverride,
          order_by: [asc: o.type_key, asc: o.locale, desc: o.version_no],
          select: map(o, ^fields)
        )

      query =
        Enum.reduce([:type_key, :locale], query, fn key, q ->
          case Access.get(filters, key) do
            value when is_binary(value) -> where(q, [o], field(o, ^key) == ^value)
            _ -> q
          end
        end)

      {:ok, Repo.all(query, prefix: prefix)}
    end
  end

  @doc "The fixed 409 text of a context-level conflict reason."
  @spec conflict_reason(:not_a_draft | :not_active | :needs_second_admin) :: String.t()
  def conflict_reason(:needs_second_admin), do: "activation needs a second administrator"

  def conflict_reason(reason) when reason in [:not_a_draft, :not_active],
    do: "override is not in a status that allows this action"

  # -- transitions --------------------------------------------------------------------------

  defp do_activate(prefix, id, code, actor_id) do
    case lock_row(prefix, id) do
      nil ->
        {:error, :not_found}

      %PrintOverride{status: status} when status != "draft" ->
        {:error, {:conflict, :not_a_draft}}

      %PrintOverride{created_by: ^actor_id} ->
        {:error, {:conflict, :needs_second_admin}}

      %PrintOverride{} = row ->
        lock_pair(prefix, row.type_key, row.locale)

        with :ok <- validate_layout(prefix, row.type_key, row.layout) do
          now = DateTime.utc_now()

          # the previous active row first, so the partial unique index never sees two
          from(o in PrintOverride,
            where:
              o.type_key == ^row.type_key and o.locale == ^row.locale and o.status == "active"
          )
          |> Repo.update_all(
            [
              set: [
                status: "retired",
                retired_at: now,
                reason_code: "superseded",
                updated_at: now
              ]
            ],
            prefix: prefix
          )

          from(o in PrintOverride, where: o.id == ^id)
          |> Repo.update_all(
            [
              set: [
                status: "active",
                activated_by: actor_id,
                activated_at: now,
                reason_code: code,
                updated_at: now
              ]
            ],
            prefix: prefix
          )

          updated = Repo.get!(PrintOverride, id, prefix: prefix)
          write_event(:activated, prefix, updated, actor_id)
          {:ok, updated}
        end
    end
  end

  defp do_retire(prefix, id, code, actor_id) do
    case lock_row(prefix, id) do
      nil ->
        {:error, :not_found}

      %PrintOverride{status: status} when status != "active" ->
        {:error, {:conflict, :not_active}}

      %PrintOverride{} ->
        now = DateTime.utc_now()

        from(o in PrintOverride, where: o.id == ^id)
        |> Repo.update_all(
          [set: [status: "retired", retired_at: now, reason_code: code, updated_at: now]],
          prefix: prefix
        )

        updated = Repo.get!(PrintOverride, id, prefix: prefix)
        write_event(:retired, prefix, updated, actor_id)
        {:ok, updated}
    end
  end

  defp lock_row(prefix, id) do
    from(o in PrintOverride, where: o.id == ^id, lock: "FOR UPDATE")
    |> Repo.one(prefix: prefix)
  end

  # Advisory locks are database-wide, so the schema name is part of the key.
  defp lock_pair(prefix, type_key, locale) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      prefix <> ":" <> type_key <> ":" <> locale
    ])
  end

  defp next_version(prefix, type_key, locale) do
    from(o in PrintOverride,
      where: o.type_key == ^type_key and o.locale == ^locale,
      select: coalesce(max(o.version_no), 0) + 1
    )
    |> Repo.one!(prefix: prefix)
  end

  # -- audit --------------------------------------------------------------------------------

  defp write_event(kind, prefix, %PrintOverride{} = row, actor_id) do
    entry = %{
      actor_id: actor_id,
      action: action(kind),
      resource_type: "document_print_override",
      resource_id: row.id,
      before_state: nil,
      after_state: %{
        "override_id" => row.id,
        "type_key" => row.type_key,
        "locale" => row.locale,
        "version_no" => row.version_no,
        "layout_hash" => row.layout_hash,
        "actor_id" => actor_id,
        "reason_code" => row.reason_code
      }
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp action(:saved), do: "document.print_override_saved"
  defp action(:activated), do: "document.print_override_activated"
  defp action(:retired), do: "document.print_override_retired"

  # -- layout -------------------------------------------------------------------------------

  defp validate_layout(prefix, type_key, layout) do
    case Repo.get(DocumentType, type_key, prefix: prefix) do
      nil ->
        {:error, {:unprocessable, :unknown_type_key}}

      %DocumentType{declared_fields: declared} ->
        # `declared_pairs` keeps list-valued entries only, so the map-valued "_free" entry is
        # skipped: free fields cannot be named by a layout.
        declared = if is_map(declared), do: declared, else: %{}
        entity_types = declared |> Map.delete(@free) |> Map.keys()

        restricted =
          from(r in "entity_field_restrictions",
            where: r.entity_type in ^entity_types,
            select: {r.entity_type, r.field_name}
          )
          |> Repo.all(prefix: prefix)

        case PrintLayout.validate(layout, declared, restricted: restricted) do
          :ok -> :ok
          {:error, violations} -> {:error, {:invalid_layout, violations}}
        end
    end
  end

  defp canonical(layout) do
    case Canonical.canonicalize(layout) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> {:error, {:unprocessable, :invalid_layout}}
    end
  end

  # -- input --------------------------------------------------------------------------------

  defp validate_locale(locale) when locale in @locales, do: :ok
  defp validate_locale(_), do: {:error, {:unprocessable, :invalid_locale}}

  defp validate_type_key(key) when is_binary(key) and key != "", do: :ok
  defp validate_type_key(_), do: {:error, {:unprocessable, :unknown_type_key}}

  defp validate_reason(attrs) when is_map(attrs) do
    code = Map.get(attrs, :reason_code)

    if is_binary(code) and Regex.match?(@reason_code_re, code),
      do: {:ok, code},
      else: {:error, {:unprocessable, :invalid_reason_code}}
  end

  defp validate_reason(_), do: {:error, {:unprocessable, :invalid_reason_code}}

  defp validate_actor(actor) when is_binary(actor) do
    case Ecto.UUID.cast(actor) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:unprocessable, :invalid_actor}}
    end
  end

  defp validate_actor(_), do: {:error, {:unprocessable, :invalid_actor}}

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast_id(_), do: {:error, :not_found}
end
