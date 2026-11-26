defmodule Letflow.TestSupport.CursorBuilderInventory do
  @moduledoc """
  The inventory of the product's keyset cursor builders -- the input of the
  **G-07 security probe** (`test/letflow/security/g07_cursor_codec_probe_test.exs`).

  ## Why an inventory

  Every keyset list endpoint in `lib/` mints a cursor with the shared
  `Letflow.Api.Pagination` codec: a `<prefix>` literal, the cursor's own mint
  time, then one `:`-separated slot per seek value. The codec is only as safe
  as the *convention* each call site follows, and the convention is invisible
  to the compiler: a slot that carries a caller-supplied id may contain the
  `:` separator, so a `:`-bearing id shifts or truncates every later slot
  unless the id's slot is the last one.

  That class of defect is real and was found by hand (T-2571: a colon-bearing
  `service_id` shifted the cursor's slots; the same review found a legacy
  cursor decoded into the wrong values, allowing repeated/looping pages).
  The probe therefore needs the *list* of cursor builders, not one of them.

  This module is that list, and it is **anchored in the tree**: every entry
  names the file the decoder lives in, the prefix literal that file defines and
  the slot layout the decoder reads. `scan_tree/0` re-derives the prefixes and
  the seek shapes from `lib/` on every run, so an entry that drifts (a renamed
  prefix, a reshaped slot list) fails the probe instead of silently testing a
  layout the product no longer uses.

  ## The slot language

  A *layout* lists the slots of a cursor payload, in payload order, the first
  one being the slot `Letflow.Api.Pagination.decode_cursor/4` reads for the
  expiry check:

    * `:mint` -- the cursor's own mint time (the slot is skipped by the seek
      decoder; `decode_seek_parts/3`'s `:skip`);
    * `:mint_dt` -- a timestamp that is BOTH the mint time and the seek key
      (the pre-issue-time cursor generations, whose expiry was measured from
      the row's own timestamp);
    * `:dt` -- a unix-microsecond timestamp;
    * `:int` -- a decimal integer;
    * `:uuid` -- an `Ecto.UUID` (never contains a `:`);
    * `:string` -- a free-form string (MAY contain a `:` -- so it must be the
      last slot; see `free_string_violations/0`);
    * `:rank_id` -- the machine-built `"<rank>|<uuid>"` composite of the
      definitions search cursor (constrained, so it never contains a `:`).

  `shape_for_layout/1` maps a layout onto the shape the product passes to
  `Letflow.Api.Pagination.decode_seek_parts/3`.

  ## Scope

  The inventory covers the `Letflow.Api.Pagination` family (prefix + `:`-separated
  slots) only. The cursors with their own wire format -- the ledger's
  `|`-separated key, the exam grading's `v1|...`, the script-rules' newline
  separated key -- are listed in `docs/security-probes/G-07.md` as a known
  scope boundary, not as covered cases.

  Test-only: compiled under `elixirc_paths(:test)`, never referenced from `lib/`.
  """

  alias Letflow.Api.Pagination

  @typedoc "One slot of a cursor payload, in the vocabulary above."
  @type slot :: :mint | :mint_dt | :dt | :int | :uuid | :string | :rank_id

  @typedoc "The slots of a cursor payload, in payload order."
  @type layout :: [slot()]

  @typedoc """
  One cursor builder of the inventory.

    * `:name` -- a stable id for the builder;
    * `:prefix` -- the cursor prefix literal the decoder checks;
    * `:layout` -- the slot layout, in the vocabulary above;
    * `:file` -- the file the decoder lives in;
    * `:line` -- the line the decoder's slot list is on (informational: the
      anchor check is on the file and the shape, not on the line, so an
      unrelated edit above it does not break the probe);
    * `:legacy` -- the previous generation of the same cursor, when the
      product still accepts it (`nil` when it does not).
  """
  @type entry :: %{
          name: String.t(),
          prefix: String.t(),
          layout: layout(),
          file: String.t(),
          line: pos_integer(),
          legacy:
            nil
            | %{
                prefix: String.t(),
                layout: layout(),
                file: String.t(),
                line: pos_integer()
              }
        }

  # Every entry was read out of the tree (see `scan_tree/0`); the anchor check
  # in the probe re-reads the tree and fails when one of them drifts.
  @entries [
    %{
      name: "dlq_list",
      prefix: "D:",
      layout: [:mint, :uuid, :dt],
      file: "lib/letflow/dlq.ex",
      line: 423,
      legacy: %{prefix: "D:", layout: [:mint_dt, :uuid], file: "lib/letflow/dlq.ex", line: 434}
    },
    %{
      name: "instances_list",
      prefix: "IL:",
      layout: [:mint, :uuid, :dt],
      file: "lib/letflow/instances.ex",
      line: 516,
      legacy: %{
        prefix: "IL:",
        layout: [:mint_dt, :uuid],
        file: "lib/letflow/instances.ex",
        line: 527
      }
    },
    %{
      name: "instances_timeline",
      prefix: "IT:",
      layout: [:mint, :int],
      file: "lib/letflow/instances.ex",
      line: 600,
      legacy: nil
    },
    %{
      name: "instances_history",
      prefix: "IH:",
      layout: [:mint, :int],
      file: "lib/letflow/instances.ex",
      line: 600,
      legacy: nil
    },
    %{
      name: "tasks_list",
      prefix: "T:",
      layout: [:mint, :uuid, :dt],
      file: "lib/letflow/tasks.ex",
      line: 1143,
      legacy: %{prefix: "T:", layout: [:mint_dt, :uuid], file: "lib/letflow/tasks.ex", line: 1154}
    },
    %{
      name: "attachments_list",
      prefix: "IA:",
      layout: [:mint, :uuid, :dt],
      file: "lib/letflow/repository/attachments.ex",
      line: 806,
      legacy: %{
        prefix: "IA:",
        layout: [:mint_dt, :uuid],
        file: "lib/letflow/repository/attachments.ex",
        line: 817
      }
    },
    %{
      name: "entity_attachments_list",
      prefix: "ERA:",
      layout: [:mint, :uuid, :dt],
      file: "lib/letflow/repository/entity_attachments.ex",
      line: 490,
      legacy: %{
        prefix: "ERA:",
        layout: [:mint_dt, :uuid],
        file: "lib/letflow/repository/entity_attachments.ex",
        line: 501
      }
    },
    %{
      name: "identity_users",
      prefix: "U:",
      layout: [:mint, :dt, :uuid],
      file: "lib/letflow/identity.ex",
      line: 4108,
      legacy: nil
    },
    %{
      name: "identity_tenants",
      prefix: "T:",
      layout: [:mint, :dt, :uuid],
      file: "lib/letflow/identity.ex",
      line: 4108,
      legacy: nil
    },
    %{
      name: "identity_group_members",
      prefix: "G:",
      layout: [:mint, :dt, :uuid],
      file: "lib/letflow/identity.ex",
      line: 4108,
      legacy: nil
    },
    %{
      name: "scoped_grants",
      prefix: "RG:",
      layout: [:mint, :dt, :uuid],
      file: "lib/letflow/identity/scoped_grants.ex",
      line: 384,
      legacy: nil
    },
    %{
      name: "definitions_list",
      prefix: "DL:",
      layout: [:mint, :uuid, :dt],
      file: "lib/letflow/definitions.ex",
      line: 2164,
      legacy: nil
    },
    %{
      name: "definitions_search",
      prefix: "DS:",
      layout: [:mint, :rank_id, :dt],
      file: "lib/letflow/definitions.ex",
      line: 2337,
      legacy: nil
    },
    %{
      name: "entities_definitions_list",
      prefix: "ED:",
      layout: [:mint, :uuid, :dt],
      file: "lib/letflow/entities/definitions.ex",
      line: 473,
      legacy: nil
    },
    %{
      name: "repository_list_versions",
      prefix: "RV:",
      layout: [:mint, :uuid, :int],
      file: "lib/letflow/repository.ex",
      line: 365,
      legacy: nil
    },
    %{
      name: "activation_list_history",
      prefix: "AH:",
      layout: [:mint, :uuid, :dt],
      file: "lib/letflow/repository/activation.ex",
      line: 644,
      legacy: nil
    },
    %{
      name: "promotion_reviews_list",
      prefix: "PR:",
      layout: [:mint, :uuid, :dt],
      file: "lib/letflow/definitions/promotion_review_store.ex",
      line: 402,
      legacy: nil
    },
    %{
      name: "service_catalog_list",
      prefix: "SC2:",
      layout: [:mint, :dt, :string],
      file: "lib/letflow/service_catalog.ex",
      line: 755,
      legacy: %{
        prefix: "SC:",
        layout: [:mint_dt, :string],
        file: "lib/letflow/service_catalog.ex",
        line: 764
      }
    },
    %{
      name: "service_catalog_list_all",
      prefix: "SCA2:",
      layout: [:mint, :dt, :string],
      file: "lib/letflow/service_catalog.ex",
      line: 755,
      legacy: %{
        prefix: "SCA:",
        layout: [:mint_dt, :string],
        file: "lib/letflow/service_catalog.ex",
        line: 764
      }
    },
    %{
      name: "audit_list",
      prefix: "A:",
      layout: [:mint, :dt, :uuid],
      file: "lib/letflow/routers/audit.ex",
      line: 257,
      legacy: nil
    },
    %{
      name: "platform_events",
      prefix: "PE:",
      layout: [:mint, :int, :uuid],
      file: "lib/letflow/routers/promotions.ex",
      line: 1065,
      legacy: nil
    },
    %{
      name: "module_rollouts",
      prefix: "RO:",
      layout: [:mint, :dt, :uuid],
      file: "lib/letflow/routers/platform_module_rollouts.ex",
      line: 121,
      legacy: nil
    },
    %{
      name: "record_history",
      prefix: "RH:",
      layout: [:mint, :int],
      file: "lib/letflow/routers/entities/record_history.ex",
      line: 93,
      legacy: nil
    },
    %{
      name: "entities_query_cursor",
      prefix: "EQ:",
      layout: [:mint, :string],
      file: "lib/letflow/entities/query/cursor.ex",
      line: 236,
      legacy: nil
    }
  ]

  # Cursor prefixes of `lib/` that this probe deliberately does NOT cover, with
  # the reason. A prefix that is neither in the inventory nor here fails the
  # completeness check -- the exclusions are explicit, not silent.
  @scope_excluded [
    %{
      prefix: "script-rules:",
      reason:
        "own codec family: the key and the version are separated by a newline, not by the `:` slot separator"
    }
  ]

  @doc "Every cursor builder of the `Letflow.Api.Pagination` family."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "The inventory entry named `name` (`nil` when there is none)."
  @spec entry(String.t()) :: entry() | nil
  def entry(name), do: Enum.find(@entries, &(&1.name == name))

  @doc """
  The shape the product passes to `Letflow.Api.Pagination.decode_seek_parts/3`
  for a layout of this inventory.
  """
  @spec shape_for_layout(layout()) :: [atom()]
  def shape_for_layout(layout) when is_list(layout) do
    Enum.map(layout, fn
      :mint -> :skip
      :mint_dt -> :datetime_us
      :dt -> :datetime_us
      :int -> :int
      :uuid -> :uuid
      :string -> :string
      :rank_id -> :string
    end)
  end

  @doc """
  The slot layouts of the inventory that carry a FREE string (a value the
  product does not constrain, and which may therefore contain the `:` slot
  separator).

  A free string must be the LAST slot of the layout: `decode_seek_parts/3`
  splits the payload with `String.split(rest, ":", parts: slots)`, so only the
  last slot keeps the colons that follow it -- a free string in an earlier slot
  is truncated at its first colon and every later slot shifts (T-2571).
  """
  @spec free_string_layouts() :: [{String.t(), layout()}]
  def free_string_layouts do
    for entry <- @entries,
        :string <- free_string_positions(entry.layout),
        do: {entry.name, entry.layout}
  end

  @doc """
  The inventory entries whose layout carries a free string that is NOT the last
  slot -- the structural defect the probe must never see.
  """
  @spec free_string_violations() :: [{String.t(), layout()}]
  def free_string_violations do
    for entry <- @entries,
        index <- free_string_positions(entry.layout),
        index != length(entry.layout) - 1,
        do: {entry.name, entry.layout}
  end

  @doc """
  The raw cursor payload for `layout` and the given slot strings: the prefix,
  then the slots joined with the `:` separator.
  """
  @spec build_raw(String.t(), [String.t()]) :: String.t()
  def build_raw(prefix, slot_strings) when is_binary(prefix) and is_list(slot_strings) do
    prefix <> Enum.join(slot_strings, ":")
  end

  @doc """
  Decodes a raw cursor payload the way the product does: the prefix and the
  expiry check first (`Letflow.Api.Pagination.decode_cursor/4`), then the slot
  list (`decode_seek_parts/3`).

  Returns `{:ok, values}` with the decoded slot values (the `:skip` slot
  dropped), or the tagged error the codec produced.
  """
  @spec decode(String.t(), String.t(), [atom()]) :: {:ok, [term()]} | {:error, atom()}
  def decode(raw, prefix, shape) when is_binary(raw) and is_binary(prefix) do
    with {:ok, %Pagination.Cursor{inner: inner}} <-
           Pagination.decode_cursor(Pagination.encode_cursor(raw), prefix, byte_size(prefix)),
         {:ok, values} <- Pagination.decode_seek_parts(inner, prefix, shape) do
      {:ok, values}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The seeded BROKEN decoder of the non-vacuity case: the naive split that
  ignores the slot count, so a `:` inside a free string creates extra slots
  and the value is truncated at its first colon.

  It is the shape of the defect T-2571 found; the probe asserts that the real
  decoder preserves such an id and that this one does not -- a probe that
  cannot fail is not evidence.
  """
  @spec broken_decode(String.t(), String.t(), [atom()]) :: {:ok, [term()]} | {:error, atom()}
  def broken_decode(raw, prefix, shape) when is_binary(raw) and is_binary(prefix) do
    prefix_len = byte_size(prefix)

    if byte_size(raw) < prefix_len or not String.starts_with?(raw, prefix) do
      {:error, :wrong_endpoint}
    else
      rest = binary_part(raw, prefix_len, byte_size(raw) - prefix_len)

      case String.split(rest, ":") do
        parts when length(parts) >= length(shape) ->
          {:ok, Enum.take(parts, length(shape))}

        _ ->
          {:error, :invalid_cursor}
      end
    end
  end

  @doc """
  Re-derives the cursor prefixes and the seek shapes from `lib/`.

  Returns `%{prefixes: [String.t()], shapes: [%{shape: [atom()], file: String.t(), line: pos_integer()}]}`.
  """
  @spec scan_tree() :: %{
          prefixes: [String.t()],
          shapes: [%{shape: [atom()], file: String.t(), line: pos_integer()}]
        }
  def scan_tree do
    files = Path.wildcard("lib/**/*.ex")

    {prefixes, shapes} =
      Enum.reduce(files, {[], []}, fn file, {prefixes, shapes} ->
        content = File.read!(file)

        if String.contains?(content, "cursor_prefix") or
             String.contains?(content, "decode_seek_parts") do
          ast = Code.string_to_quoted!(content, token_metadata: true)
          {file_prefixes, file_shapes} = scan_source(ast, file)
          {prefixes ++ file_prefixes, shapes ++ file_shapes}
        else
          {prefixes, shapes}
        end
      end)

    %{prefixes: Enum.uniq(prefixes) |> Enum.sort(), shapes: shapes}
  end

  @doc """
  The seek shapes the tree's `decode_seek_parts/3` calls use, as a set.
  """
  @spec tree_shapes() :: [[atom()]]
  def tree_shapes do
    scan_tree().shapes |> Enum.map(& &1.shape) |> Enum.uniq()
  end

  @doc """
  The seek shape the file at `file` reads, for every `decode_seek_parts/3` call
  in it. `[]` when the file has none.
  """
  @spec shapes_in_file(String.t()) :: [[atom()]]
  def shapes_in_file(file) do
    content = File.read!(file)

    case Code.string_to_quoted(content, token_metadata: true) do
      {:ok, ast} ->
        {_prefixes, shapes} = scan_source(ast, file)
        Enum.map(shapes, & &1.shape)

      {:error, _reason} ->
        []
    end
  end

  @doc "The prefix literals the tree defines for its cursor codecs."
  @spec tree_prefixes() :: [String.t()]
  def tree_prefixes, do: scan_tree().prefixes

  @doc """
  The cursor prefixes of `lib/` this probe deliberately does not cover, with the
  reason. A prefix that is neither in the inventory nor here fails the
  completeness check.
  """
  @spec scope_excluded() :: [%{prefix: String.t(), reason: String.t()}]
  def scope_excluded, do: @scope_excluded

  # ── source scan ────────────────────────────────────────────────────────────

  defp scan_source(ast, file) do
    {_ast, {prefixes, shapes}} =
      Macro.prewalk(ast, {[], []}, fn
        {:@, _meta, [{name, _nmeta, [value]}]} = node, {prefixes, shapes} ->
          literal = if is_binary(value), do: value, else: nil

          if literal && String.ends_with?(to_string(name), "cursor_prefix") do
            {node, {[literal | prefixes], shapes}}
          else
            {node, {prefixes, shapes}}
          end

        {{:., _dot, [{:__aliases__, _aliases, [:Pagination]}, :decode_seek_parts]}, meta,
         [_inner, _prefix, shape]} = node,
        {prefixes, shapes} ->
          case literal_shape(shape) do
            nil ->
              {node, {prefixes, shapes}}

            shape_list ->
              {node, {prefixes, [%{shape: shape_list, file: file, line: meta[:line]} | shapes]}}
          end

        node, acc ->
          {node, acc}
      end)

    {prefixes, Enum.reverse(shapes)}
  end

  defp literal_shape(shape) when is_list(shape) do
    if shape != [] and Enum.all?(shape, &is_atom/1), do: shape, else: nil
  end

  defp literal_shape(_shape), do: nil

  # ── helpers ────────────────────────────────────────────────────────────────

  defp free_string_positions(layout) do
    layout
    |> Enum.with_index()
    |> Enum.filter(fn {slot, _index} -> slot == :string end)
    |> Enum.map(fn {_slot, index} -> index end)
  end
end
