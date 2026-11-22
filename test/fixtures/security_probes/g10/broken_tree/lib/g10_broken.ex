defmodule Letflow.Fixtures.G10Broken do
  @moduledoc """
  A deliberately broken configuration surface: the fixture of the G-10 probe.

  Every read in this file breaks exactly one rule of the registry, so the probe has to report
  it. The file is a fixture under `test/fixtures/`, is never compiled by the suite and exists
  only so the probe can prove that it is not vacuous.

  The rules it breaks:

    * `G10_UNREGISTERED_SETTING` is read but is not in the registry;
    * `:g10_flag_enabled` is a feature flag read with a default that turns it on;
    * `:g10_secret` is a secret read with a literal default;
    * `:g10_runtime_key` is read while the code is compiled but registered as a runtime read.
  """

  def unregistered_env, do: System.get_env("G10_UNREGISTERED_SETTING")

  def flag_on_by_default, do: Application.get_env(:letflow, :g10_flag_enabled, true)

  def secret_with_a_literal, do: Application.get_env(:letflow, :g10_secret, "g10-literal-secret")

  def read_at_compile_time, do: Application.compile_env(:letflow, :g10_runtime_key)
end
