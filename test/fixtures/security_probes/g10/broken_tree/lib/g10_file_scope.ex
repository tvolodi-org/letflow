import System

defmodule Letflow.Fixtures.G10FileScopeEnv do
  @moduledoc """
  The read of a module that inherits the import of the file it is in: an import of a file
  reaches the modules of that file, the way the language scopes it.
  """

  def env, do: get_env("G10_FILE_SCOPE_SETTING")
end

defmodule Letflow.Fixtures.G10FileScopeNarrowed do
  @moduledoc """
  The read of a module that narrows the import of the file: the import of the module replaces
  the import of the file for that module, the way the language narrows it.
  """

  import System, only: [get_env: 1]

  def env, do: get_env("G10_FILE_SCOPE_NARROWED_SETTING")
end
