defmodule Letflow.Identity.AuditContextTest do
  @moduledoc """
  GH 2547 (design `lib/letflow/design/gh2547-tenant-admin-audit-and-count.md` sections 2.2 and
  10c): `Letflow.Identity.AuditContext`, the pure module that resolves actor, trace id and source
  for the audited identity writes. Spec: `test/specs/GH-2547.md`, T-19c (SEC-A1) and the SEC-A4
  control-character rule. The HTTP half of T-19c (a 256-byte `x-trace-id` header reaching an
  audit row) is in `test/letflow/routers/identity_gh2547_audit_test.exs`.

  No database, no process state beyond `Logger` metadata, which each test sets and restores
  itself; `async: true` is safe because `Logger.metadata/1` is per process.
  """

  use ExUnit.Case, async: true

  alias Letflow.Identity.AuditContext

  # Logger metadata is per process: each test starts from none and needs no restore.
  setup do
    Logger.reset_metadata([])
    :ok
  end

  describe "T-19c normalize_trace_id/1 (SEC-A1)" do
    test "300 ASCII characters are cut to the first 255" do
      value = String.duplicate("a", 300)
      result = AuditContext.normalize_trace_id(value)

      assert result == String.duplicate("a", 255)
      assert String.length(result) == 255
    end

    test "a value of exactly 255 characters is kept whole; a short UUID is unchanged" do
      exact = String.duplicate("b", 255)
      assert AuditContext.normalize_trace_id(exact) == exact

      uuid = "0f6b3c2e-2547-4a11-8c20-000000000001"
      assert AuditContext.normalize_trace_id(uuid) == uuid
    end

    test "254 ASCII + one 3-byte character + 10 more: 255 codepoints, cut on a codepoint boundary" do
      value = String.duplicate("a", 254) <> "€" <> String.duplicate("z", 10)
      result = AuditContext.normalize_trace_id(value)

      assert String.valid?(result)
      assert String.length(result) == 255
      assert result == String.duplicate("a", 254) <> "€"
      # 255 characters, 257 bytes: the varchar(255) limit counts characters.
      assert byte_size(result) == 257
    end

    test "a 256-byte value cut in the middle of a codepoint (invalid UTF-8) becomes nil" do
      # What `Letflow.Api.Context` produces for a header whose 256th byte falls inside "é".
      cut = binary_part(String.duplicate("a", 255) <> "é", 0, 256)

      assert byte_size(cut) == 256
      refute String.valid?(cut)
      assert AuditContext.normalize_trace_id(cut) == nil
    end

    test "empty and non-binary values become nil" do
      for value <- ["", nil, 42, :trace, [?c, ?l], %{"trace" => "x"}, ["x"]] do
        assert AuditContext.normalize_trace_id(value) == nil, inspect(value)
      end
    end
  end

  describe "SEC-A4 control characters" do
    test "a value containing any Unicode Cc character becomes nil" do
      for cc <- ["\0", "\r", "\n", "\t", "\e", <<0x7F>>, "\u0085", "\u009F"] do
        assert AuditContext.normalize_trace_id("trace" <> cc <> "id") == nil, inspect(cc)
      end
    end

    test "a control character beyond the 255th codepoint still makes the value nil (checked before the cut)" do
      value = String.duplicate("a", 260) <> "\n"
      assert AuditContext.normalize_trace_id(value) == nil
    end

    test "non-control Unicode (letters, symbols, spaces) is kept" do
      value = "trace id é € 日本"
      assert AuditContext.normalize_trace_id(value) == value
    end
  end

  describe "from_opts/1" do
    test "an explicit map wins: actor, normalized trace, source" do
      actor = Ecto.UUID.generate()
      Logger.metadata(trace_id: "from-logger")

      assert AuditContext.from_opts(
               prefix: "ignored",
               audit_context: %{
                 actor_id: actor,
                 trace_id: String.duplicate("t", 300),
                 source: "api"
               }
             ) == %{actor_id: actor, trace_id: String.duplicate("t", 255), source: "api"}
    end

    test "no audit_context: actor nil, trace from Logger metadata, source \"system\"" do
      Logger.metadata(trace_id: "cli-run-trace")

      assert AuditContext.from_opts(prefix: "x") ==
               %{actor_id: nil, trace_id: "cli-run-trace", source: "system"}
    end

    test "no audit_context and no Logger trace: every field has its fallback" do
      assert AuditContext.from_opts([]) == %{actor_id: nil, trace_id: nil, source: "system"}
    end

    test "a partial or malformed context never raises and falls back field by field" do
      Logger.metadata(trace_id: "fallback-trace")

      assert AuditContext.from_opts(audit_context: %{actor_id: 7, trace_id: "", source: :api}) ==
               %{actor_id: nil, trace_id: "fallback-trace", source: "system"}

      assert AuditContext.from_opts(audit_context: "not a map") ==
               %{actor_id: nil, trace_id: "fallback-trace", source: "system"}

      assert AuditContext.from_opts(audit_context: %{source: "idp_sync"}) ==
               %{actor_id: nil, trace_id: "fallback-trace", source: "idp_sync"}
    end

    test "an invalid explicit trace becomes nil; it does not fall back to the Logger trace" do
      Logger.metadata(trace_id: "fallback-trace")
      cut = binary_part(String.duplicate("a", 255) <> "é", 0, 256)

      assert AuditContext.from_opts(audit_context: %{trace_id: cut}).trace_id == nil
    end

    test "current_trace_id/0 normalizes the Logger value too" do
      Logger.metadata(trace_id: String.duplicate("l", 400))
      assert AuditContext.current_trace_id() == String.duplicate("l", 255)

      Logger.metadata(trace_id: "bad\nvalue")
      assert AuditContext.current_trace_id() == nil
    end
  end
end
