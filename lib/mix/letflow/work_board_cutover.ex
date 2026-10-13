defmodule Mix.Letflow.WorkBoardCutover do
  @moduledoc """
  The single switch for the work-board cutover (ISS-1073 / GH #2430,
  `docs/agents/protocols/WORK_BOARD.md`).

  The three gate checks (`check_requirements_registration`,
  `check_deferral_staleness`, `check_issue_refs`) accept either the legacy
  queue ids (`impl_order`, `queue_ref`) or a GitHub issue number (`gh:`) while
  the switch is `false`, and accept only the GitHub number for live work once
  it is `true`. The switch lives in one data file so that cutover is a
  one-line change, reviewed like any other docs change:

      docs/status/work_board_cutover.yaml
        cutover: false          # flip to true on cutover day
        last_legacy_iss: 1119   # highest ISS-NNNN that predates the board

  Cutover is not a calendar date and is not tied to the repository transfer;
  it is the day a PR flips this value, after one CI-shaped dry run passed.

  The file is read line by line (this project has no YAML dependency). A
  file that does not exist means "before cutover" (the state of every
  checkout that predates this switch, and of the hermetic fixture
  directories some check tests `cd` into); the live file's presence is
  pinned by a test. An unreadable file or a missing/invalid `cutover:` value
  is an error, never a silent default. So are a key that appears twice and
  `cutover: true` without `last_legacy_iss:` (the R7 ceiling would silently
  never fire).
  """

  @path "docs/status/work_board_cutover.yaml"

  @type config :: %{cutover: boolean(), last_legacy_iss: non_neg_integer() | nil}

  @doc "Repo-relative path of the switch file."
  @spec path() :: String.t()
  def path, do: @path

  @doc """
  Parses the switch file's content. Pure.

  Only column-0 `cutover:` and `last_legacy_iss:` lines are read; a trailing
  `# comment` is ignored.
  """
  @spec parse(String.t()) :: {:ok, config()} | {:error, String.t()}
  def parse(content) when is_binary(content) do
    pairs =
      content
      |> String.split(~r/\r?\n/)
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^([a-z_]+):[ \t]*([^#]*?)[ \t]*(?:#.*)?$/, line) do
          [_, key, val] -> [{key, val}]
          _ -> []
        end
      end)

    fields = Map.new(pairs)

    with :ok <- reject_duplicates(pairs),
         {:ok, cutover} <- parse_cutover(Map.get(fields, "cutover")),
         {:ok, last} <- parse_last_legacy(Map.get(fields, "last_legacy_iss")),
         :ok <- require_ceiling(cutover, last) do
      {:ok, %{cutover: cutover, last_legacy_iss: last}}
    end
  end

  defp reject_duplicates(pairs) do
    dup =
      pairs
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&(&1 in ["cutover", "last_legacy_iss"]))
      |> Enum.frequencies()
      |> Enum.find(fn {_key, n} -> n > 1 end)

    case dup do
      nil -> :ok
      {key, _} -> {:error, "`#{key}:` appears more than once"}
    end
  end

  defp require_ceiling(true, nil),
    do: {:error, "`cutover: true` requires `last_legacy_iss:` (the R7 ceiling)"}

  defp require_ceiling(_cutover, _last), do: :ok

  defp parse_cutover("true"), do: {:ok, true}
  defp parse_cutover("false"), do: {:ok, false}
  defp parse_cutover(nil), do: {:error, "no `cutover:` field"}
  defp parse_cutover(other), do: {:error, "`cutover: #{other}` is neither true nor false"}

  defp parse_last_legacy(nil), do: {:ok, nil}

  defp parse_last_legacy(val) do
    case Integer.parse(val) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, "`last_legacy_iss: #{val}` is not a non-negative integer"}
    end
  end

  @doc """
  Reads the switch file. A missing file is `cutover: false`; any other read
  error or a malformed file raises with the file name and reason.
  """
  @spec load!() :: config()
  def load! do
    case File.read(@path) do
      {:error, :enoent} ->
        %{cutover: false, last_legacy_iss: nil}

      {:error, reason} ->
        raise "#{@path}: #{inspect(reason)}"

      {:ok, content} ->
        case parse(content) do
          {:ok, config} -> config
          {:error, reason} -> raise "#{@path}: #{reason}"
        end
    end
  end

  @doc "True once the work-board cutover has happened."
  @spec cutover?() :: boolean()
  def cutover?, do: load!().cutover

  @doc "Highest `ISS-NNNN` number that predates the board (post-cutover rule)."
  @spec last_legacy_iss() :: non_neg_integer() | nil
  def last_legacy_iss, do: load!().last_legacy_iss
end
