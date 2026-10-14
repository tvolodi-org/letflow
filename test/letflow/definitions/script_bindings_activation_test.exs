defmodule Letflow.Definitions.ScriptBindingsActivationTest do
  @moduledoc """
  GH 2534 PR 7c-1 AC1 (definition save), AC2 and AC2a (design
  `lib/letflow/design/gh2534-7c-script-handler.md` 4.5, C8, C10, C11a): a definition binding a
  tenant script is refused activation unless every bound `(key, version)` is a published
  `service_task` version with a CLOSED output schema, no restricted opt-in and (7c-1) no
  `reads` -- in ALL three activation paths (`Definitions.activate/2`, promotion, version
  rollback). Each refusal writes nothing.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.Promotion
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Scripts.Runtime
  alias Letflow.Support.ScriptTaskFixture, as: F

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  # A script version of `key` in `status` (or no row at all for :absent); returns the version
  # number the graph should bind.
  defp version_in_status!(schema, key, status, manifest) do
    case status do
      :absent ->
        99

      :draft ->
        F.draft!(schema, key, F.doubling_source(), manifest).version

      :discarded ->
        draft = F.draft!(schema, key, F.doubling_source(), manifest)

        draft
        |> Ecto.Changeset.change(status: "discarded", discarded_at: DateTime.utc_now())
        |> Repo.update!(prefix: schema)
        |> Map.fetch!(:version)

      :retired ->
        schema
        |> F.published!(key, F.doubling_source(), manifest)
        |> then(&F.retire_raw!(schema, &1))
        |> Map.fetch!(:version)

      :revoked ->
        schema
        |> F.published!(key, F.doubling_source(), manifest)
        |> then(&F.revoke_raw!(schema, &1))
        |> Map.fetch!(:version)

      :published ->
        F.published!(schema, key, F.doubling_source(), manifest).version
    end
  end

  # ── the three paths ─────────────────────────────────────────────────────────

  defp activate_path(schema, graph) do
    draft = F.draft_definition!(schema, graph, [])
    result = Definitions.activate(draft.id, prefix: schema)
    status = Repo.get!(ProcessDefinition, draft.id, prefix: schema).status
    {result, status}
  end

  defp raw_definition!(schema, name, version, graph, status) do
    row =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: name,
        version: version,
        graph: graph,
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: schema)

    {1, _} =
      from(d in ProcessDefinition, where: d.id == ^row.id)
      |> Repo.update_all([set: [status: status]], prefix: schema)

    row
  end

  defp promote_path(source, target, graph) do
    key = unique("promo-proc")
    source_def = raw_definition!(source.schema_name, key, "1.0.0", graph, :active)

    plan = %{
      source_tenant_id: source.tenant_id,
      target_tenant_id: target.tenant_id,
      process_key: key,
      source_definition_id: source_def.id,
      target_definition_id: nil,
      base_version: nil,
      entries: []
    }

    review =
      struct(PromotionReview, %{
        id: Ecto.UUID.generate(),
        plan_digest: PromotionDigest.compute_plan_digest(plan),
        def_id: key,
        serialised_plan: Jason.encode!(plan),
        requested_by: Ecto.UUID.generate(),
        status: :approved,
        row_version: 2
      })

    result =
      Promotion.promote_definition(Ecto.UUID.generate(), review,
        permission_checker: fn _actor, _tenant -> true end,
        event_appender: fn _attrs, _prefix -> {:ok, %{event_id: Ecto.UUID.generate()}} end
      )

    rows =
      Repo.all(from(d in ProcessDefinition, where: d.name == ^key), prefix: target.schema_name)

    {result, rows}
  end

  defp rollback_path(schema, graph) do
    key = unique("rb-proc")
    raw_definition!(schema, key, "1", graph, :deprecated)
    trivial = %{"nodes" => trivial_nodes(), "edges" => trivial_edges()}
    v2 = raw_definition!(schema, key, "2", trivial, :active)

    result =
      Definitions.rollback_definition_version(key, "1", Ecto.UUID.generate(),
        prefix: schema,
        permission_checker: fn _actor, _tenant -> true end,
        event_appender: fn _attrs, _prefix -> {:ok, %{event_id: Ecto.UUID.generate()}} end
      )

    {result, Repo.get!(ProcessDefinition, v2.id, prefix: schema).status}
  end

  defp trivial_nodes,
    do: [%{"id" => "start", "node_type" => "START"}, %{"id" => "end", "node_type" => "END"}]

  defp trivial_edges, do: [%{"id" => "e1", "source" => "start", "target" => "end"}]

  defp assert_refused_everywhere(source, target, graph, reason) do
    expected = {:error, {:script_binding_invalid, "svc", reason}}

    assert {^expected, :draft} = activate_path(target.schema_name, graph)
    assert {^expected, []} = promote_path(source, target, graph)
    assert {^expected, :active} = rollback_path(target.schema_name, graph)
  end

  setup do
    %{
      source: F.tenant_without_hmac!("gh2534-7c-act-src"),
      target: F.tenant_without_hmac!("gh2534-7c-act-tgt")
    }
  end

  # ── AC1 at definition save ─────────────────────────────────────────────────

  test "AC1: a script binding also carrying an endpoint is refused at definition save", %{
    target: t
  } do
    graph = F.script_graph("pricing", 1)
    [start, svc, finish] = graph["nodes"]
    svc = put_in(svc, ["attributes", "endpoint"], "http://example.invalid")
    graph = %{graph | "nodes" => [start, svc, finish]}

    assert {:error, {:graph_validation_failed, violations}} =
             Definitions.create(
               %{
                 name: unique("save"),
                 version: "1",
                 graph: graph,
                 created_by: Ecto.UUID.generate()
               },
               prefix: t.schema_name
             )

    assert :conflicting_service_task_routes in Enum.map(violations, & &1.code)
  end

  # ── AC2 ─────────────────────────────────────────────────────────────────────

  describe "AC2: refused per status x3 paths" do
    for status <- [:draft, :discarded, :retired, :revoked, :absent] do
      test "#{status} -> :script_not_published in activate, promotion and rollback", %{
        source: s,
        target: t
      } do
        key = unique("k")
        version = version_in_status!(t.schema_name, key, unquote(status), F.closed_manifest())
        assert_refused_everywhere(s, t, F.script_graph(key, version), :script_not_published)
      end
    end

    test "a published version activates in all three paths", %{source: s, target: t} do
      key = unique("k")
      version = version_in_status!(t.schema_name, key, :published, F.closed_manifest())
      graph = F.script_graph(key, version)

      assert {{:ok, %{definition: %{status: :active}}}, :active} =
               activate_path(t.schema_name, graph)

      assert {{:ok, _}, [%{status: :active}]} = promote_path(s, t, graph)
      assert {{:ok, _}, :deprecated} = rollback_path(t.schema_name, graph)
    end

    test "version conflict: two versions of one key", %{target: t} do
      key = unique("k")
      v1 = version_in_status!(t.schema_name, key, :published, F.closed_manifest())
      v2 = version_in_status!(t.schema_name, key, :published, F.closed_manifest())
      graph = F.two_script_graph(key, v1, key, v2)

      assert {{:error, {:script_binding_invalid, "svc2", :script_version_conflict}}, :draft} =
               activate_path(t.schema_name, graph)
    end

    test "reads unsupported (7c-1)", %{source: s, target: t} do
      key = unique("k")

      manifest =
        Map.put(F.closed_manifest(), "reads", [
          %{
            "name" => "c",
            "entity_type" => "customer",
            "match" => %{"id_from" => "amount"},
            "fields" => ["name"]
          }
        ])

      version = version_in_status!(t.schema_name, key, :published, manifest)
      assert_refused_everywhere(s, t, F.script_graph(key, version), :script_reads_unsupported)
    end

    test "restricted opt-in", %{source: s, target: t} do
      key = unique("k")
      manifest = Map.put(F.closed_manifest(), "restricted_inputs", ["amount"])
      version = version_in_status!(t.schema_name, key, :published, manifest)

      assert_refused_everywhere(
        s,
        t,
        F.script_graph(key, version),
        :script_restricted_opt_in_unsupported
      )

      key2 = unique("k")

      manifest2 =
        Map.put(F.closed_manifest(), "reads", [
          %{
            "name" => "c",
            "entity_type" => "customer",
            "match" => %{"id_from" => "amount"},
            "fields" => ["name"],
            "restricted_fields" => ["name"]
          }
        ])

      version2 = version_in_status!(t.schema_name, key2, :published, manifest2)

      assert {{:error, {:script_binding_invalid, "svc", :script_restricted_opt_in_unsupported}},
              :draft} = activate_path(t.schema_name, F.script_graph(key2, version2))
    end
  end

  # ── AC2a ────────────────────────────────────────────────────────────────────

  describe "AC2a: closed output schema" do
    test "open output schema refused x3 paths", %{source: s, target: t} do
      closed = F.closed_manifest()

      for open_schema <- [
            Map.delete(closed["output_schema"], "additionalProperties"),
            Map.put(closed["output_schema"], "properties", %{}),
            Map.delete(closed["output_schema"], "properties"),
            %{"type" => "object"}
          ] do
        key = unique("k")
        manifest = Map.put(closed, "output_schema", open_schema)
        version = version_in_status!(t.schema_name, key, :published, manifest)
        assert_refused_everywhere(s, t, F.script_graph(key, version), :script_output_schema_open)
      end
    end

    test "prepare_run output_schema_open", %{target: t} do
      key = unique("k")

      manifest =
        Map.put(F.closed_manifest(), "output_schema", %{
          "type" => "object",
          "properties" => %{"total" => %{"type" => "integer"}}
        })

      rule = F.published!(t.schema_name, key, F.doubling_source(), manifest)

      assert Runtime.prepare_run(t.schema_name, t.tenant_id, %{
               script_key: key,
               script_version: rule.version,
               script_sha256: rule.sha256
             }) == {:rejected, :output_schema_open}
    end

    test "closed_output_schema?/1 is the same strict rule everywhere (pure)" do
      closed = F.closed_manifest()
      assert Runtime.closed_output_schema?(closed)
      refute Runtime.closed_output_schema?(put_in(closed, ["output_schema", "type"], "array"))
      refute Runtime.closed_output_schema?(Map.delete(closed, "output_schema"))
      refute Runtime.closed_output_schema?(nil)
      assert Runtime.declared_outputs(closed) == ["total"]
    end
  end
end
