defmodule Letflow.Scripts.RuntimeTest do
  @moduledoc """
  GH 2534 PR 7c-2, design `lib/letflow/design/gh2534-7c-script-handler.md` 5.3 step 3 and 11.3
  (`Letflow.Scripts.Runtime.prepare_run/3` in 7c-2):

    * SR-OPT-1 (decision 0062 part 3): the restricted opt-in is allowed; the 0053 C10 refusal and
      its `restricted_opt_in_unsupported` backstop are gone. A `restricted_inputs` `from` pair is
      re-checked with the reads (`reads_not_allowed`).
    * The normative step order: closed output schema, then the run-time `check_reads` (first
      failure wins); `run_spec.reads` carries the declared
      reads only when every check passed.

  `async: false`: provisioning switches the sandbox to `:auto`; tests flip application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Scripts
  alias Letflow.Scripts.Policy
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

  defp restricted_input(name, entity_type, field),
    do: %{"name" => name, "from" => [%{"entity_type" => entity_type, "field" => field}]}

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

  describe "SR-OPT-1: the restricted opt-in is allowed (0053 C10 lifted by 0062 part 3)" do
    test "restricted_fields on a read no longer rejects the run; the port is called", %{t: t} do
      schema = t.schema_name
      F.record_read_port_calls!()
      F.count_runner_calls!()

      manifest = manifest([read(%{"restricted_fields" => ["name"]})])

      rule =
        F.published!(schema, "k#{System.unique_integer([:positive])}", "return {n = 1}", manifest)

      assert {:ok, %{reads: [%{"restricted_fields" => ["name"]}]}} =
               Runtime.prepare_run(schema, t.tenant_id, binding_of(rule))

      definition = raw_active_definition!(schema, F.script_graph(rule.key, rule.version))

      instance_id =
        F.start!(schema, definition, %{"cid" => Ecto.UUID.generate()}, Ecto.UUID.generate())

      {row, result} = F.run_next!(schema)
      assert result == {:ok, :applied}
      assert F.reload(schema, row).outcome == "ok"
      assert F.projection(schema, instance_id).status != :error

      assert_received {:script_read_port_called, _, _, _}
      assert_received {:script_runner_called, _, _}
    end

    test "a restricted_inputs object whose from pair names a known field is accepted", %{t: t} do
      m = manifest([], %{"restricted_inputs" => [restricted_input("cid", "customer", "name")]})
      assert {:ok, %{manifest: ^m}} = prepare(t, m)
    end

    test "a from pair naming an unknown field or type is reads_not_allowed", %{t: t} do
      bad_field =
        manifest([], %{"restricted_inputs" => [restricted_input("cid", "customer", "zz")]})

      bad_type = manifest([], %{"restricted_inputs" => [restricted_input("cid", "nope", "name")]})

      assert prepare(t, bad_field) == {:rejected, :reads_not_allowed}
      assert prepare(t, bad_type) == {:rejected, :reads_not_allowed}
    end

    test "a legacy bare-name restricted_inputs row still prepares and delivers nothing", %{t: t} do
      assert {:ok, _spec} = prepare(t, manifest([], %{"restricted_inputs" => ["cid"]}))
    end
  end

  describe "REVIEWER F1: a match.field must be on the query allowlist" do
    setup %{t: t} do
      {:ok, definition} =
        Letflow.Entities.Definitions.create_definition(
          %{
            definition: %{
              name: "acct",
              display_name: "Acct",
              fields: [
                %{name: "name", type: :string, queried: true},
                %{name: "code", type: :string, queried: false}
              ]
            },
            created_by: Ecto.UUID.generate()
          },
          t.schema_name
        )

      {:ok, _} =
        Letflow.Entities.Definitions.activate_definition(
          definition.name,
          Ecto.UUID.generate(),
          "go-live",
          t.schema_name
        )

      SP.flag!(t.schema_name, "acct")

      match_on = fn field ->
        SP.field_read("r", "acct", field, %{"match" => %{"field" => field, "value_from" => "cid"}})
      end

      %{match_on: match_on}
    end

    test "refused at save, at publish (check_reads with lock: :share) and at run", %{
      t: t,
      match_on: match_on
    } do
      schema = t.schema_name
      not_queried = manifest([match_on.("code")])
      queried = manifest([match_on.("name")])

      # positive control: the same read on a queried field passes every check
      assert Policy.check_reads(schema, queried) == :ok
      assert Policy.check_reads(schema, queried, lock: :share) == :ok
      assert {:ok, _spec} = prepare(t, queried)

      # publish runs check_reads (plain, then lock: :share inside its transaction)
      assert Policy.check_reads(schema, not_queried) == {:error, :reads_not_allowed}
      assert Policy.check_reads(schema, not_queried, lock: :share) == {:error, :reads_not_allowed}

      body = %{
        "hook_kind" => "service_task",
        "source" => "return {n = 1}",
        "manifest" => not_queried,
        "test_cases" => [
          %{"name" => "c1", "input" => %{}, "expect" => %{"output" => %{"n" => 1}}}
        ]
      }

      assert Scripts.create_draft(
               schema,
               "k#{System.unique_integer([:positive])}",
               body,
               SP.actor()
             ) ==
               {:error, :reads_not_allowed}

      # run (a version stored before the rule existed)
      assert prepare(t, not_queried) == {:rejected, :reads_not_allowed}
    end
  end

  describe "step order (design 11.3)" do
    test "3a closed output schema wins over 3b check_reads", %{t: t} do
      open = %{"output_schema" => %{"type" => "object"}}
      m = manifest([read(%{"restricted_fields" => ["name"], "entity_type" => "nope"})], open)
      assert prepare(t, m) == {:rejected, :output_schema_open}
    end

    test "3b a restricted_inputs from pair is re-checked with the reads (one code)", %{t: t} do
      m = manifest([], %{"restricted_inputs" => [restricted_input("cid", "nope", "name")]})
      assert prepare(t, m) == {:rejected, :reads_not_allowed}
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
