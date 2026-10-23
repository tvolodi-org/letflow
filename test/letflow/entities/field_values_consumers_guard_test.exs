defmodule Letflow.Entities.FieldValuesConsumersGuardTest do
  @moduledoc """
  REQ-516 S4 (GH #2701), test G1: source-scan guards for the consumers of entity-event
  `field_values` that no slice redacts because they do not read them today (design
  section 4, C10 audit states and C12 logs; C7/C8 are pinned in
  `Letflow.WebhooksRedactionTest`). A new reader of event `field_values` in one of these
  places fails here, so the change to it is conscious: route it through
  `Letflow.Entities.FieldPolicy.redact_for_recipient/3` and then update the list below.
  Design: `lib/letflow/design/req516-record-history-field-policy.md` sections 4 and 6.
  """

  use ExUnit.Case, async: true

  @lib Path.join(File.cwd!(), "lib")

  # Files that build an audit entry (`Audit.insert_entry`) AND mention `field_values`
  # today. Each was read for REQ-516 S4: none puts event field values into
  # before_state/after_state (entities.ex: field NAMES of an export; exam/snapshot.ex:
  # origin, timestamps and ids; instances.ex: moduledoc text only).
  @audit_writers_mentioning_field_values [
    "letflow/modules/exam/snapshot.ex",
    "letflow/routers/entities.ex",
    "letflow/routers/instances.ex"
  ]

  defp lib_files do
    @lib
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/lib/letflow/design/"))
  end

  # A file writes audit entries through `Audit.insert_entry` or the public wrapper
  # `Audit.append_multi/4`. A bare `append_multi` is not matched: `EventStore.append_multi`
  # is the record event store, not the audit.
  @audit_write ~r/insert_entry|Audit\.append_multi/

  defp rel(path), do: Path.relative_to(path, @lib)

  describe "G1 (C10): audit entries are hash-chained, so they never carry raw field_values" do
    test "the audit store and its readers do not reference field_values" do
      paths =
        ["letflow/audit.ex", "letflow/routers/audit.ex"] ++
          (@lib |> Path.join("letflow/audit/**/*.ex") |> Path.wildcard() |> Enum.map(&rel/1))

      assert length(paths) >= 3

      for path <- paths do
        refute File.read!(Path.join(@lib, path)) =~ "field_values",
               "#{path} now references field_values: an audit entry cannot be redacted later " <>
                 "(hash chain); store FieldPolicy.redact_for_recipient/3 output and update this guard " <>
                 "(REQ-516 design 4, C10)"
      end
    end

    test "only the known audit writers mention field_values" do
      writers =
        lib_files()
        |> Enum.filter(fn path ->
          source = File.read!(path)
          source =~ @audit_write and source =~ "field_values"
        end)
        |> Enum.map(&rel/1)
        |> Enum.sort()

      assert writers == @audit_writers_mentioning_field_values,
             "a module that writes audit entries now mentions field_values (or one stopped): " <>
               "check its before_state/after_state holds no raw event values, then update " <>
               "@audit_writers_mentioning_field_values (REQ-516 design 4, C10)"
    end
  end

  test "the writer filter sees append_multi-only audit writers (it is not vacuous for that API)" do
    path = Path.join(@lib, "letflow/tasks.ex")
    source = File.read!(path)

    assert path in lib_files()
    assert source =~ @audit_write
    refute source =~ "insert_entry"
  end

  describe "G1 (C9): the DLQ stores already-redacted payloads and cannot redact on read" do
    test "the DLQ context, entry schema and read route do not reference field_values" do
      for path <- ["letflow/dlq.ex", "letflow/dlq/entry.ex", "letflow/routers/dlq.ex"] do
        refute File.read!(Path.join(@lib, path)) =~ "field_values",
               "#{path} now references field_values (REQ-516 design 4, C9)"
      end
    end
  end

  describe "G1 (C12): logs never carry a payload or field_values" do
    # A Logger call (to the closing paren at the call's indentation, or a blank line)
    # that mentions field_values or interpolates/inspects a payload.
    @logger_call ~r/Logger\.(?:debug|info|notice|warn|warning|error|critical|alert|emergency|log|bare_log)\((?:(?!\n\s*\n).){0,600}/s
    @leak ~r/field_values|#\{[^}]*\bpayload\b|inspect\([^)]*\b(?:payload|field_values)\b/

    test "no Logger call mentions field_values or interpolates a payload" do
      offenders =
        for path <- lib_files(),
            source = File.read!(path),
            [call] <- Regex.scan(@logger_call, source),
            call =~ @leak do
          {rel(path), call |> String.split("\n") |> hd()}
        end

      assert offenders == [],
             "Logger call(s) may log event values (REQ-516 design 4, C12): #{inspect(offenders)}"
    end

    test "the scan sees Logger calls at all (it is not vacuous)" do
      count =
        Enum.count(lib_files(), fn path -> Regex.match?(@logger_call, File.read!(path)) end)

      assert count > 20
    end
  end
end
