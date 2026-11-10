defmodule Letflow.ModuleUpgrade.Settings do
  @moduledoc """
  The module-upgrade settings (decision 0080 Q5): the record-count cap of the one-transaction
  data-step apply. Key `:module_upgrade_one_tx_max_records` under `:letflow`, environment variable
  `LETFLOW_MODULE_UPGRADE_ONE_TX_MAX_RECORDS`, starting value 1000 records. A plan whose data steps
  would touch more records is refused as `upgrade_needs_runner` (a later runner slice runs it).
  """

  @default 1000
  @max 100_000

  @doc "The cap read at call time (a missing or invalid value falls back to the default)."
  @spec one_tx_max_records() :: pos_integer()
  def one_tx_max_records do
    case Application.get_env(:letflow, :module_upgrade_one_tx_max_records, @default) do
      value when is_integer(value) and value >= 1 and value <= @max -> value
      _other -> @default
    end
  end

  @doc """
  Parses the environment value: `nil` gives the default; otherwise a base-10 integer string in
  1..100000. Anything else raises WITHOUT echoing the value.
  """
  @spec parse_one_tx_max_records(String.t() | nil) :: pos_integer()
  def parse_one_tx_max_records(nil), do: @default

  def parse_one_tx_max_records(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 1 and int <= @max ->
        int

      _other ->
        raise "environment variable LETFLOW_MODULE_UPGRADE_ONE_TX_MAX_RECORDS must be an integer " <>
                "from 1 to #{@max}. The value is not echoed."
    end
  end

  @halt_default 3
  @halt_max 1000

  @doc """
  RU-S6: the fleet driver halts a rollout after this many consecutive failed tenants. Key
  `:module_rollout_halt_after`, environment variable `LETFLOW_MODULE_ROLLOUT_HALT_AFTER`, starting
  value 3 (a setting, not a rule).
  """
  @spec rollout_halt_after() :: pos_integer()
  def rollout_halt_after do
    case Application.get_env(:letflow, :module_rollout_halt_after, @halt_default) do
      value when is_integer(value) and value >= 1 and value <= @halt_max -> value
      _other -> @halt_default
    end
  end

  @doc "Parses the environment value: `nil` gives 3; otherwise an integer 1..1000. Else raises without echoing."
  @spec parse_rollout_halt_after(String.t() | nil) :: pos_integer()
  def parse_rollout_halt_after(nil), do: @halt_default

  def parse_rollout_halt_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 1 and int <= @halt_max ->
        int

      _other ->
        raise "environment variable LETFLOW_MODULE_ROLLOUT_HALT_AFTER must be an integer " <>
                "from 1 to #{@halt_max}. The value is not echoed."
    end
  end
end
