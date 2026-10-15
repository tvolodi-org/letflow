defmodule Letflow.Entities.RecordsCommandMultiTest do
  @moduledoc """
  GH #2587 / REQ-499 PR A2 (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  sections 3.1-3.3, section 11 A2 rows "command_multi/3" and "interpret_in_multi/1", revision 1
  CDV-4 / CDV-6 / SEC F2 / SEC F3):

    * `Records.command_multi/3` builds a composable, `{:line, i, _}`-namespaced Multi per line;
      three lines (two on one type) compose into one transaction without a duplicate-name raise.
    * The per-line authority check, the read-only synthetic-instance lookup, the shape checks
      (kind, line key, anchored step-key regex, source) and the in-transaction
      `{:line, i, :recheck_definition}` step.
    * `EventStore.append_multi/3`'s `:step_namespace` option, and the `sys:step:` refusal of
      every un-namespaced EventStore entry point (D-A2.16).
    * `Records.interpret_in_multi/1` / `classify_step_error/1`: no duplicate-as-success, atoms
      only.

  Setup (CDV-6): the synthetic instances of the two test types are pre-created with
  `EntityTypeInstance.get_or_create/2` directly (`StepWrites.prepare/2` arrives in A3).

  `async: false`: tenant provisioning switches the sandbox to `:auto`, so every
  `Repo.transaction/1` here is a real transaction.
  """

  use Letflow.DataCase, async: false
  use ExUnitProperties

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Modules.FixtureManaged
  alias Letflow.Modules.Installs
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @actor_id "00000000-0000-0000-0000-0000000000a2"
  @type_a "cm_alpha"
  @type_b "cm_beta"

  @line_steps [
    :active_instance_guard,
    :assign_sequence,
    :idempotency,
    :insert_event,
    :update_projection,
    :recheck_definition,
    :upsert_record_latest,
    :dual_write_promoted_columns
  ]

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2587-cm")
    schema = tenant.schema_name

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(schema)

    for type <- [@type_a, @type_b] do
      activate!(schema, type, [])
      {:ok, _instance_id} = EntityTypeInstance.get_or_create(type, schema)
    end

    {:ok, schema: schema, task_id: Ecto.UUID.generate()}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp activate!(schema, name, extra_fields) do
    fields =
      [%{name: "title", type: :string, required: true}, %{name: "note", type: :string}] ++
        extra_fields

    {:ok, _row} =
      Definitions.create_definition(
        %{definition: %{name: name, display_name: name, fields: fields}, created_by: @actor_id},
        schema
      )

    {:ok, active} = Definitions.activate_definition(name, @actor_id, "gh2587", schema)
    active
  end

  defp source(line_key, overrides \\ %{}) do
    Map.merge(
      %{
        kind: "process_step",
        instance_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        node_id: "approve_order",
        definition_id: Ecto.UUID.generate(),
        definition_version: 3,
        line_index: line_key,
        activator_id: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp command(type, line_key, task_id, overrides \\ %{}) do
    Map.merge(
      %{
        kind: :create,
        line_key: line_key,
        entity_type: type,
        field_values: %{"title" => "line #{line_key}"},
        actor_id: @actor_id,
        idempotency_key: "sys:step:#{task_id}:#{line_key}",
        source: source(line_key)
      },
      overrides
    )
  end

  defp build!(command, schema, authority \\ :tenant) do
    assert {:ok, %Multi{} = multi} = Records.command_multi(command, schema, authority)
    multi
  end

  defp names(multi), do: multi |> Multi.to_list() |> Enum.map(&elem(&1, 0))

  defp record_events(schema) do
    Repo.all(
      from(e in Event, where: e.event_type == "ENTITY_RECORD_CREATED", order_by: e.global_seq),
      prefix: schema
    )
  end

  defp event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)
  defp idempotency_count(schema), do: Repo.aggregate(IdempotencyRecord, :count, prefix: schema)
  defp latest_count(schema), do: Repo.aggregate(Latest, :count, prefix: schema)

  defp counts(schema), do: {event_count(schema), idempotency_count(schema), latest_count(schema)}

  defp synthetic_instance!(schema, type) do
    {:ok, id} = EntityTypeInstance.fetch_instance_id(type, schema)
    id
  end

  defp entity_record_created_payload(schema, type) do
    {:ok, definition} = Definitions.get_active_definition_by_name(type, schema)

    Jason.encode!(%{
      "entity_type" => type,
      "entity_def_version" => Base.encode16(definition.logical_shape_version, case: :lower),
      "record_id" => Ecto.UUID.generate(),
      "field_values" => %{"title" => "raw"}
    })
  end

  # ── composition ─────────────────────────────────────────────────────────────────────────────

  describe "command_multi/3: three lines (two on one type) in one transaction" do
    test "commit three records and three events, each carrying the source.* metadata", %{
      schema: schema,
      task_id: task_id
    } do
      commands = [
        command(@type_a, 0, task_id),
        command(@type_b, 1, task_id, %{source: source(1, %{node_id: "n-1"})}),
        command(@type_a, 2, task_id)
      ]

      multis = Enum.map(commands, &build!(&1, schema))

      # No duplicate-name raise: every step is {:line, i, step}.
      combined = Enum.reduce(multis, Multi.new(), &Multi.append(&2, &1))
      all_names = names(combined)
      assert length(all_names) == 3 * length(@line_steps)
      assert Enum.uniq(all_names) == all_names

      for {multi, i} <- Enum.with_index(multis) do
        assert names(multi) == Enum.map(@line_steps, &{:line, i, &1})
      end

      assert {:ok, changes} = Repo.transaction(combined)

      for i <- 0..2 do
        assert %Latest{} = changes[{:line, i, :upsert_record_latest}]
        assert %Event{} = changes[{:line, i, :insert_event}]
      end

      assert latest_count(schema) == 3
      events = record_events(schema)
      assert length(events) == 3

      for {event, i} <- Enum.with_index(events) do
        cmd = Enum.at(commands, i)
        assert event.actor_id == @actor_id
        assert event.idempotency_key == "sys:step:#{task_id}:#{i}"

        assert event.metadata == %{
                 "source.kind" => "process_step",
                 "source.instance_id" => cmd.source.instance_id,
                 "source.task_id" => cmd.source.task_id,
                 "source.node_id" => cmd.source.node_id,
                 "source.definition_id" => cmd.source.definition_id,
                 "source.definition_version" => "3",
                 "source.line_index" => Integer.to_string(i),
                 "source.activator_id" => cmd.source.activator_id
               }
      end

      # Lines 0 and 2 share the type's synthetic instance; line 1 is the other type.
      assert Enum.map(events, & &1.instance_id) == [
               synthetic_instance!(schema, @type_a),
               synthetic_instance!(schema, @type_b),
               synthetic_instance!(schema, @type_a)
             ]
    end

    test "the recheck step returns the same EntityDefinition row the build resolved", %{
      schema: schema,
      task_id: task_id
    } do
      {:ok, %EntityDefinition{id: active_id}} =
        Definitions.get_active_definition_by_name(@type_a, schema)

      assert {:ok, changes} = Repo.transaction(build!(command(@type_a, 0, task_id), schema))
      assert %EntityDefinition{id: ^active_id} = changes[{:line, 0, :recheck_definition}]
    end

    test "a dispatch_id source is recorded as source.dispatch_id", %{schema: schema} do
      dispatch_id = Ecto.UUID.generate()

      src =
        0
        |> source(%{dispatch_id: dispatch_id})
        |> Map.delete(:task_id)

      cmd = command(@type_a, 0, dispatch_id, %{source: src})
      assert {:ok, _} = Repo.transaction(build!(cmd, schema))
      [event] = record_events(schema)
      assert event.metadata["source.dispatch_id"] == dispatch_id
      refute Map.has_key?(event.metadata, "source.task_id")
    end

    test "a >4096-byte payload adds {:line, i, :store_oversized_payload} and commits", %{
      schema: schema,
      task_id: task_id
    } do
      cmd =
        command(@type_b, 4, task_id, %{
          field_values: %{"title" => "big", "note" => String.duplicate("x", 5000)}
        })

      multi = build!(cmd, schema)
      assert {:line, 4, :store_oversized_payload} in names(multi)
      assert {:ok, _} = Repo.transaction(multi)
      assert latest_count(schema) == 1
    end
  end

  # ── build-phase refusals ────────────────────────────────────────────────────────────────────

  describe "command_multi/3 build refusals" do
    test "a type whose synthetic instance was not prepared is refused and never created", %{
      schema: schema,
      task_id: task_id
    } do
      activate!(schema, "cm_gamma", [])
      before = counts(schema)

      assert {:error, {:entity_type_instance_missing, "cm_gamma"}} =
               Records.command_multi(command("cm_gamma", 0, task_id), schema, :tenant)

      assert Repo.get(EntityTypeInstance, "cm_gamma", prefix: schema) == nil
      assert counts(schema) == before
    end

    test ":update and :delete are not supported, with no query", %{
      schema: schema,
      task_id: task_id
    } do
      for kind <- [:update, :delete] do
        {result, queries} =
          PlatformTenantFixture.capture_repo_queries(fn ->
            Records.command_multi(command(@type_a, 0, task_id, %{kind: kind}), schema, :tenant)
          end)

        assert result == {:error, {:command_kind_not_supported, kind}}
        assert queries == []
      end
    end

    test "keys outside the anchored sys:step: charset are :invalid_step_key, with no query", %{
      schema: schema,
      task_id: task_id
    } do
      bad_keys = [
        "certificate:issue:x",
        "sys:step:a b",
        "sys:step:",
        # \z, not $: a trailing newline is refused.
        "sys:step:abc\n",
        # \A: the family must be the head of the key.
        "xsys:step:abc",
        "SYS:STEP:abc",
        "sys:step:" <> String.duplicate("a", 247),
        nil,
        42
      ]

      assert byte_size("sys:step:" <> String.duplicate("a", 247)) == 256

      for key <- bad_keys do
        {result, queries} =
          PlatformTenantFixture.capture_repo_queries(fn ->
            Records.command_multi(
              command(@type_a, 0, task_id, %{idempotency_key: key}),
              schema,
              :tenant
            )
          end)

        assert result == {:error, :invalid_step_key}, inspect(key)
        assert queries == [], inspect(key)
      end

      # Boundary control: exactly 255 bytes and the full charset are accepted.
      ok_key = "sys:step:Az09:_.-" <> String.duplicate("a", 255 - 17)
      assert byte_size(ok_key) == 255

      assert {:ok, _} =
               Records.command_multi(
                 command(@type_a, 0, task_id, %{idempotency_key: ok_key}),
                 schema,
                 :tenant
               )
    end

    test "malformed sources and a line_index that differs from line_key are :invalid_step_source",
         %{schema: schema, task_id: task_id} do
      both = source(0, %{dispatch_id: Ecto.UUID.generate()})
      neither = Map.delete(source(0), :task_id)

      bad = [
        %{source: source(1)},
        %{line_key: -1, source: source(-1)},
        %{source: both},
        %{source: neither},
        %{source: source(0, %{kind: "client"})},
        %{source: source(0, %{instance_id: "not-a-uuid"})},
        %{source: source(0, %{node_id: ""})},
        %{source: source(0, %{node_id: String.duplicate("n", 1025)})},
        %{source: source(0, %{definition_version: 0})},
        %{source: Map.put(source(0), :extra, "x")},
        %{source: "nope"},
        %{actor_id: "not-a-uuid"},
        %{field_values: "nope"}
      ]

      for overrides <- bad do
        {result, queries} =
          PlatformTenantFixture.capture_repo_queries(fn ->
            Records.command_multi(command(@type_a, 0, task_id, overrides), schema, :tenant)
          end)

        assert result == {:error, :invalid_step_source}, inspect(overrides)
        assert queries == [], inspect(overrides)
      end

      assert Records.command_multi(:not_a_map, schema, :tenant) == {:error, :invalid_step_source}
    end

    test "a missing required field is {:record_payload_invalid, _} and nothing is written", %{
      schema: schema,
      task_id: task_id
    } do
      before = counts(schema)
      cmd = command(@type_a, 0, task_id, %{field_values: %{"note" => "no title"}})

      assert {:error, {:record_payload_invalid, _violations}} =
               Records.command_multi(cmd, schema, :tenant)

      assert counts(schema) == before
    end

    test "an authority that is neither :tenant nor an Owner raises FunctionClauseError", %{
      schema: schema,
      task_id: task_id
    } do
      assert_raise FunctionClauseError, fn ->
        apply(Records, :command_multi, [command(@type_a, 0, task_id), schema, "x"])
      end
    end
  end

  describe "command_multi/3 per-line authority (GH #2583 section 8.2)" do
    setup %{schema: schema} do
      {:ok, _tenant_module} =
        Installs.install("fixture_managed", Ecto.UUID.generate(),
          prefix: schema,
          rationale: "GH #2587 command_multi authority test install"
        )

      {:ok, _} = EntityTypeInstance.get_or_create("org_unit", schema)
      {:ok, owner: ManagedTypes.owner_for!(FixtureManaged)}
    end

    test "a managed type with :tenant is :entity_type_managed after exactly the definition query",
         %{schema: schema, task_id: task_id, owner: owner} do
      {:ok, _} = Definitions.get_active_definition_by_name("org_unit", schema)

      {_def, baseline} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Definitions.get_active_definition_by_name("org_unit", schema)
        end)

      assert baseline != []

      cmd = command("org_unit", 0, task_id, %{field_values: %{"name" => "u"}})

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Records.command_multi(cmd, schema, :tenant)
        end)

      assert result == {:error, :entity_type_managed}
      assert Enum.map(queries, & &1.query) == Enum.map(baseline, & &1.query)
      assert Records.classify_step_error(:entity_type_managed) == {:refused, :write_not_permitted}

      # The owning module's Owner writes the same line; an unmanaged line in the same
      # composition is checked against its own (unmanaged) definition.
      owned = build!(cmd, schema, owner)
      free = build!(command(@type_a, 1, task_id), schema, owner)
      assert {:ok, _} = Repo.transaction(Multi.append(owned, free))
    end
  end

  # ── recheck under lock (CDV-4) ──────────────────────────────────────────────────────────────

  describe "{:line, i, :recheck_definition}" do
    test "a new version activated between build and transaction refuses the line, nothing committed",
         %{schema: schema, task_id: task_id} do
      multi = build!(command(@type_a, 0, task_id), schema)
      before = counts(schema)

      activate!(schema, @type_a, [%{name: "extra", type: :string}])

      assert {:error, {:line, 0, :recheck_definition}, {:definition_changed, @type_a}, _} =
               result = Repo.transaction(multi)

      assert Records.interpret_in_multi(result) ==
               {:entity_write_refused, 0, :entity_type_inactive}

      assert counts(schema) == before

      assert Repo.all(from(e in Event, where: e.idempotency_key == ^"sys:step:#{task_id}:0"),
               prefix: schema
             ) == []
    end
  end

  # ── EventStore :step_namespace and the sys:step: refusal (3.1, SEC F3) ──────────────────────

  describe "EventStore.append_multi/3 :step_namespace" do
    test "without the option the step names are today's fixed list", %{schema: schema} do
      attrs = %{
        instance_id: synthetic_instance!(schema, @type_a),
        event_type: "ENTITY_RECORD_CREATED",
        payload: entity_record_created_payload(schema, @type_a),
        actor_id: @actor_id,
        idempotency_key: Ecto.UUID.generate()
      }

      assert {:ok, multi} = EventStore.append_multi(Multi.new(), attrs, prefix: schema)

      assert names(multi) == [
               :active_instance_guard,
               :assign_sequence,
               :idempotency,
               :insert_event,
               :update_projection
             ]

      assert {:ok, ns_multi} =
               EventStore.append_multi(Multi.new(), attrs,
                 prefix: schema,
                 step_namespace: {:line, 7}
               )

      assert names(ns_multi) ==
               Enum.map(
                 [
                   :active_instance_guard,
                   :assign_sequence,
                   :idempotency,
                   :insert_event,
                   :update_projection
                 ],
                 &{:line, 7, &1}
               )
    end

    test "an invalid namespace is refused before any other check, with no query", %{
      schema: schema
    } do
      for ns <- [{:line, -1}, :foo, nil, {:line, 1.0}, {:other, 0}] do
        {result, queries} =
          PlatformTenantFixture.capture_repo_queries(fn ->
            EventStore.append_multi(Multi.new(), %{tenant_id: "x"},
              prefix: schema,
              step_namespace: ns
            )
          end)

        assert result == {:error, :invalid_step_namespace}, inspect(ns)
        assert queries == []
      end
    end

    test "append/2, append_platform_event/2 and un-namespaced append_multi/3 refuse a sys:step: key",
         %{schema: schema} do
      key = Records.step_key_prefix() <> "t:0"
      assert key == "sys:step:t:0"
      before = counts(schema)
      payload = entity_record_created_payload(schema, @type_a)

      attrs = %{
        instance_id: synthetic_instance!(schema, @type_a),
        event_type: "ENTITY_RECORD_CREATED",
        payload: payload,
        actor_id: @actor_id,
        idempotency_key: key
      }

      {results, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          [
            EventStore.append(attrs, prefix: schema),
            EventStore.append_platform_event(
              %{attrs | instance_id: EventStore.platform_instance_id()},
              prefix: schema
            ),
            EventStore.append_multi(Multi.new(), attrs, prefix: schema)
          ]
        end)

      assert results == List.duplicate({:error, :reserved_idempotency_key}, 3)
      assert queries == []
      assert counts(schema) == before

      # Exact bytes: another case is an ordinary key.
      assert {:ok, %{is_duplicate: false}} =
               EventStore.append(%{attrs | idempotency_key: "SYS:STEP:t:0"}, prefix: schema)

      # A namespaced append_multi/3 accepts the key and commits it.
      assert {:ok, multi} =
               EventStore.append_multi(Multi.new(), attrs,
                 prefix: schema,
                 step_namespace: {:line, 0}
               )

      assert {:ok, %{{:line, 0, :insert_event} => %Event{idempotency_key: ^key}}} =
               Repo.transaction(multi)
    end
  end

  # ── interpret_in_multi/1 ────────────────────────────────────────────────────────────────────

  describe "interpret_in_multi/1" do
    test "a re-used committed key is :idempotency_conflict, never success", %{
      schema: schema,
      task_id: task_id
    } do
      cmd = command(@type_a, 0, task_id)
      assert {:ok, _} = Repo.transaction(build!(cmd, schema))
      before = counts(schema)

      result = Repo.transaction(build!(cmd, schema))

      assert {:error, {:line, 0, :idempotency}, {:duplicate_idempotency_key, %Event{}}, _} =
               result

      assert Records.interpret_in_multi(result) ==
               {:entity_write_refused, 0, :idempotency_conflict}

      assert counts(schema) == before
    end

    test "the mapping table" do
      changeset = Ecto.Changeset.change(%Latest{})

      cases = [
        {{:line, 2, :build}, :entity_type_managed,
         {:entity_write_refused, 2, :write_not_permitted}},
        {{:line, 2, :build}, {:definition_not_found, "t"},
         {:entity_write_refused, 2, :entity_type_inactive}},
        {{:line, 3, :build}, :invalid_step_key, {:entity_write_failed, 3, :build}},
        {{:line, 0, :recheck_definition}, {:definition_changed, "t"},
         {:entity_write_refused, 0, :entity_type_inactive}},
        {{:line, 0, :recheck_definition}, :entity_type_managed,
         {:entity_write_refused, 0, :write_not_permitted}},
        {{:line, 0, :idempotency}, {:duplicate_idempotency_key, %Event{}},
         {:entity_write_refused, 0, :idempotency_conflict}},
        {{:line, 5, :check_record_version}, :record_version_conflict,
         {:entity_write_refused, 5, :record_version_conflict}},
        {{:line, 1, :dual_write_promoted_columns}, {:record_payload_invalid, [:v]},
         {:entity_write_refused, 1, :validation_failed}},
        {{:line, 1, :insert_event}, changeset, {:entity_write_failed, 1, :insert_event}},
        {{:line, 1, :idempotency}, {:idempotency_lookup_failed, :sidecar_row_missing},
         {:entity_write_failed, 1, :idempotency}},
        {{:line, 4, :recheck_definition}, :invalid_schema_name,
         {:entity_write_failed, 4, :recheck_definition}},
        {:transition, :whatever, :not_a_line_failure},
        {{:line, -1, :build}, :entity_type_managed, :not_a_line_failure}
      ]

      for {name, reason, expected} <- cases do
        assert Records.interpret_in_multi({:error, name, reason, %{}}) == expected,
               inspect({name, reason})
      end
    end

    test "classify_step_error/1 table" do
      assert Records.classify_step_error({:record_not_found, "r"}) ==
               {:refused, :write_not_permitted}

      assert Records.classify_step_error({:record_already_deleted, "r"}) ==
               {:refused, :write_not_permitted}

      assert Records.classify_step_error({:entity_append_only, "t"}) ==
               {:refused, :entity_append_only}

      assert Records.classify_step_error({:record_payload_invalid, [:v]}) ==
               {:refused, :validation_failed}

      assert Records.classify_step_error(:record_version_conflict) ==
               {:refused, :record_version_conflict}

      assert Records.classify_step_error({:duplicate_idempotency_key, %Event{}}) ==
               {:refused, :idempotency_conflict}

      assert Records.classify_step_error(:idempotency_key_reuse) ==
               {:refused, :idempotency_conflict}

      for internal <- [
            :invalid_step_key,
            :invalid_step_source,
            {:command_kind_not_supported, :update},
            {:entity_type_instance_missing, "t"},
            :invalid_schema_name,
            {:invalid_metadata, :not_a_map},
            {:payload_validation_failed, []}
          ] do
        assert Records.classify_step_error(internal) == :internal, inspect(internal)
      end
    end

    test "property: the result never carries a map or a list (no field values or names)" do
      reasons =
        one_of([
          any_value(),
          tuple({constant(:record_payload_invalid), list_of(any_value())}),
          tuple({constant(:definition_not_found), string(:printable)}),
          tuple({constant(:duplicate_idempotency_key), constant(%Event{payload: %{"f" => "v"}})}),
          member_of([:entity_type_managed, :record_version_conflict, :idempotency_key_reuse])
        ])

      names =
        one_of([
          tuple({constant(:line), integer(0..20), member_of([:build | @line_steps])}),
          any_value()
        ])

      check all(
              name <- names,
              reason <- reasons,
              changes <- map_of(atom(:alphanumeric), any_value())
            ) do
        result = Records.interpret_in_multi({:error, name, reason, changes})
        refute contains_container?(result), inspect(result)
      end
    end
  end

  # Arbitrary nested terms without floats (StreamData 0.6's float generator trips an
  # Elixir 1.20 Range deprecation warning at run time).
  defp any_value do
    scalar =
      one_of([
        atom(:alphanumeric),
        integer(),
        binary(),
        string(:printable),
        boolean(),
        constant(nil)
      ])

    tree(scalar, fn child ->
      one_of([
        list_of(child, max_length: 3),
        map_of(string(:alphanumeric), child, max_length: 3),
        tuple({child, child}),
        tuple({child, child, child})
      ])
    end)
  end

  defp contains_container?(value) when is_map(value) or is_list(value), do: true

  defp contains_container?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&contains_container?/1)

  defp contains_container?(_scalar), do: false
end
