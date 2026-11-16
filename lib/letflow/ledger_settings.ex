defmodule Letflow.LedgerSettings do
  @moduledoc """
  REQ-835 (decision 0090 section 5, Qoimeks parity G4 part 3): the admin context behind
  `GET /ledger-settings` and `PUT /ledger-settings/:registration`, the per-tenant switch of negative
  balances. Built on the pattern of the four-eyes switch (`Letflow.ApprovalRules`).

  The stored setting is one row per registration name in the tenant schema (REQ-834; the row access
  is `Letflow.Ledger.NegativeBalanceSettings`); no row means refuse. The ledger core reads the row at the guard step
  (`Letflow.Ledger.negative_balances_allowed?/3`); this module only writes it.

  A registration is *switchable* when it declares `negative_balance: :tenant_setting` and belongs to a
  module installed (active) in the tenant. The registrations come from the ledger registry
  (`Application.get_env(:letflow, :ledger_registry)`, each entry carries `module_id` since REQ-835);
  one registration with several ledger ids is listed once. Today the compiled manifests declare none
  (module stock opts in with REQ-836), so the list is empty until then.

  `put/5` validates in this order and writes nothing before the last step: body (exactly
  `allow_negative` boolean and `reason`), reason, registration (`:not_switchable`), then, only when the
  value changes, the row and one `ledger_setting.changed` audit entry in ONE transaction. A PUT equal to
  the current value writes nothing. The tenant comes only from `prefix` (INV-1); names are bound
  parameters (INV-7).
  """

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Audit.Reason
  alias Letflow.Ledger.NegativeBalanceSettings, as: Settings
  alias Letflow.Modules.Installs
  alias Letflow.Repo

  @type item :: %{
          registration: String.t(),
          allow_negative: boolean(),
          changed_by: Ecto.UUID.t() | nil,
          changed_by_name: String.t() | nil,
          changed_at: DateTime.t() | nil,
          reason: String.t() | nil
        }

  @type actor :: %{user_id: Ecto.UUID.t(), trace_id: String.t() | nil}

  @doc "Every switchable registration of the tenant with its current value, sorted by name."
  @spec list(prefix :: String.t()) :: [item()]
  def list(prefix) when is_binary(prefix) do
    names = switchable_names(prefix)
    rows = Settings.rows(prefix, names)

    names
    |> Enum.map(&item(&1, Map.get(rows, &1)))
    |> with_names(prefix)
  end

  @doc "Switches one registration. `body` is `%{\"allow_negative\" => boolean, \"reason\" => string}`."
  @spec put(String.t(), String.t(), term(), actor()) ::
          {:ok, item()}
          | {:error,
             :invalid_body | :invalid_reason | :not_switchable | :conflict | :audit_failed}
  def put(prefix, registration, body, %{user_id: _} = actor)
      when is_binary(prefix) and is_binary(registration) do
    with {:ok, allow} <- fetch_allow(body),
         {:ok, reason} <- fetch_reason(body),
         :ok <- check_switchable(prefix, registration),
         {:ok, item} <- do_put(prefix, registration, allow, reason, actor) do
      # The name lookup runs after the commit, so a lookup failure never turns a switch into an error.
      {:ok, hd(with_names([item], prefix))}
    end
  end

  def put(_prefix, _registration, _body, _actor), do: {:error, :invalid_body}

  # Exactly the two keys: an extra key (or a missing allow_negative) is invalid_body. A missing or
  # blank reason is invalid_reason, so a body with only `allow_negative` plus an extra key is a body error.
  defp fetch_allow(%{"allow_negative" => value} = body) when is_boolean(value) do
    if Map.keys(body) -- ["allow_negative", "reason"] == [],
      do: {:ok, value},
      else: {:error, :invalid_body}
  end

  defp fetch_allow(_body), do: {:error, :invalid_body}

  defp fetch_reason(%{"reason" => reason}) do
    case Reason.validate(reason) do
      {:ok, trimmed} -> {:ok, trimmed}
      :error -> {:error, :invalid_reason}
    end
  end

  defp fetch_reason(_body), do: {:error, :invalid_reason}

  defp check_switchable(prefix, registration) do
    if registration in switchable_names(prefix), do: :ok, else: {:error, :not_switchable}
  end

  # Names of the registrations that declare `:tenant_setting` and whose module is active in the tenant.
  defp switchable_names(prefix) do
    case Application.get_env(:letflow, :ledger_registry, %{}) do
      %{} = registry ->
        registry
        |> Map.values()
        |> Enum.filter(&settable?/1)
        |> Enum.filter(&Installs.installed?(&1.module_id, prefix: prefix))
        |> Enum.map(& &1.name)
        |> Enum.uniq()
        |> Enum.sort()

      _other ->
        []
    end
  end

  defp settable?(%{
         name: name,
         module_id: module_id,
         registration: %{negative_balance: :tenant_setting}
       })
       when is_binary(name) and is_binary(module_id),
       do: true

  defp settable?(_entry), do: false

  defp do_put(prefix, name, allow, reason, actor) do
    result =
      Repo.transaction(fn ->
        existing = Settings.lock(prefix, name)

        old = if existing, do: existing.allow_negative, else: false

        if old == allow do
          item(name, current_row(prefix, name))
        else
          row = Settings.write!(prefix, existing, name, allow, reason, actor.user_id)
          audit!(prefix, row, name, old, allow, reason, actor)
          item(name, row)
        end
      end)

    case result do
      {:ok, item} -> {:ok, item}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in [Ecto.ConstraintError, Postgrex.Error] ->
      if match?(%Postgrex.Error{postgres: %{code: :unique_violation}}, e) or
           is_struct(e, Ecto.ConstraintError),
         do: {:error, :conflict},
         else: {:error, :audit_failed}

    _other ->
      {:error, :audit_failed}
  end

  defp current_row(prefix, name), do: Map.get(Settings.rows(prefix, [name]), name)

  defp audit!(prefix, row, name, old, new, reason, actor) do
    {:ok, _} =
      Multi.new()
      |> Audit.append_multi(
        :audit,
        %{
          actor_id: actor.user_id,
          action: "ledger_setting.changed",
          resource_type: "ledger_setting",
          resource_id: row.id,
          before_state: %{"registration" => name, "allow_negative" => old},
          after_state: %{"registration" => name, "allow_negative" => new, "reason" => reason},
          trace_id: Map.get(actor, :trace_id)
        },
        prefix
      )
      |> Repo.transaction()

    :ok
  end

  # Adds `changed_by_name` with one tenant-scoped query. Never raises: a failed lookup leaves nil.
  defp with_names(items, prefix) do
    ids = items |> Enum.map(& &1.changed_by) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    names =
      try do
        Audit.user_names(ids, prefix)
      rescue
        _ -> %{}
      end

    Enum.map(items, fn i ->
      Map.put(i, :changed_by_name, i.changed_by && Map.get(names, to_string(i.changed_by)))
    end)
  end

  defp item(name, row) do
    %{
      registration: name,
      allow_negative: row != nil and row.allow_negative,
      changed_by: row && row.changed_by,
      changed_at: row && row.changed_at,
      reason: row && row.reason
    }
  end
end
