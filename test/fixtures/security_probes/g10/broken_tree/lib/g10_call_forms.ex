defmodule Letflow.Fixtures.G10CallForms do
  @moduledoc """
  The call forms a setting can be read in, each of them a variable nobody registered.

  A name that hides in one of these forms is a name the registry does not have, so the
  derivation has to see a read whatever form the call takes:

    * the imported call: `import System` and then `get_env("X")`;
    * the imported application call: `import Application, only: [get_env: 2]` and then
      `get_env(:app, :key)`;
    * the `Elixir.`-prefixed call: `Elixir.System.get_env("X")`;
    * the aliased call: `alias System, as: Sys` and then `Sys.get_env("X")`;
    * the aliased application call: `alias Application, as: App` and then
      `App.get_env(:app, :key)`.

  The file is a fixture under `test/fixtures/`, is never compiled by the suite and exists only
  so the probe can prove that it is not vacuous.
  """

  import System
  alias System, as: Sys
  alias Application, as: App

  def imported_env, do: get_env("G10_IMPORTED_SETTING")

  def imported_fetched_env, do: fetch_env("G10_IMPORTED_FETCH_SETTING")

  def elixir_prefixed_env, do: Elixir.System.get_env("G10_ELIXIR_PREFIXED_SETTING")

  def aliased_env, do: Sys.get_env("G10_ALIASED_SETTING")

  def aliased_app_env, do: App.get_env(:letflow, :g10_aliased_app_key)
end

defmodule Letflow.Fixtures.G10ImportedAppEnv do
  @moduledoc """
  The application environment read through an import of `Application`.
  """

  import Application, only: [get_env: 2]

  def imported_app_env, do: get_env(:letflow, :g10_imported_app_key)
end

defmodule Letflow.Fixtures.G10DefinesGetEnvItself do
  @moduledoc """
  A module that defines `get_env/1` itself.
  """

  def get_env(_name), do: nil

  # A call of the module's own definition: not a read of the environment.
  def own, do: get_env("G10_OWN_DEFINITION_SETTING")
end

defmodule Letflow.Fixtures.G10ImportBesideALocalDefinition do
  @moduledoc """
  The read of a module that imports `System` while another module of the same file defines
  `get_env/1`.

  The definition belongs to the module that holds it: it does not reach the module that
  imports `System`, so the call there is a read of the operating system environment and the
  derivation has to report it.
  """

  import System

  def env, do: get_env("G10_IMPORT_BESIDE_LOCAL_SETTING")
end

defmodule Letflow.Fixtures.G10UnresolvedForms do
  @moduledoc """
  The forms the derivation cannot resolve; each must be reported, never skipped.
  """

  @reader System

  def applied, do: apply(System, :get_env, ["G10_APPLIED_SETTING"])

  def applied_app, do: Kernel.apply(Application, :get_env, [:letflow, :g10_applied_key])

  def captured, do: Enum.map(["G10_CAPTURED_SETTING"], &System.get_env/1)

  def attribute_module, do: @reader.get_env("G10_ATTRIBUTE_MODULE_SETTING")

  def variable_module(reader), do: reader.get_env("G10_VARIABLE_SETTING")

  def applied_computed(fun), do: apply(System, fun, ["G10_COMPUTED_FUN_SETTING"])

  def atom_prefixed, do: :"Elixir.System".get_env("G10_ATOM_PREFIX_SETTING")

  def erlang_call, do: :os.getenv(~c"G10_ERLANG_SETTING")
end
