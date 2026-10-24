defmodule Letflow.Entities.Record.SizeCap do
  @moduledoc """
  The entity-side byte cap on a record write (GH #2689, REQ-514). One pure check, called from
  `Letflow.Entities.Records` for every writer (create, update, upsert, `command_multi/3`), so the
  limit no longer depends on the origin of the write.

  It replaces the service-origin caps that lived in `StepWrites` (design GH #2587 PR C, D-C.7:
  "Run-time size caps on the service origin only ... The HUMAN path is NOT widened in PR C; the
  follow-up is an entity-side per-record cap that replaces both origin-specific caps"). The numbers
  are the same; the location moved, and the HUMAN path, the generic HTTP routes, the import route
  and the module callers are now capped too (accepted widening).

  ## Measure

  The unit is `byte_size(Jason.encode!(term))` with default options. A string of N ASCII characters
  is N + 2 bytes (quotes), so 65_534 is the largest accepted string under the standard value cap.
  The value cap applies to each top-level field value, the record cap to the whole `field_values`
  map (keys, braces and commas included; for an update that is the merged full-replacement map).
  A map over both caps is reported as `:record`. There is no per-type limit.

  ## Profiles

  `:standard` (64 KiB per value, 256 KiB per record) is used by every tenant-controlled path and by
  `command_multi/3`. `:module` (4 MiB / 5 MiB) is a backstop for a compiled-in module writing its own
  managed type with an `Owner` authority (`modules/exam` freezes an exam snapshot of up to 2 MiB into
  one `:json` value); the module's own limit stays the first line. The profile is chosen by
  `Records` from the authority, never from request data.

  ## Stored records already over the cap

  A write must not make an oversize record worse, and never has to repair it. With `stored`
  given (an update): a value byte-identical to the stored one is not measured, and the record cap is
  not applied when the stored map is already over it. A changed or new value must fit the value cap.
  `stored` is `nil` for a create, so the plain caps apply.

  The error carries no field name and no size (INV-2).
  """

  @standard %{value_max_bytes: 65_536, record_max_bytes: 262_144}
  @module %{value_max_bytes: 4_194_304, record_max_bytes: 5_242_880}

  @type profile :: :standard | :module
  @type error :: {:record_size_exceeded, :value | :record} | :record_not_encodable

  @doc "The byte limits of a profile."
  @spec caps(profile()) :: %{value_max_bytes: pos_integer(), record_max_bytes: pos_integer()}
  def caps(:standard), do: @standard
  def caps(:module), do: @module

  @doc "Checks the (normalised) `field_values` map about to be written."
  @spec check(map(), profile(), map() | nil) :: :ok | {:error, error()}
  def check(new, profile, stored \\ nil) when is_map(new) do
    %{value_max_bytes: value_max, record_max_bytes: record_max} = caps(profile)

    with {:ok, record_json} <- Jason.encode(new),
         :ok <- check_record(byte_size(record_json), record_max, stored),
         {:ok, encoded} <- encode_values(new) do
      check_values(encoded, value_max, stored)
    else
      {:error, {:record_size_exceeded, _} = reason} -> {:error, reason}
      {:error, _not_encodable} -> {:error, :record_not_encodable}
    end
  end

  defp check_record(size, max, _stored) when size <= max, do: :ok

  defp check_record(_size, max, stored) do
    if stored_over?(stored, max), do: :ok, else: {:error, {:record_size_exceeded, :record}}
  end

  defp stored_over?(stored, max) when is_map(stored) do
    case Jason.encode(stored) do
      {:ok, json} -> byte_size(json) > max
      {:error, _} -> false
    end
  end

  defp stored_over?(_stored, _max), do: false

  defp encode_values(values) do
    Enum.reduce_while(values, {:ok, []}, fn {name, value}, {:ok, acc} ->
      case Jason.encode(value) do
        {:ok, json} -> {:cont, {:ok, [{name, json} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_values(encoded, max, stored) do
    if Enum.any?(encoded, fn {name, json} ->
         byte_size(json) > max and not unchanged?(stored, name, json)
       end),
       do: {:error, {:record_size_exceeded, :value}},
       else: :ok
  end

  defp unchanged?(stored, name, json) when is_map(stored) do
    with {:ok, old} <- Map.fetch(stored, name),
         {:ok, old_json} <- Jason.encode(old) do
      old_json == json
    else
      _ -> false
    end
  end

  defp unchanged?(_stored, _name, _json), do: false
end
