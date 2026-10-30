defmodule Letflow.RecordTriggers.Runner do
  @moduledoc """
  REQ-628 slice T-4 part A (GH #3507, decision 0067 D3/D5/D7) -- the run of one claimed
  `record_trigger_outbox` row, replacing the T-3 stub. It writes nothing: `run/2` returns the
  validated write lines and `Letflow.RecordTriggers.Apply` applies them in one transaction.

  Steps: `Runtime.prepare_run/3` (tenant id from the tick's schema name, never from the row; the
  pin is the row's own, hook kind `entity_event`); the 0062 R5 check over the manifest's declared
  write targets (before the sandbox starts); the input build from the live record with redaction;
  the pre-fetched reads (outside any transaction, so the sandbox has no `Repo` access); the
  sandbox run; the output checks.

  **Input.** `%{"record" => nil | %{"id" => id, <kept fields>}, "event" => ..., "source_seq" => n,
  "record_seq" => n | nil}` plus `"reads"`. A missing, deleted or typeless record, and a `deleted`
  event, all give `"record" => nil` built by the same code path, so the term does not tell them
  apart. The principal is tenant-wide (0051 D1), so "outside the principal's scope" is realised by
  those cases. A restricted field enters only when the manifest names it and the publisher holds
  `:EntitiesRestrictionsManage` now; a failed restriction load is a dead row, never a different
  `record: nil`.

  **Output.** One declared output property, `"writes"`: a list of `{entity_type, mode, fields}`
  lines (plus `external_ref` for `upsert_by_external_ref`), each matching a line of the manifest's
  `writes` and no longer than it.

  Never raises; every failure is a closed code (INV-8), never error text.
  """

  import Ecto.Query

  alias Letflow.Api.Authorization
  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.Engine.ScriptInput
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.HiddenLabels
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.ScriptReads
  alias Letflow.Identity
  alias Letflow.RecordTriggers.OutboxRow
  alias Letflow.Repo
  alias Letflow.Scripts.EntityWrite
  alias Letflow.Scripts.Runtime
  alias Letflow.Scripts.ScriptRule
  alias Letflow.TenantProvisioning

  @hook_kind "entity_event"
  @line_keys ~w(entity_type mode fields external_ref)

  @type line :: %{
          index: non_neg_integer(),
          entity_type: String.t(),
          mode: String.t(),
          fields: map(),
          external_ref: map() | nil
        }

  @doc "Runs the pinned script for `row` in tenant schema `prefix`; see the moduledoc."
  @spec run(OutboxRow.t(), String.t()) ::
          {:ok, [line()]} | {:retry, String.t()} | {:dead, String.t()}
  def run(%OutboxRow{} = row, prefix) when is_binary(prefix) do
    do_run(row, prefix)
  rescue
    _ -> {:dead, "script_error"}
  catch
    _kind, _ -> {:dead, "script_error"}
  end

  defp do_run(row, prefix) do
    with {:ok, spec} <- prepare(row, prefix),
         :ok <- check_r5(spec.manifest, prefix),
         {:ok, input} <- build_input(row, spec.manifest, prefix),
         {:ok, input} <- put_reads(input, spec, prefix),
         :ok <- sign(row, input, spec),
         {:ok, output} <- run_script(row, spec, input, prefix) do
      check_lines(output, spec.manifest, row)
    end
  end

  # ── prepare_run ──────────────────────────────────────────────────────────────

  defp prepare(row, prefix) do
    binding = %{
      script_key: row.script_key,
      script_version: row.script_version,
      script_sha256: row.script_sha256,
      hook_kind: @hook_kind
    }

    prepared =
      case TenantProvisioning.tenant_id_for_schema_name(prefix) do
        {:ok, tenant_id} -> Runtime.prepare_run(prefix, tenant_id, binding)
        _error -> {:rejected, :tenant_inactive}
      end

    case prepared do
      {:ok, spec} -> {:ok, spec}
      {:rejected, reason} -> {:dead, rejection_code(reason)}
    end
  end

  defp rejection_code(reason)
       when reason in [:script_unavailable, :script_revoked, :pin_mismatch],
       do: Atom.to_string(reason)

  defp rejection_code(_other), do: "script_rejected"

  # ── decision 0062 R5 at run time ─────────────────────────────────────────────

  defp check_r5(manifest, prefix) do
    targets =
      for %{"entity_type" => type, "fields" => fields} <- Map.get(manifest, "writes", []),
          field <- fields,
          do: type <> "." <> field

    if EntityWrite.r5_violation?(
         HiddenLabels.load_platform_hidden_labels(prefix),
         Runtime.manifest_taint(manifest),
         targets
       ),
       do: {:dead, "script_output_restriction_widened"},
       else: :ok
  end

  # ── input build and redaction ────────────────────────────────────────────────

  @doc false
  @spec build_input(OutboxRow.t(), map(), String.t()) :: {:ok, map()} | {:dead, String.t()}
  def build_input(%OutboxRow{} = row, manifest, prefix) do
    latest = live_record(row, prefix)

    with {:ok, record, record_seq} <- record_input(row, latest, manifest, prefix) do
      {:ok,
       %{
         "record" => record,
         "event" => Atom.to_string(row.event),
         "source_seq" => row.source_seq,
         "record_seq" => record_seq
       }}
    end
  end

  # nil for every case the script must not tell apart.
  defp live_record(%OutboxRow{event: :deleted}, _prefix), do: nil

  defp live_record(row, prefix) do
    latest =
      Repo.get_by(Latest, [entity_type: row.entity_type, record_id: row.record_id],
        prefix: prefix
      )

    case latest do
      %Latest{deleted: false} = latest ->
        if match?({:ok, _}, Definitions.get_active_definition_by_name(row.entity_type, prefix)),
          do: latest,
          else: nil

      _missing_or_deleted ->
        nil
    end
  end

  defp record_input(_row, nil, _manifest, _prefix), do: {:ok, nil, nil}

  defp record_input(row, %Latest{} = latest, manifest, prefix) do
    with {:ok, restricted} <- load_restricted(prefix),
         {:ok, fields, _taint} <-
           built(row.entity_type, latest.field_values, manifest, restricted, prefix, row) do
      {:ok, Map.put(fields, "id", row.record_id), latest.last_event_global_seq}
    end
  end

  defp load_restricted(prefix) do
    case HiddenLabels.load_platform_hidden_labels(prefix) do
      {:ok, restricted} -> {:ok, restricted}
      _error -> {:dead, "script_error"}
    end
  end

  defp built(type, candidate, manifest, restricted, prefix, row) do
    may? = publisher_may_restricted?(prefix, row.script_key, row.script_version)

    case EntityWrite.build_input(type, candidate, manifest, restricted, may?) do
      {:ok, fields, taint} -> {:ok, fields, taint}
      {:error, :input_invalid} -> {:dead, "input_invalid"}
    end
  end

  # Fail closed: no publisher, an inactive user, a lookup error or a missing permission is false.
  defp publisher_may_restricted?(prefix, key, version) do
    publisher_id =
      from(r in ScriptRule,
        where: r.key == ^key and r.version == ^version,
        select: r.publisher_id
      )
      |> Repo.one(prefix: prefix)

    with id when is_binary(id) <- publisher_id,
         {:ok, user} <- Identity.get_user(id, prefix: prefix),
         true <- Identity.active_user?(user) do
      id
      |> Identity.tenant_wide_role_names(prefix: prefix)
      |> MapSet.to_list()
      |> Authorization.roles_from_strings()
      |> Authorization.has_permission?(:EntitiesRestrictionsManage)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  # ── pre-fetched reads ────────────────────────────────────────────────────────

  defp put_reads(input, %{reads: []}, _prefix), do: {:ok, input}

  defp put_reads(input, spec, prefix) do
    declared = fields_of(input["record"])

    case ScriptReads.prefetch(prefix, spec.reads, declared) do
      {:ok, %{} = rows} -> {:ok, ScriptInput.put_reads(input, rows)}
      _refused -> {:dead, "script_rejected"}
    end
  end

  defp fields_of(%{} = record), do: Map.delete(record, "id")
  defp fields_of(nil), do: %{}

  defp sign(row, input, spec) do
    ctx = %{
      "instance_id" => row.id,
      "node_id" => "record_trigger",
      "token_id" => row.id,
      "now" => DateTime.to_iso8601(row.occurred_at)
    }

    case spec.hmac_fun.(ScriptInput.canonical(input, ctx)) do
      {:ok, _hmac} -> :ok
      _failed -> {:dead, "script_rejected"}
    end
  end

  # ── sandbox ──────────────────────────────────────────────────────────────────

  defp run_script(row, spec, input, prefix) do
    result =
      runner().run(spec.source, input,
        tenant: prefix,
        ctx: %{
          instance_id: row.id,
          node_id: "record_trigger",
          token_id: row.id,
          now: row.occurred_at
        },
        fail_codes: spec.fail_codes,
        instructions: spec.limits.instructions,
        timeout_ms: spec.limits.timeout_ms,
        heap_words: spec.limits.heap_words
      )

    case result do
      {:ok, %{output: output}} -> check_output(output, spec.manifest)
      {:error, :script_busy, _detail} -> {:retry, "script_busy"}
      {:error, :output_invalid, _detail} -> {:dead, "output_invalid"}
      {:error, :script_failed, _detail} -> {:dead, "script_failed"}
      {:error, code, _detail} when is_atom(code) -> {:dead, failure_code(code)}
      _unexpected -> {:dead, "script_error"}
    end
  end

  @known_failures ~w(script_error budget_exceeded memory_limit_exceeded timeout script_rejected)a

  defp failure_code(code) when code in @known_failures, do: Atom.to_string(code)
  defp failure_code(_code), do: "script_error"

  defp check_output(output, manifest) do
    case Runtime.check_output(output, manifest) do
      {:ok, declared} -> {:ok, declared}
      {:error, _reason} -> {:dead, "output_invalid"}
    end
  end

  # [CDV C2] the runner seam is honoured only under :scripts_test_hooks.
  defp runner do
    case Application.get_env(:letflow, :record_trigger_script_runner) do
      module when is_atom(module) and not is_nil(module) ->
        if Runtime.test_hooks?(), do: module, else: ScriptRunner

      _ ->
        ScriptRunner
    end
  end

  # ── output lines against the manifest's writes ───────────────────────────────

  defp check_lines(output, manifest, row) do
    declared = Map.get(manifest, "writes", [])

    with %{"writes" => lines} when is_list(lines) and length(lines) <= length(declared) <- output,
         {:ok, normalised} <- normalise(lines, declared, row) do
      {:ok, Enum.with_index(normalised, fn line, index -> Map.put(line, :index, index) end)}
    else
      _ -> {:dead, "output_invalid"}
    end
  end

  defp normalise(lines, declared, row) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case normalise_line(line, declared, row) do
        {:ok, normalised} -> {:cont, {:ok, [normalised | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp normalise_line(
         %{"entity_type" => type, "mode" => mode, "fields" => %{} = fields} = line,
         declared,
         row
       )
       when is_binary(type) and is_binary(mode) do
    allowed = declared_fields(declared, type, mode)

    with true <- Enum.all?(Map.keys(line), &(&1 in @line_keys)),
         true <- allowed != nil and Enum.all?(Map.keys(fields), &(&1 in allowed)),
         true <- mode != "update_self" or type == row.entity_type,
         {:ok, ref} <- external_ref(mode, line) do
      {:ok, %{entity_type: type, mode: mode, fields: fields, external_ref: ref}}
    else
      _ -> :error
    end
  end

  defp normalise_line(_line, _declared, _row), do: :error

  # The union of the declared fields of every declared line with this (type, mode); nil if none.
  defp declared_fields(declared, type, mode) do
    matching =
      for %{"entity_type" => ^type, "mode" => ^mode, "fields" => fields} <- declared,
          do: fields

    if matching == [], do: nil, else: List.flatten(matching)
  end

  defp external_ref("upsert_by_external_ref", %{"external_ref" => %{} = ref}), do: {:ok, ref}
  defp external_ref("upsert_by_external_ref", _line), do: :error
  defp external_ref(_mode, %{"external_ref" => _}), do: :error
  defp external_ref(_mode, _line), do: {:ok, nil}
end
