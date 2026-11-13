defmodule Letflow.Currencies do
  @moduledoc """
  The tenant side of the currency directory (REQ-823, GH #4394, design
  `docs/design/currency-directory.md`): which currencies of the platform list
  (`Letflow.Currencies.Catalog`) the tenant has switched on, and which one is the tenant currency.

  **Reading rule (one rule).** A code is *active* when its `tenant_currencies` row says
  `active = true`, or, without a row, when it is `KZT`. The *tenant currency* is the code of the
  row with `tenant_currency = true`, or `KZT` without one. An untouched tenant therefore reads
  exactly what it reads today (D-097: one currency per tenant, KZT default).

  A plain transactional context (no process per tenant): the unique indexes on `code` and on the
  single true `tenant_currency` arbitrate concurrent writers. Every `Repo` call passes the tenant
  `prefix` (INV-1, INV-6); the tenant comes from the caller's auth context, never from input.
  No route and no module reads this yet (slice C1).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Currencies.Catalog
  alias Letflow.Currencies.Switch
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @aliases ["тенге", "теңге", "тг", "₸", "tenge"]

  @type reason ::
          :currency_unknown | :currency_is_tenant_currency | :invalid_body | :tenant_not_found

  @doc """
  Every platform entry with its `active` flag, ordered by code:
  `%{code, numeric_code, minor_units, names, active}`.
  """
  @spec list(String.t()) :: [map()]
  def list(prefix) do
    active = active_codes(prefix)
    Enum.map(Catalog.all(), &Map.put(&1, :active, MapSet.member?(active, &1.code)))
  end

  @doc "The tenant currency code: the flagged row's code, else `KZT`."
  @spec tenant_currency(String.t()) :: String.t()
  def tenant_currency(prefix) do
    from(s in Switch, where: s.tenant_currency == true, select: s.code, limit: 1)
    |> Repo.one(prefix: prefix)
    |> Kernel.||(Catalog.default_code())
  end

  @doc """
  The tenant currency code when a `tenant_currencies` row with `tenant_currency = true` exists,
  otherwise `nil`. Used by `Letflow.Modules.Assets.Settings.currency/1` to decide whether to
  trust the directory or fall back to the legacy assets setting (C4 / REQ-826).
  """
  @spec tenant_currency_opt(String.t()) :: String.t() | nil
  def tenant_currency_opt(prefix) do
    from(s in Switch, where: s.tenant_currency == true, select: s.code, limit: 1)
    |> Repo.one(prefix: prefix)
  end

  @doc "True when `code` is switched on for the tenant (and is in the platform list)."
  @spec active?(String.t(), term()) :: boolean()
  def active?(prefix, code) do
    Catalog.known?(code) and MapSet.member?(active_codes(prefix), code)
  end

  @doc """
  Switches one currency. `attrs` is `%{"active" => boolean}` with the optional
  `"tenant_currency" => true` (string or atom keys); any other key, a missing or non-boolean
  `active`, `tenant_currency` other than `true`, or `tenant_currency` with `active` false is
  `{:error, :invalid_body}`. An unknown code is `{:error, :currency_unknown}`; switching the
  tenant currency off is `{:error, :currency_is_tenant_currency}`.

  `tenant_currency: true` makes the code the tenant currency, switches it on and clears the flag
  of the previous row in the same transaction. One audit entry (`currencies.switched`) is written
  in that transaction; a refusal writes nothing.
  """
  @spec switch(String.t(), term(), term(), String.t() | nil) ::
          {:ok, map()} | {:error, reason() | term()}
  def switch(prefix, code, attrs, actor_id) do
    with {:ok, active, make_tenant?} <- check_body(attrs),
         {:ok, code} <- check_code(code),
         {:ok, tenant_id} <- tenant_id(prefix) do
      do_switch(prefix, tenant_id, code, active, make_tenant?, actor_id)
    end
  end

  @doc """
  Maps a stored text to a code of the list. A trimmed three-letter text equal to a code in any
  letter case gives `{:ok, code}`; the aliases `тенге`, `теңге`, `тг`, `₸`, `tenge` (any letter
  case) give `{:ok, "KZT"}`; anything else is `:unknown`.
  """
  @spec normalize(term()) :: {:ok, String.t()} | :unknown
  def normalize(text) when is_binary(text) do
    folded = text |> String.trim() |> String.downcase()
    upper = String.upcase(folded)

    cond do
      folded in @aliases -> {:ok, Catalog.default_code()}
      Regex.match?(~r/\A[a-z]{3}\z/, folded) and Catalog.known?(upper) -> {:ok, upper}
      true -> :unknown
    end
  end

  def normalize(_text), do: :unknown

  # --- reading ---------------------------------------------------------------------------

  defp active_codes(prefix) do
    rows = from(s in Switch, where: s.active == true, select: s.code) |> Repo.all(prefix: prefix)
    MapSet.new([Catalog.default_code() | rows]) |> remove_off_default(prefix)
  end

  # KZT is active without a row; an explicit row with active false switches it off.
  defp remove_off_default(set, prefix) do
    off? =
      from(s in Switch,
        where: s.code == ^Catalog.default_code() and s.active == false,
        select: true
      )
      |> Repo.one(prefix: prefix)

    if off?, do: MapSet.delete(set, Catalog.default_code()), else: set
  end

  # --- writing ---------------------------------------------------------------------------

  @body_keys ["active", "tenant_currency"]

  defp check_body(attrs) when is_map(attrs) do
    body = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with true <- Enum.all?(Map.keys(body), &(&1 in @body_keys)),
         active when is_boolean(active) <- Map.get(body, "active"),
         {:ok, make?} <- check_tenant_flag(body, active) do
      {:ok, active, make?}
    else
      _ -> {:error, :invalid_body}
    end
  end

  defp check_body(_attrs), do: {:error, :invalid_body}

  defp check_tenant_flag(body, active) do
    case Map.fetch(body, "tenant_currency") do
      :error -> {:ok, false}
      {:ok, true} when active -> {:ok, true}
      _ -> :error
    end
  end

  defp check_code(code) do
    if Catalog.known?(code), do: {:ok, code}, else: {:error, :currency_unknown}
  end

  defp tenant_id(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :tenant_not_found}
    end
  end

  defp do_switch(prefix, tenant_id, code, active, make_tenant?, actor_id) do
    result =
      Repo.transaction(fn ->
        current = tenant_currency(prefix)

        existing =
          Repo.one(from(s in Switch, where: s.code == ^code, lock: "FOR UPDATE"), prefix: prefix)

        if code == current and not active, do: Repo.rollback(:currency_is_tenant_currency)

        was_active = existing_active?(existing, code)
        flag? = make_tenant? or (existing != nil and existing.tenant_currency)
        now = DateTime.utc_now()

        if make_tenant? do
          from(s in Switch, where: s.tenant_currency == true and s.code != ^code)
          |> Repo.update_all(
            [set: [tenant_currency: false, updated_by: actor_id, updated_at: now]],
            prefix: prefix
          )
        end

        row = %Switch{
          tenant_id: tenant_id,
          code: code,
          active: active,
          tenant_currency: flag?,
          updated_by: actor_id,
          inserted_at: now,
          updated_at: now
        }

        {:ok, _} =
          Multi.new()
          |> Multi.insert(:switch, row,
            prefix: prefix,
            on_conflict: {:replace, [:active, :tenant_currency, :updated_by, :updated_at]},
            conflict_target: [:code]
          )
          |> Audit.append_multi(
            :audit,
            %{
              actor_id: actor_id,
              action: "currencies.switched",
              resource_type: "tenant_currency",
              resource_id: code,
              before_state: %{
                "code" => code,
                "active" => was_active,
                "tenant_currency" => code == current
              },
              after_state: %{
                "code" => code,
                "active" => active,
                "tenant_currency" => code == current or make_tenant?
              }
            },
            prefix
          )
          |> Repo.transaction()
          |> case do
            {:ok, changes} -> {:ok, changes}
            {:error, _step, reason, _} -> Repo.rollback(reason)
          end

        :ok
      end)

    case result do
      {:ok, :ok} -> {:ok, %{code: code, active: active, tenant_currency: tenant_currency(prefix)}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # A concurrent writer won the unique index on the single tenant-currency row (INV-8).
    e in [Ecto.ConstraintError, Postgrex.Error] ->
      if match?(%Postgrex.Error{postgres: %{code: :unique_violation}}, e) or
           is_struct(e, Ecto.ConstraintError),
         do: {:error, :conflict},
         else: reraise(e, __STACKTRACE__)
  end

  defp existing_active?(nil, code), do: code == Catalog.default_code()
  defp existing_active?(%Switch{active: active}, _code), do: active
end
