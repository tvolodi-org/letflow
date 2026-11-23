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
    * `G10_ATTRIBUTE_LIST_SETTING` is named in a list a module attribute holds and is not in
      the registry;
    * `G10_HEAD_DEFAULT_SETTING` is read in the default argument of a function head and is not
      in the registry;
    * `G10_STATUS_PENDING` and `G10_STATUS_DONE` are named in a list a module attribute holds
      whose consumer does not read the environment: they are not variables and must not be
      reported;
    * `:g10_flag_enabled` is a feature flag read with a default that turns it on;
    * `:g10_secret` is a secret read with a literal default;
    * `:g10_runtime_key` is read while the code is compiled but registered as a runtime read.

  The file takes no environment map, so the rule of the module that parses the environment does
  not fire here: every name below is found by its own form.
  """

  @g10_credential "G10_ATTRIBUTE_SETTING"

  @env_list_names ~w(G10_ATTRIBUTE_LIST_SETTING)

  @g10_statuses ~w(G10_STATUS_PENDING G10_STATUS_DONE)

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

  # The list the attribute holds is a list of variables, because the function that consumes it
  # reads the environment.
  def attribute_list_env do
    for var_name <- @env_list_names, into: %{}, do: {var_name, System.get_env(var_name)}
  end

  # A list of something else is not a list of variables: the function that consumes this one
  # does not read the environment, so its words are not names of the operating system.
  def status_env do
    for status <- @g10_statuses, do: {status, status}
  end

  # A read in the default argument of a head is a read like any other.
  def head_default_env(_current \\ System.get_env("G10_HEAD_DEFAULT_SETTING")), do: :ok

  def flag_on_by_default, do: Application.get_env(:letflow, :g10_flag_enabled, true)

  def secret_with_a_literal, do: Application.get_env(:letflow, :g10_secret, "g10-literal-secret")

  def read_at_compile_time, do: Application.compile_env(:letflow, :g10_runtime_key)
end
