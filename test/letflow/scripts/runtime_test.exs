defmodule Letflow.Scripts.RuntimeTest do
  @moduledoc """
  GH 2534 PR 7c-2, design `lib/letflow/design/gh2534-7c-script-handler.md` 5.3 step 3 and 11.3
  (`Letflow.Scripts.Runtime.prepare_run/3` in 7c-2):

    * AC26a: a version whose manifest carries a non-empty `restricted_fields`, bound by a
      definition made active WITHOUT the activation check, is rejected
      `restricted_opt_in_unsupported` and the read port is never called (C10: no opt-in path).
    * The normative step order: closed output schema, then the restricted opt-in refusal, then
      the run-time `check_reads` (first failure wins); `run_spec.reads` carries the declared
      reads only when every check passed.

  `async: false`: provisioning switches the sandbox to `:auto`; tests flip application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Scripts.Runtime
  alias Letflow.Support.ScriptPolicyFixture, as: SP
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    t = F.tenant!("gh2534-7c2-runtime")
    SP.active_definition!(t.schema_name, "customer")
    SP.flag!(t.schema_name, "customer")
    %{t: t}
  end

  defp manifest(reads, overrides \\ %{}) do
    Map.merge(
      %{
        "input_schema" => %{"type" => "object", "properties" => %{"cid" => %{"type" => "string"}}},
        "output_schema" => %{
          "type" => "object",
          "properties" => %{"n" => %{"type" => "integer"}},
          "additionalProperties" => false
        },
        "fail_codes" => [],
        "reads" => reads
      },
      overrides
    )
  end

  defp read(extra \\ %{}), do: Map.merge(SP.id_read("r", "customer"), extra)

  defp binding_of(rule),
    do: %{script_key: rule.key, script_version: rule.version, script_sha256: rule.sha256}

  defp prepare(t, manifest) do
    rule =
      F.published!(t.schema_name, "k#{System.unique_integer([:positive])}", "return {}", manifest)

    Runtime.prepare_run(t.schema_name, t.tenant_id, binding_of(rule))
  end

  # An ACTIVE definition written directly (bypassing Definitions.activate/2's binding check).
  defp raw_active_definition!(schema, graph) do
    row =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: "gh2534-7c2-raw-#{System.unique_integer([:positive])}",
        version: "1",
        graph: graph,
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: schema)

    {1, _} =
      from(d in ProcessDefinition, where: d.id == ^row.id)
      |> Repo.update_all([set: [status: :active]], prefix: schema)

    Repo.get!(ProcessDefinition, row.id, prefix: schema)
  end

  describe "AC26a" do
    test "opt-in backstop: restricted_fields inserted directly is rejected and the port is never called",
         %{t: t} do
      schema = t.schema_name
      F.record_read_port_calls!()
      F.count_runner_calls!()

      manifest = manifest([read(%{"restricted_fields" => ["name"]})])

      rule =
        F.published!(schema, "k#{System.unique_integer([:positive])}", "return {n = 1}", manifest)

      assert Runtime.prepare_run(schema, t.tenant_id, binding_of(rule)) ==
               {:rejected, :restricted_opt_in_unsupported}

      definition = raw_active_definition!(schema, F.script_graph(rule.key, rule.version))

      instance_id =
        F.start!(schema, definition, %{"cid" => Ecto.UUID.generate()}, Ecto.UUID.generate())

      {row, result} = F.run_next!(schema)
      assert result == {:ok, :failed}
      row = F.reload(schema, row)
      assert row.outcome == "script_rejected"
      assert row.outcome_detail == "restricted_opt_in_unsupported"
      assert F.projection(schema, instance_id).status == :error

      refute_received {:script_read_port_called, _, _, _}
      refute_received {:script_runner_called, _, _}
    end

    test "restricted_inputs is refused the same way", %{t: t} do
      manifest =
        manifest([], %{
          "restricted_inputs" => ["cid"]
        })

      assert prepare(t, manifest) == {:rejected, :restricted_opt_in_unsupported}
    end
  end

  describe "step order (design 11.3)" do
    test "3a closed output schema wins over 3b restricted opt-in and 3c check_reads", %{t: t} do
      open = %{"output_schema" => %{"type" => "object"}}
      m = manifest([read(%{"restricted_fields" => ["name"], "entity_type" => "nope"})], open)
      assert prepare(t, m) == {:rejected, :output_schema_open}
    end

    test "3b restricted opt-in wins over 3c check_reads", %{t: t} do
      m = manifest([read(%{"restricted_fields" => ["name"], "entity_type" => "nope"})])
      assert prepare(t, m) == {:rejected, :restricted_opt_in_unsupported}
    end

    test "3c check_reads against the CURRENT policy", %{t: t} do
      assert prepare(t, manifest([read(%{"entity_type" => "nope"})])) ==
               {:rejected, :reads_not_allowed}

      SP.restrict_field!(t.schema_name, "customer", "tier")

      tier_match =
        SP.field_read("r", "customer", "tier", %{
          "match" => %{"field" => "tier", "value_from" => "cid"}
        })

      assert prepare(t, manifest([tier_match])) == {:rejected, :reads_not_allowed}
    end

    test "allowed reads reach run_spec.reads; no reads gives []", %{t: t} do
      reads = [read()]
      assert {:ok, %{reads: ^reads}} = prepare(t, manifest(reads))
      assert {:ok, %{reads: []}} = prepare(t, Map.delete(manifest([]), "reads"))
    end
  end
end
