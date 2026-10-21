defmodule Letflow.Documents.Preconditions do
  @moduledoc """
  The PostgreSQL version floor for the versioned-documents store (REQ-500, GH #2588,
  decision 0056).

  The document numbering index is `NULLS NOT DISTINCT`, which PostgreSQL provides from
  15 on. The application therefore refuses to start below `server_version_num` 150000.
  The check is a pure function over the number, so tests can inject any version. The
  live read is `Letflow.Documents.BootCheck`.
  """

  @min_server_version_num 150_000

  @doc "The lowest `server_version_num` the document store runs on."
  @spec min_server_version_num() :: pos_integer()
  def min_server_version_num, do: @min_server_version_num

  @doc """
  `:ok` when `version_num` (PostgreSQL's `server_version_num`, e.g. `160004`) is at least
  the floor, otherwise `{:error, {:postgres_too_old, version_num}}`.
  """
  @spec check_server_version_num(integer()) :: :ok | {:error, {:postgres_too_old, integer()}}
  def check_server_version_num(version_num) when is_integer(version_num) do
    if version_num >= @min_server_version_num,
      do: :ok,
      else: {:error, {:postgres_too_old, version_num}}
  end
end
