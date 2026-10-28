defmodule Letflow.Scripts.EntityWriteTenantTest do
  @moduledoc """
  REQ-601 / GH #3380 part B, criteria 9 and 10: the tenant prefix is the only tenant selector of
  `Letflow.Scripts.EntityWrite.run/4` (INV-1, INV-10), and the module has no other caller and no
  other `lib/` file changed. `async: false` (tenant provisioning).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.ScriptReads
  alias Letflow.Scripts.EntityWrite
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F

  @now ~U[2026-10-26 08:00:00.000000Z]
  @manifest %{
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"amount" => %{"type" => "integer"}}
    },
    "output_schema" => %{
      "type" => "object",
      "properties" => %{"total" => %{"type" => "integer"}},
      "additionalProperties" => false
    },
    "derived_fields" => ["total"],
    "fail_codes" => [],
    "limits" => %{"timeout_ms" => 5_000}
  }

  setup do
    a = F.tenant!("r601a")
    b = F.tenant!("r601b")

    for t <- [a, b] do
      P.active_definition!(t.schema_name, "tt", ["amount", "total"])
    end

    rule =
      F.published!(
        a.schema_name,
        "derive_total",
        "return { total = ctx.input.amount * 2 }",
        @manifest,
        hook_kind: "entity_write"
      )

    pin = %{script_key: rule.key, script_version: rule.version, script_sha256: rule.sha256}
    {:ok, a: a.schema_name, b: b.schema_name, pin: pin}
  end

  defp facts(extra \\ %{}),
    do: Map.merge(%{entity_type: "tt", candidate: %{"amount" => 2}, now: @now}, extra)

  describe "criterion 9: prefix is the only tenant selector" do
    test "T9a tenant B cannot reach tenant A's version", %{a: _a, b: b, pin: pin} do
      absent = %{pin | script_key: "exists_nowhere"}
      result = EntityWrite.run(b, pin, facts())
      assert result == EntityWrite.run(b, absent, facts())
      assert {:error, :script_rejected, _} = result
    end

    test "T9b tenant A runs it", %{a: a, pin: pin} do
      assert {:ok, %{derived: %{"total" => 4}}} = EntityWrite.run(a, pin, facts())
    end

    test "T9c reads of another tenant's type are refused", %{a: a, b: b} do
      P.active_definition!(a, "only_a", ["name"])
      P.flag!(a, "only_a")
      reads = [P.id_read("r", "only_a")]

      assert ScriptReads.prefetch_with_fingerprint(b, reads, %{"cid" => "x"}) ==
               {:error, :reads_not_allowed}
    end

    test "T9d foreign tenant strings in facts change nothing", %{a: a, b: b, pin: pin} do
      plain = EntityWrite.run(a, pin, facts())

      noisy =
        EntityWrite.run(
          a,
          pin,
          facts(%{tenant: b, prefix: b, schema: b, tenant_id: b})
        )

      assert {:ok, %{derived: d1}} = plain
      assert {:ok, %{derived: ^d1}} = noisy

      # and B's prefix with the same extra keys still finds nothing of A's
      assert {:error, :script_rejected, _} =
               EntityWrite.run(b, pin, facts(%{tenant: a, prefix: a}))
    end

    test "T9e every Repo call passes a prefix and no SQL is interpolated" do
      for file <- ["lib/letflow/scripts/entity_write.ex"] do
        source = File.read!(file)
        calls = Regex.scan(~r/Repo\.(?!aggregate)[a-z_!?]+\([^\n]*/, source)
        assert Enum.all?(calls, fn [call] -> call =~ "prefix" end), inspect(calls)
        refute source =~ "Repo.query"
        refute source =~ "fragment("
      end
    end
  end

  describe "criterion 10: scope" do
    test "T10a EntityWrite.run and prefetch_with_fingerprint have no other caller in lib/" do
      files = Path.wildcard("lib/**/*.ex")

      hits = fn needle ->
        for f <- files, File.read!(f) =~ needle, do: Path.basename(f)
      end

      assert hits.("EntityWrite.run") == []

      assert Enum.sort(hits.("prefetch_with_fingerprint")) == [
               "entity_write.ex",
               "script_reads.ex"
             ]
    end
  end
end
