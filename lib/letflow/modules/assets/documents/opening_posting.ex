defmodule Letflow.Modules.Assets.Documents.OpeningPosting do
  @moduledoc """
  GH #4037 / G5 part 2 (decision 0083): the pure helpers that turn an issued asset opening document
  into the posting command of cause `opening` and into the legs that command must produce. No
  database. Used by `Letflow.Modules.Assets.Documents.Posting`. Mirrors
  `Letflow.Modules.Stock.Documents.OpeningPosting` (module `assets` cannot call `stock`, boundary
  Rule 4).

  `command/3` is built ONLY from the frozen content of the issued version. It carries NO `device_id`,
  `client_seq` or `client_event_time`, so the entry's event time is its posting time (decision 0083
  D1), and NEVER a price, value or date: money and dates stay on the card. The location, the
  responsible employee and the actual user are the line's own; the org unit is the header's.
  """

  alias Letflow.Modules.Assets.Documents.Posting

  @spec command(map(), map(), %{optional(integer()) => String.t()}) ::
          {:ok, map()} | {:error, :line_record_missing | :quantity_not_whole}
  def command(view, %{content: content} = issued, line_ids) do
    header = Map.get(content, "header", %{})

    content
    |> Map.get("lines", [])
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      with {:ok, line_id} <- Map.fetch(line_ids, Map.get(line, "line_no")),
           {:ok, quantity} <- Posting.whole_text(Map.get(line, "quantity")) do
        {:cont, {:ok, [leg_line(line, line_id, quantity, header) | acc]}}
      else
        :error -> {:halt, {:error, :line_record_missing}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} ->
        {:ok,
         %{
           "cause" => "opening",
           "document_type" => "assets_opening",
           "document_id" => view.id,
           "client_op_id" => issued.version_id,
           "lines" => Enum.reverse(acc)
         }}

      error ->
        error
    end
  end

  defp leg_line(line, line_id, quantity, header) do
    %{
      "line_id" => line_id,
      "asset" => Map.get(line, "asset_id"),
      "quantity" => quantity,
      "from" => nil,
      "to" => %{
        "org_unit" => Map.get(header, "org_unit_id"),
        "location" => Map.get(line, "location_id"),
        "material_responsible" => Map.get(line, "material_responsible_id"),
        "actual_user" => Map.get(line, "actual_user_id")
      }
    }
  end

  @doc """
  The expected legs of the frozen `content` as tuples built by `leg_key` (the caller's function, so
  the other kinds and the opening share one normal form): `leg_key.(asset, org_unit, location,
  responsible, actual_user, unit, quantity)`.
  """
  @spec expected_legs(map(), (term(), term(), term(), term(), term(), term(), term() -> tuple())) ::
          [tuple()]
  def expected_legs(content, leg_key) do
    header = Map.get(content, "header", %{})

    for line <- Map.get(content, "lines", []) do
      leg_key.(
        Map.get(line, "asset_id"),
        Map.get(header, "org_unit_id"),
        Map.get(line, "location_id"),
        Map.get(line, "material_responsible_id"),
        Map.get(line, "actual_user_id"),
        "pcs",
        Map.get(line, "quantity")
      )
    end
  end
end
