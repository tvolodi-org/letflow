defmodule Letflow.Fixtures.G10Broken do
  @moduledoc """
  A deliberately broken configuration surface: the fixture of the G-10 probe.

  Every read in this file breaks exactly one rule of the registry, so the probe has to report
  it. The file is a fixture under `test/fixtures/`, is never compiled by the suite and exists
  only so the probe can prove that it is not vacuous.

  The rules it breaks:

    * `G10_UNREGISTERED_SETTING` is read but is not in the registry;
    * `G10_LIST_SETTING` is named in a list the boot reads and is not in the registry;
    * `G10_ATTRIBUTE_SETTING` is named by a module attribute and is not in the registry;
    * `G10_LOCAL_SETTING` is named by a local variable and is not in the registry;
    * `:g10_flag_enabled` is a feature flag read with a default that turns it on;
    * `:g10_secret` is a secret read with a literal default;
    * `:g10_runtime_key` is read while the code is compiled but registered as a runtime read.

  The file takes no environment map, so the rule of the module that parses the environment does
  not fire here: every name below is found by its own form.
  """

  @g10_credential "G10_ATTRIBUTE_SETTING"

  def unregistered_env, do: System.get_env("G10_UNREGISTERED_SETTING")

  def list_env do
    ~w(G10_LIST_SETTING)
    |> Map.new(fn name -> {name, System.get_env(name)} end)
  end

  def attribute_env, do: System.get_env(@g10_credential)

  def local_env do
    name = "G10_LOCAL_SETTING"

    System.get_env(name)
  end

  def flag_on_by_default, do: Application.get_env(:letflow, :g10_flag_enabled, true)

  def secret_with_a_literal, do: Application.get_env(:letflow, :g10_secret, "g10-literal-secret")

  def read_at_compile_time, do: Application.compile_env(:letflow, :g10_runtime_key)
end
