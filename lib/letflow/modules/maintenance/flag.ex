defmodule Letflow.Modules.Maintenance.Flag do
  @moduledoc """
  The release flag of module `maintenance` (REQ-893): `config :letflow, :maintenance_enabled` is
  `false` in `config/config.exs` and turned on only by `config/test.exs` (no environment variable,
  no `runtime.exs` line). This module is the flag's only reader;
  `Letflow.Modules.Maintenance.enabled?/0` delegates to it.

  The reader lives in its own file because the entry module of a module that registers write
  handlers is scanned for handler purity (the H4 scan of
  `test/letflow/entities/handler_writes_callers_test.exs`), and that scan forbids the platform's
  configuration read (`Application`) in the entry file. The assets module reads its own flag the
  same way (`Letflow.Modules.Assets.Reminders.enabled?/0`).
  """

  @doc "True when the release flag `:maintenance_enabled` is on (default and production: off)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:letflow, :maintenance_enabled, false) == true
end
