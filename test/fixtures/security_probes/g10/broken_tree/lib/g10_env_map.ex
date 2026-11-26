defmodule Letflow.Fixtures.G10EnvMap do
  @moduledoc """
  The second half of the seeded fixture of the G-10 probe: a module that parses the operating
  system environment.

  It takes a map of variable names to raw values (`env`) and reads it with `Map.get/2`, the way
  `Letflow.TenantProvisioner.Config` and `Letflow.LoginDiscovery.Notifier.Smtp.Config` do. The
  name it looks up is therefore a variable of the operating system, and the registry has to
  name it.
  """

  def setting(env), do: Map.get(env, "G10_ENV_MAP_SETTING")
end
