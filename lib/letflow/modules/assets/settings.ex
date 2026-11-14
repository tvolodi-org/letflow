defmodule Letflow.Modules.Assets.Settings do
  @moduledoc """
  The module-setting readers of `Letflow.Modules.Assets` (`currency/1`, `expiry_lead_days/1`, and since REQ-816 the
  asset count settings `count_enabled?/1`, `count_signer_role/1`, `count_freeze_limit_minutes/1`),
  moved out of the entry file in C10 (GH #3890 / REQ-752): once the module declares write handlers,
  `handler_writes_callers_test` scans the entry file and forbids `alias Letflow.Repo` there. The
  entry file keeps its public names as `defdelegate`s; behaviour is unchanged. The tenant comes only
  from `prefix` (INV-1).

  `currency/1` reads the directory tenant currency (C4 / REQ-826) with the legacy assets setting
  as fallback for tenants not yet migrated by the C3 release task.
  """

  alias Letflow.Currencies
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo

  @default_currency "KZT"
  @default_signer_role "accountant"
  @default_freeze_limit 120

  @doc """
  The tenant currency of `prefix` (C4 / REQ-826, D-097), in this order:

  1. The code from the `tenant_currencies` row with `tenant_currency = true` (directory, C1/C2).
  2. The result of `Letflow.Currencies.normalize/1` on the legacy assets setting (handles lower-case
     and known aliases such as `KZT`).
  3. The assets setting as stored when it is exactly three characters (legacy unknown value,
     kept so an unmigrated tenant reads its old value until the C3 release task runs).
  4. `\"KZT\"` (D-097 default).
  """
  @spec currency(prefix :: String.t()) :: String.t()
  def currency(prefix) when is_binary(prefix) do
    case Currencies.tenant_currency_opt(prefix) do
      code when is_binary(code) ->
        code

      nil ->
        setting =
          case Repo.get_by(TenantModule, [module_id: "assets", status: :active], prefix: prefix) do
            %TenantModule{settings: %{"currency" => c}} when is_binary(c) -> c
            _ -> nil
          end

        case Currencies.normalize(setting) do
          {:ok, code} ->
            code

          :unknown when is_binary(setting) and byte_size(setting) == 3 ->
            setting

          _ ->
            @default_currency
        end
    end
  end

  @doc "The reminder lead time in days (1..3650), `nil` when absent, invalid or the module is not installed."
  @spec expiry_lead_days(prefix :: String.t()) :: pos_integer() | nil
  def expiry_lead_days(prefix) when is_binary(prefix) do
    case Repo.get_by(TenantModule, [module_id: "assets", status: :active], prefix: prefix) do
      %TenantModule{settings: %{"expiry_reminder_lead_days" => d}}
      when is_integer(d) and d >= 1 and d <= 3650 ->
        d

      _ ->
        nil
    end
  end

  @doc """
  REQ-816: the flag of the asset count routes. `true` only when the stored value is exactly `true`;
  absent, `false`, any other value or a module that is not installed is `false` (default off).
  """
  @spec count_enabled?(prefix :: String.t()) :: boolean()
  def count_enabled?(prefix) when is_binary(prefix) do
    match?(%{"count_enabled" => true}, active_settings(prefix))
  end

  @doc "REQ-816: the role that signs a count sheet (1..128 codepoints); `\"accountant\"` when absent or invalid."
  @spec count_signer_role(prefix :: String.t()) :: String.t()
  def count_signer_role(prefix) when is_binary(prefix) do
    case active_settings(prefix) do
      %{"count_signer_role" => r} when is_binary(r) ->
        if String.length(r) in 1..128, do: r, else: @default_signer_role

      _ ->
        @default_signer_role
    end
  end

  @doc "REQ-816: the longest freeze of locations in minutes (1..5760); 120 when absent or invalid."
  @spec count_freeze_limit_minutes(prefix :: String.t()) :: 1..5760
  def count_freeze_limit_minutes(prefix) when is_binary(prefix) do
    case active_settings(prefix) do
      %{"count_freeze_limit_minutes" => m} when is_integer(m) and m >= 1 and m <= 5760 -> m
      _ -> @default_freeze_limit
    end
  end

  defp active_settings(prefix) do
    case Repo.get_by(TenantModule, [module_id: "assets", status: :active], prefix: prefix) do
      %TenantModule{settings: %{} = settings} -> settings
      _ -> %{}
    end
  end
end
