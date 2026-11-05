defmodule Letflow.Documents.OverrideRender do
  @moduledoc """
  Renders an issued version from the print override it was pinned to (REQ-624, decision 0068 D8
  S3, decision 0075 R4/R6). Called by `Letflow.Documents.attach_artefact/2` only when the version
  has a `print_override_id`; a version without one goes through `Letflow.Documents.Renderers`.

  The pinned row is read by id in the tenant schema whatever its status (a later retirement or a
  newer activation never changes an issued version) and its `layout_hash` must equal the one
  stored on the version. The projection is the version content restricted to the entity types and
  field names the document type declares: `%{entity_type => %{field => value}}` for a map entry and
  `%{entity_type => [row]}` for a list entry, never an undeclared key and never a free field. The
  tenant's restricted pairs go to `PrintLayout.render/4` as well.

  Returns `{:ok, bytes, template_version}` or `{:error, code}` where `code` is an atom of a closed
  set; nothing from a layout, a violation or a content value is returned, raised or logged.
  """

  alias Letflow.Documents.DocumentType
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Documents.PrintLayout
  alias Letflow.Documents.PrintOverride
  alias Letflow.Documents.PrintOverrides
  alias Letflow.Repo

  @free "_free"

  @spec render(String.t(), %DocumentVersion{}, %DocumentType{}) ::
          {:ok, binary(), String.t()} | {:error, atom()}
  def render(prefix, %DocumentVersion{} = version, %DocumentType{} = type) do
    with %PrintOverride{} = row <-
           Repo.get(PrintOverride, version.print_override_id, prefix: prefix),
         true <- row.layout_hash == version.print_override_layout_hash,
         true <- is_binary(version.template_version) and version.template_version != "" do
      declared = if is_map(type.declared_fields), do: type.declared_fields, else: %{}
      restricted = PrintOverrides.restricted_pairs(prefix, declared)
      projection = projection(version.content, declared)

      case PrintLayout.render(row.layout, projection, declared, restricted: restricted) do
        {:ok, bytes} -> {:ok, bytes, version.template_version}
        {:error, _violations} -> {:error, :override_render}
      end
    else
      nil -> {:error, :no_override}
      false -> {:error, :override_hash_mismatch}
      _ -> {:error, :no_override}
    end
  rescue
    _error -> {:error, :override_render}
  catch
    _kind, _reason -> {:error, :override_render}
  end

  @doc false
  # Only declared entity types and declared field names survive; a missing entry stays missing.
  def projection(content, declared) when is_map(content) do
    declared
    |> Map.delete(@free)
    |> Enum.flat_map(fn {entity_type, names} ->
      names = Enum.filter(List.wrap(names), &is_binary/1)

      case Map.get(content, entity_type) do
        %{} = entry when not is_struct(entry) -> [{entity_type, Map.take(entry, names)}]
        rows when is_list(rows) -> [{entity_type, Enum.map(rows, &take_row(&1, names))}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  def projection(_content, _declared), do: %{}

  defp take_row(%{} = row, names) when not is_struct(row), do: Map.take(row, names)
  defp take_row(_row, _names), do: %{}
end
