defmodule Letflow.Modules.Assets.Settings do
  @moduledoc """
  The two module-setting readers of `Letflow.Modules.Assets` (`currency/1`, `expiry_lead_days/1`),
  moved out of the entry file in C10 (GH #3890 / REQ-752): once the module declares write handlers,
  `handler_writes_callers_test` scans the entry file and forbids `alias Letflow.Repo` there. The
  entry file keeps its public names as `defdelegate`s; behaviour is unchanged. The tenant comes only
  from `prefix` (INV-1).
  """

  alias Letflow.Modules.TenantModule
  alias Letflow.Repo

  @default_currency "KZT"

  @doc "The tenant currency of `prefix`: the `currency` setting of the active install, `\"KZT\"` otherwise (D-097)."
  @spec currency(prefix :: String.t()) :: String.t()
  def currency(prefix) when is_binary(prefix) do
    case Repo.get_by(TenantModule, [module_id: "assets", status: :active], prefix: prefix) do
      %TenantModule{settings: %{"currency" => c}} when is_binary(c) and byte_size(c) == 3 -> c
      _ -> @default_currency
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
end
