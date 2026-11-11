defmodule Letflow.LetflowCase do
  @moduledoc """
  Where tests find the "companion" files (`docs/`, `handoffs/`, `.claude/`, `CLAUDE.md`,
  `test/fixtures/uat`): T-1599 stage 2 (source-only public repo), first slice.

  `LETFLOW_COMPANION_DIR` unset or blank: the companion root is the repository root, so tests
  read the in-tree files exactly as before. Set: its absolute expansion. There is no fallback
  when it is set; a file missing under a set directory is a failure, because a silent fallback
  to the in-tree copy would hide an unreadable companion.

  A test module that reads companion files carries `@moduletag :companion` and builds its
  paths with `companion_path/1`, keeping the literal relative path in the call so the CI
  docs-test selector still finds it. Nothing is excluded by the tag yet.

  `check/1` is the canary: it fails when a directory is missing, cannot be listed, or its
  marker file cannot be read or is empty.
  """

  @env "LETFLOW_COMPANION_DIR"
  @marker "docs/requirements.yaml"
  @repo_root Path.expand("../..", __DIR__)

  @doc "Companion root for a raw env value (pure)."
  @spec resolve(String.t() | nil) :: String.t()
  def resolve(nil), do: @repo_root

  def resolve(value) when is_binary(value) do
    case String.trim(value) do
      "" -> @repo_root
      v -> Path.expand(v)
    end
  end

  @doc "Companion root: the in-tree repository root unless `LETFLOW_COMPANION_DIR` is set."
  @spec companion() :: String.t()
  def companion, do: resolve(System.get_env(@env))

  @doc "True when `LETFLOW_COMPANION_DIR` is set to a non-blank value."
  @spec companion_set?() :: boolean()
  def companion_set?, do: not blank?()

  @doc "Path of a companion file, relative to the companion root."
  @spec companion_path(String.t()) :: String.t()
  def companion_path(rel), do: Path.join(companion(), rel)

  @doc "Canary: `:ok` when `dir` is a readable companion root, else `{:error, message}`."
  @spec check(String.t()) :: :ok | {:error, String.t()}
  def check(dir) do
    marker = Path.join(dir, @marker)

    with :ok <- if(File.dir?(dir), do: :ok, else: {:error, "#{dir} is not a directory"}),
         :ok <- listable(dir),
         :ok <- listable(Path.join(dir, "docs")),
         {:ok, bytes} <- read_marker(marker) do
      if bytes == "", do: {:error, "#{marker} is empty"}, else: :ok
    end
  end

  defp blank?, do: String.trim(System.get_env(@env) || "") == ""

  defp listable(path) do
    case File.ls(path) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "#{path} is not readable: #{:file.format_error(reason)}"}
    end
  end

  defp read_marker(marker) do
    case File.read(marker) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, "#{marker} is not readable: #{:file.format_error(reason)}"}
    end
  end
end
