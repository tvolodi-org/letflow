defmodule Letflow.Documents.FormTemplate.Package do
  @moduledoc """
  Bounded ZIP input and deterministic output. No extraction to disk, no second ZIP
  parser. The directory selects slices of the upload; safeInflate counts actual
  bytes, independently of declared sizes. Only verified parts reach the writer.

  Every binary XML child is wrapped in `{:characters, text}` before Saxy.encode!;
  plain binaries are raw XML in Saxy, and must never reach that encoder unwrapped.
  """
  import Bitwise
  alias Letflow.Documents.FormTemplate, as: F

  def size(bytes) when is_binary(bytes) do
    if byte_size(bytes) <= F.limits().compressed, do: :ok, else: F.error(:too_large)
  end

  def size(_), do: F.error(:not_docx)

  def read(bytes) do
    with :ok <- size(bytes), {:ok, directory} <- :zip.list_dir(bytes) do
      entries =
        for {:zip_file, name, info, _, offset, csize} <- directory,
            do: %{name: to_string(name), size: elem(info, 1), offset: offset, csize: csize}

      names = Enum.map(entries, &String.downcase(&1.name))

      cond do
        length(entries) > F.limits().entries ->
          F.error(:zip_too_many_entries)

        length(Enum.uniq(names)) != length(names) or
            Enum.any?(entries, &(not safe_name?(&1.name))) ->
          F.error(:zip_bad_entry)

        Enum.sum(Enum.map(entries, & &1.size)) > F.limits().inflated ->
          F.error(:zip_inflated_too_large)

        true ->
          inflate_all(bytes, entries)
      end
    else
      {:error, [_ | _]} = error -> error
      _ -> F.error(:not_docx)
    end
  rescue
    _ -> F.error(:zip_bad_entry)
  catch
    _, _ -> F.error(:zip_bad_entry)
  end

  defp safe_name?(name),
    do:
      String.valid?(name) and not String.starts_with?(name, "/") and
        not String.contains?(name, ["\\", <<0>>]) and
        not Enum.any?(String.split(name, "/"), &(&1 in ["..", "."]))

  defp inflate_all(bytes, entries) do
    Enum.reduce_while(entries, {:ok, 0, []}, fn entry, {:ok, total, parts} ->
      case inflate_entry(bytes, entry, F.limits().inflated - total) do
        {:ok, data} -> {:cont, {:ok, total + byte_size(data), [{entry.name, data} | parts]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  defp inflate_entry(bytes, %{offset: offset, csize: csize} = entry, budget) do
    case bytes do
      <<_::binary-size(^offset), 0x04034B50::32-little, _::16, flags::16-little,
        method::16-little, _::binary-size(16), nlen::16-little, elen::16-little, rest::binary>>
      when band(flags, 1) == 0 and method in [0, 8] and byte_size(rest) >= nlen + elen + csize ->
        <<name::binary-size(^nlen), _::binary-size(^elen), data::binary-size(^csize), _::binary>> =
          rest

        if name != entry.name do
          F.error(:zip_bad_entry)
        else
          ratio = F.limits().ratio * max(csize, 1)
          if method == 0, do: bounded(data, budget, ratio), else: inflate(data, budget, ratio)
        end

      _ ->
        F.error(:zip_bad_entry)
    end
  end

  defp bounded(data, budget, ratio) do
    cond do
      byte_size(data) > budget -> F.error(:zip_inflated_too_large)
      byte_size(data) > ratio -> F.error(:zip_ratio)
      true -> {:ok, data}
    end
  end

  defp inflate(data, budget, ratio) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      inflate_loop(z, :zlib.safeInflate(z, data), 0, [], budget, ratio)
    after
      :zlib.close(z)
    end
  end

  defp inflate_loop(z, {state, out}, size, acc, budget, ratio) do
    size = size + IO.iodata_length(out)

    cond do
      size > budget -> F.error(:zip_inflated_too_large)
      size > ratio -> F.error(:zip_ratio)
      state == :finished -> {:ok, IO.iodata_to_binary([acc, out])}
      true -> inflate_loop(z, :zlib.safeInflate(z, []), size, [acc, out], budget, ratio)
    end
  end

  def encodable({name, attrs, children}), do: {name, attrs, Enum.map(children, &encodable/1)}
  def encodable(text) when is_binary(text), do: {:characters, text}

  def write(parts) do
    entries =
      parts
      |> Enum.sort_by(fn {n, _} ->
        {if(n == "[Content_Types].xml", do: 0, else: if(n == "_rels/.rels", do: 1, else: 2)), n}
      end)
      |> Enum.map(fn {name, value} ->
        bytes =
          if is_binary(value),
            do: value,
            else:
              value
              |> encodable()
              |> Saxy.encode!(version: "1.0", encoding: "UTF-8", standalone: true)

        time = {{1980, 1, 1}, {0, 0, 0}}

        info =
          {:file_info, byte_size(bytes), :regular, :read_write, time, time, time, 0o644, 1, 0, 0,
           0, 0, 0}

        {String.to_charlist(name), bytes, info}
      end)

    case :zip.create(~c"template.docx", entries, [:memory]) do
      {:ok, {_, bytes}} -> {:ok, bytes}
      _ -> F.error(:xml_unreadable)
    end
  rescue
    _ -> F.error(:xml_unreadable)
  catch
    _, _ -> F.error(:xml_unreadable)
  end
end
