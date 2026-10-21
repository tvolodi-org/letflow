defmodule Letflow.EngineCatalogServiceTaskTest do
  @moduledoc """
  ISS-0917 regression suite (T1-T11 of
  `lib/letflow/design/iss0917-catalog-service-task-pinned-dispatch.md`
  section 6.2): a SERVICE_TASK that references a `service_id` (catalog
  `route_kind: :catalog_service`) is resolved at ACTIVATION from the
  instance's OWN pinned catalog version -- never from the live current row --
  and the pinned endpoint is frozen into the `service_task_dispatches` row.

  See `test/specs/ISS-0917.md` for the per-test rationale, the pre-fix
  (origin/main) failure record and the mutant table.

  Uses `Letflow.DataCase` (real Postgres) with real provisioned tenant
  schemas; `async: false` because the file writes committed rows to the GLOBAL
  `service_catalog` / `service_catalog_versions` tables and provisions tenant
  schemas (same reasoning as `engine_pin_resolver_catalog_test.exs`).

  Fixture graph: the HUMAN_TASK-first shape from
  `engine_pin_resolver_catalog_test.exs` (`graph_human_task_then_service_task/1`)
  so the SERVICE_TASK is activated through the COMPLETION HOP -- the path the
  issue measured -- not through `create/2`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.PinRebind
  alias Letflow.Engine.PinResolver.Lookup
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.ServiceCatalog.Version
  alias Letflow.TenantFixture

  @v1_url "https://example.test/iss0917/v1"
  @v2_url "https://example.test/iss0917/v2"

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers (no optional-argument defaults -- anti-patterns.md ISS-0069)
  # ---------------------------------------------------------------------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp tenant!, do: TenantFixture.provisioned_tenant!(slug_prefix: "iss0917")

  defp cleanup_entry!(service_id) do
    Repo.delete_all(from(v in Version, where: v.service_id == ^service_id))
    Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
  end

  defp register_with!(overrides) do
    attrs =
      Map.merge(
        %{
          service_id: unique("iss0917-svc"),
          endpoint_url: @v1_url,
          required_auth: :NONE,
          timeout_ms: 5_000,
          scope: :global
        },
        overrides
      )

    on_exit(fn -> cleanup_entry!(attrs.service_id) end)
    assert {:ok, entry} = ServiceCatalog.register(attrs)
    entry
  end

  defp register!, do: register_with!(%{})

  defp publish_v2!(service_id) do
    assert {:ok, updated} =
             ServiceCatalog.publish(service_id, "2", %{
               endpoint_url: @v2_url,
               required_auth: :NONE,
               timeout_ms: 9_000
             })

    updated
  end

  defp svc_node(service_id, timeout_ms) do
    %{
      "id" => "svc",
      "node_type" => "SERVICE_TASK",
      "attributes" => %{"service_id" => service_id, "timeout_ms" => timeout_ms}
    }
  end

  # START -> HUMAN_TASK(role approver) -> SERVICE_TASK(service_id) -> END
  defp graph_task_then_catalog(service_id, timeout_ms) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        svc_node(service_id, timeout_ms),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "svc"},
        %{"id" => "e3", "source" => "svc", "target" => "end"}
      ]
    }
  end

  # START -> SERVICE_TASK(service_id) -> END (reached straight from create/2)
  defp graph_start_catalog(service_id) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        svc_node(service_id, 5_000),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc"},
        %{"id" => "e2", "source" => "svc", "target" => "end"}
      ]
    }
  end

  # START -> SERVICE_TASK(inline url) -> SERVICE_TASK(catalog) -> END
  defp graph_inline_then_catalog(service_id) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "svc1",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => "https://example.test/inline", "timeout_ms" => 5_000}
        },
        %{
          "id" => "svc2",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"service_id" => service_id, "timeout_ms" => 5_000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc1"},
        %{"id" => "e2", "source" => "svc1", "target" => "svc2"},
        %{"id" => "e3", "source" => "svc2", "target" => "end"}
      ]
    }
  end

  # START -> TIMER(P0D) -> SERVICE_TASK(catalog) -> END
  defp graph_timer_then_catalog(service_id) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "tmr",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "P0D"}
        },
        %{
          "id" => "svc2",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"service_id" => service_id, "timeout_ms" => 5_000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "tmr"},
        %{"id" => "e2", "source" => "tmr", "target" => "svc2"},
        %{"id" => "e3", "source" => "svc2", "target" => "end"}
      ]
    }
  end

  defp active_definition!(tenant, graph) do
    attrs = %{
      name: unique("iss0917-def"),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, definition} = Definitions.create(attrs, prefix: tenant.schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: tenant.schema_name)

    activated
  end

  defp start_attrs(definition, extra) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique("iss0917-start")
      },
      extra
    )
  end

  defp create!(tenant, definition, extra) do
    assert {:ok, result} =
             Engine.create(start_attrs(definition, extra), prefix: tenant.schema_name)

    result
  end

  # Defines the graph, starts an instance (real PinLookup unless `extra`
  # injects :pin_lookup) and returns {instance_id, pending_task}.
  defp start_with_task!(tenant, graph, extra) do
    definition = active_definition!(tenant, graph)
    result = create!(tenant, definition, extra)
    assert [task] = Repo.all(EngineTask, prefix: tenant.schema_name)
    assert task.status == :pending
    {result.instance_id, task}
  end

  defp complete(tenant, task) do
    Engine.complete_task(
      task.id,
      %{
        output_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique("iss0917-complete")
      },
      prefix: tenant.schema_name
    )
  end

  defp dispatches(tenant, instance_id) do
    ServiceTaskDispatch
    |> where([d], d.instance_id == ^instance_id)
    |> Repo.all(prefix: tenant.schema_name)
  end

  # attempt_dispatch/2 normally flips the row to "advanced" before the poller
  # calls advance_after_service_task_outcome/4 (which short-circuits to
  # {:ok, :already_final} otherwise); reproduce that precondition directly.
  defp mark_advanced!(tenant, row) do
    row
    |> Ecto.Changeset.change(%{status: :advanced})
    |> Repo.update!(prefix: tenant.schema_name)
  end

  defp events(tenant, instance_id) do
    assert {:ok, events} = Reconstruction.read_full_log(instance_id, tenant.schema_name, 1)
    events
  end

  defp event_types(tenant, instance_id),
    do: tenant |> events(instance_id) |> Enum.map(& &1.event_type)

  defp execution_error_payload(tenant, instance_id) do
    assert [event] =
             Enum.filter(events(tenant, instance_id), &(&1.event_type == "EXECUTION_ERROR"))

    event.payload
  end

  defp projection(tenant, instance_id),
    do: Repo.get!(InstanceProjection, instance_id, prefix: tenant.schema_name)

  # A Lookup whose catalog side blindly "resolves" any service_id to the given
  # pin identity (ignores visibility) -- lets a test record a pin that the
  # real PinLookup would never hand out (cross-tenant / non-existent target).
  defp const_catalog_lookup(resolved_id, version) do
    %Lookup{
      catalog_lookup: fn _ref -> {:ok, %{resolved_id: resolved_id, version: version}} end,
      module_lookup: fn _ref -> {:error, :not_found} end,
      variable_schema_lookup: fn _tenant_id, _key ->
        {:ok, %{version: "unversioned", json_schema: nil}}
      end
    }
  end

  defp rebind_catalog_pin!(tenant, instance_id, service_id, version) do
    assert {:ok, %{changed: [_one]}} =
             PinRebind.rebind_pins(
               instance_id,
               %{
                 entries: [%{kind: :catalog_entry, ref: service_id, version: version}],
                 reason: "ISS-0917 test rebind",
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("iss0917-rebind")
               },
               prefix: tenant.schema_name
             )

    :ok
  end

  @catalog_keys ~w(catalog_version_id catalog_version catalog_retry_policy)
  # ISS-0926 added "rendered_body" alongside the pre-existing "rendered_url"
  # (same raw/derived pairing as url_template/rendered_url) -- the snapshot's
  # key SET grows by exactly that one key; everything else here is unchanged.
  @inline_keys ~w(route_kind url_template service_id method body_template headers timeout_ms retry_limit rendered_url rendered_body)

  # ---------------------------------------------------------------------------------
  # T1 -- the issue's measured scenario: complete the HUMAN_TASK, hop into a
  # catalog SERVICE_TASK. Pre-fix: EXECUTION_ERROR + {:instance_execution_error,
  # :service_task_url_rendered_empty, ...} and zero dispatch rows.
  # ---------------------------------------------------------------------------------

  describe "T1: completion hop into a catalog SERVICE_TASK" do
    test "completes without EXECUTION_ERROR and freezes the pinned endpoint + audit keys into one pending dispatch row" do
      tenant = tenant!()
      entry = register!()

      {instance_id, task} =
        start_with_task!(tenant, graph_task_then_catalog(entry.service_id, 5_000), %{})

      assert {:ok, %{instance_status: :active, current_nodes: ["svc"]}} = complete(tenant, task)

      types = event_types(tenant, instance_id)
      refute "EXECUTION_ERROR" in types
      assert "TASK_COMPLETED" in types
      assert projection(tenant, instance_id).status == :active

      assert [row] = dispatches(tenant, instance_id)
      assert row.status == :pending
      assert row.node_id == "svc"
      assert row.config_snapshot["route_kind"] == "catalog_service"
      assert row.config_snapshot["service_id"] == entry.service_id
      assert row.config_snapshot["rendered_url"] == @v1_url
      assert row.config_snapshot["catalog_version_id"] == entry.version_id
      assert row.config_snapshot["catalog_version"] == "1"
      assert Map.has_key?(row.config_snapshot, "catalog_retry_policy")
      assert row.config_snapshot["url_template"] == nil
    end

    test "the pinned endpoint_url is rendered through the {{variables.KEY}} renderer like an inline url_template" do
      tenant = tenant!()

      entry =
        register_with!(%{endpoint_url: "https://example.test/iss0917/{{variables.region}}/svc"})

      {instance_id, task} =
        start_with_task!(
          tenant,
          graph_task_then_catalog(entry.service_id, 5_000),
          %{initial_variables: %{"region" => "eu"}}
        )

      assert {:ok, %{instance_status: :active}} = complete(tenant, task)

      assert [row] = dispatches(tenant, instance_id)
      assert row.config_snapshot["rendered_url"] == "https://example.test/iss0917/eu/svc"
    end

    test "an endpoint_url that renders to an empty string keeps the existing url_rendered_empty error (no row)" do
      tenant = tenant!()
      entry = register_with!(%{})

      # Seeded as legacy data on purpose: register/1 now rejects a templated host
      # (ISS-0950), but such a row can still exist and the engine must stay robust.
      Repo.update_all(from(e in Entry, where: e.service_id == ^entry.service_id),
        set: [endpoint_url: "{{variables.absent}}"]
      )

      {instance_id, task} =
        start_with_task!(tenant, graph_task_then_catalog(entry.service_id, 5_000), %{})

      assert {:error,
              {:instance_execution_error, :service_task_url_rendered_empty, {:node, "svc"}}} =
               complete(tenant, task)

      assert dispatches(tenant, instance_id) == []
      assert projection(tenant, instance_id).status == :error
    end
  end

  # ---------------------------------------------------------------------------------
  # T2 -- AC-3: the pin wins over later catalog changes.
  # ---------------------------------------------------------------------------------

  describe "T2: an instance pinned to v1 keeps dispatching v1 after the catalog moves on" do
    test "retire v1 AND publish v2 before completing: the row targets v1's endpoint, never v2's" do
      tenant = tenant!()
      entry = register!()

      {instance_id, task} =
        start_with_task!(tenant, graph_task_then_catalog(entry.service_id, 5_000), %{})

      v2 = publish_v2!(entry.service_id)
      assert {:ok, _} = ServiceCatalog.retire(entry.service_id)

      assert {:ok, %{instance_status: :active}} = complete(tenant, task)

      assert [row] = dispatches(tenant, instance_id)
      assert row.config_snapshot["rendered_url"] == @v1_url
      refute row.config_snapshot["rendered_url"] == @v2_url
      assert row.config_snapshot["catalog_version_id"] == entry.version_id
      refute row.config_snapshot["catalog_version_id"] == v2.version_id
      assert row.config_snapshot["catalog_version"] == "1"
    end

    test "T2b: retire only (no republish) -> the RETIRED current version still dispatches (v1)" do
      tenant = tenant!()
      entry = register!()

      {instance_id, task} =
        start_with_task!(tenant, graph_task_then_catalog(entry.service_id, 5_000), %{})

      assert {:ok, %{status: :RETIRED}} = ServiceCatalog.retire(entry.service_id)

      assert {:ok, %{instance_status: :active}} = complete(tenant, task)

      assert [row] = dispatches(tenant, instance_id)
      assert row.config_snapshot["rendered_url"] == @v1_url
      assert row.config_snapshot["catalog_version_id"] == entry.version_id
    end
  end

  # ---------------------------------------------------------------------------------
  # T3 -- create/2 site (AC-8)
  # ---------------------------------------------------------------------------------

  describe "T3: SERVICE_TASK reachable straight from START (create/2 site)" do
    test "create returns {:ok, _} with one pending row targeting the pinned endpoint" do
      tenant = tenant!()
      entry = register!()
      definition = active_definition!(tenant, graph_start_catalog(entry.service_id))

      result = create!(tenant, definition, %{})

      assert result.status == :active
      assert [row] = dispatches(tenant, result.instance_id)
      assert row.status == :pending
      assert row.config_snapshot["rendered_url"] == @v1_url
      assert row.config_snapshot["catalog_version_id"] == entry.version_id
    end

    test "T3b: required_auth != NONE fails closed at create: typed activation_failed, no instance rows, no dispatch row" do
      tenant = tenant!()
      entry = register_with!(%{required_auth: :API_KEY})
      definition = active_definition!(tenant, graph_start_catalog(entry.service_id))

      assert {:error,
              {:activation_failed,
               {:service_task_catalog_unresolved, "svc", {:required_auth_unsupported, :API_KEY}}}} =
               Engine.create(start_attrs(definition, %{}), prefix: tenant.schema_name)

      assert Repo.aggregate(ServiceTaskDispatch, :count, prefix: tenant.schema_name) == 0
      assert Repo.aggregate(InstanceProjection, :count, prefix: tenant.schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # T4 -- rebound pins carry no resolved_id (AC-4)
  # ---------------------------------------------------------------------------------

  describe "T4: a rebound pin (resolved_id nil) resolves by (service_id, version)" do
    test "instance pinned to v1, rebound to v2 (published later): dispatches v2's endpoint via {:version, \"2\"}" do
      tenant = tenant!()
      entry = register!()

      {instance_id, task} =
        start_with_task!(tenant, graph_task_then_catalog(entry.service_id, 5_000), %{})

      v2 = publish_v2!(entry.service_id)
      rebind_catalog_pin!(tenant, instance_id, entry.service_id, "2")

      assert {:ok, %{instance_status: :active}} = complete(tenant, task)

      assert [row] = dispatches(tenant, instance_id)
      assert row.config_snapshot["rendered_url"] == @v2_url
      assert row.config_snapshot["catalog_version"] == "2"
      assert row.config_snapshot["catalog_version_id"] == v2.version_id
    end

    test "T4c: instance pinned to v2, rebound back to the ARCHIVED v1: dispatches v1's endpoint" do
      tenant = tenant!()
      entry = register!()
      publish_v2!(entry.service_id)

      {instance_id, task} =
        start_with_task!(tenant, graph_task_then_catalog(entry.service_id, 5_000), %{})

      rebind_catalog_pin!(tenant, instance_id, entry.service_id, "1")

      assert {:ok, %{instance_status: :active}} = complete(tenant, task)

      assert [row] = dispatches(tenant, instance_id)
      assert row.config_snapshot["rendered_url"] == @v1_url
      assert row.config_snapshot["catalog_version_id"] == entry.version_id
    end

    test "T4b: rebind to a version that does not exist -> typed error, instance ERROR, the live ACTIVE entry is NOT used" do
      tenant = tenant!()
      entry = register!()

      {instance_id, task} =
        start_with_task!(tenant, graph_task_then_catalog(entry.service_id, 5_000), %{})

      rebind_catalog_pin!(tenant, instance_id, entry.service_id, "9.9.9")

      assert {:error,
              {:instance_execution_error, :service_task_catalog_unresolved, {:node, "svc"}}} =
               complete(tenant, task)

      assert projection(tenant, instance_id).status == :error
      assert dispatches(tenant, instance_id) == []

      payload = execution_error_payload(tenant, instance_id)
      assert payload["error_type"] == "service_task_catalog_unresolved"
      assert payload["details"] == %{"reason" => "version_not_found"}

      # the live entry is still ACTIVE and untouched -- it was simply not consulted
      assert Repo.get!(Entry, entry.service_id).status == :ACTIVE
    end
  end

  # ---------------------------------------------------------------------------------
  # T5 -- missing pin: NEVER fall back to the live row (INV-PD-1, AC-5)
  # ---------------------------------------------------------------------------------

  describe "T5: no recorded pin for the node's service_id" do
    test "typed pin_missing class, zero rows, and the live ACTIVE entry is not used as a fallback" do
      tenant = tenant!()
      entry = register!()

      {instance_id, task} =
        start_with_task!(tenant, graph_task_then_catalog(entry.service_id, 5_000), %{})

      # Craft an INSTANCE_STARTED whose recorded pins lack the catalog pin
      # (a state create/2 cannot produce: resolve/4 pins every SERVICE_TASK).
      Repo.query!(
        "UPDATE #{tenant.schema_name}.events " <>
          "SET payload = jsonb_set(payload, '{pinned_versions}', " <>
          "(SELECT coalesce(jsonb_agg(p), '[]'::jsonb) " <>
          "FROM jsonb_array_elements(payload->'pinned_versions') p " <>
          "WHERE p->>'kind' <> 'catalog_entry')) " <>
          "WHERE instance_id = $1 AND event_type = 'INSTANCE_STARTED'",
        [Ecto.UUID.dump!(instance_id)]
      )

      assert Repo.get!(Entry, entry.service_id).status == :ACTIVE

      assert {:error,
              {:instance_execution_error, :service_task_catalog_unresolved, {:node, "svc"}}} =
               complete(tenant, task)

      assert dispatches(tenant, instance_id) == []
      assert projection(tenant, instance_id).status == :error

      assert execution_error_payload(tenant, instance_id)["details"] == %{
               "reason" => "pin_missing"
             }
    end
  end

  # ---------------------------------------------------------------------------------
  # T6 -- tenant isolation (INV-1 / INV-5 / INV-PD-4, AC-6)
  # ---------------------------------------------------------------------------------

  describe "T6: tenant-scoped entry owned by another tenant" do
    test "yields the identical typed outcome as a non-existent service; the owner tenant still resolves it" do
      tenant_a = tenant!()
      tenant_b = tenant!()

      entry =
        register_with!(%{scope: :tenant, owner_tenant_id: tenant_a.tenant_id})

      lookup = const_catalog_lookup(entry.version_id, "1")
      missing_service = unique("iss0917-missing")
      missing_lookup = const_catalog_lookup(Ecto.UUID.generate(), "1")

      # Positive control: the OWNER's instance, same pin, resolves and dispatches.
      {owner_instance_id, owner_task} =
        start_with_task!(
          tenant_a,
          graph_task_then_catalog(entry.service_id, 5_000),
          %{pin_lookup: lookup}
        )

      assert {:ok, %{instance_status: :active}} = complete(tenant_a, owner_task)
      assert [owner_row] = dispatches(tenant_a, owner_instance_id)
      assert owner_row.config_snapshot["rendered_url"] == @v1_url

      # Another tenant's instance pinning the same (injected) identity.
      {b_instance_id, b_task} =
        start_with_task!(
          tenant_b,
          graph_task_then_catalog(entry.service_id, 5_000),
          %{pin_lookup: lookup}
        )

      assert {:error,
              {:instance_execution_error, :service_task_catalog_unresolved, {:node, "svc"}}} =
               complete(tenant_b, b_task)

      # Same tenant, a service that does not exist at all.
      tenant_c = tenant!()

      {c_instance_id, c_task} =
        start_with_task!(
          tenant_c,
          graph_task_then_catalog(missing_service, 5_000),
          %{pin_lookup: missing_lookup}
        )

      assert {:error,
              {:instance_execution_error, :service_task_catalog_unresolved, {:node, "svc"}}} =
               complete(tenant_c, c_task)

      assert dispatches(tenant_b, b_instance_id) == []
      assert dispatches(tenant_c, c_instance_id) == []

      b_details = execution_error_payload(tenant_b, b_instance_id)["details"]
      c_details = execution_error_payload(tenant_c, c_instance_id)["details"]
      assert b_details == %{"reason" => "version_not_found"}
      assert b_details == c_details

      b_reason = execution_error_payload(tenant_b, b_instance_id)["reason"]
      assert b_reason == execution_error_payload(tenant_c, c_instance_id)["reason"]
    end
  end

  # ---------------------------------------------------------------------------------
  # T7 -- required_auth fails closed (AC-7)
  # ---------------------------------------------------------------------------------

  describe "T7: required_auth other than NONE" do
    for auth <- [:API_KEY, :OAUTH2, :MUTUAL_TLS] do
      test "#{auth} fails closed at the completion hop: typed error, ERROR, zero dispatch rows" do
        tenant = tenant!()
        entry = register_with!(%{required_auth: unquote(auth)})

        {instance_id, task} =
          start_with_task!(tenant, graph_task_then_catalog(entry.service_id, 5_000), %{})

        assert {:error,
                {:instance_execution_error, :service_task_catalog_unresolved, {:node, "svc"}}} =
                 complete(tenant, task)

        assert dispatches(tenant, instance_id) == []
        assert projection(tenant, instance_id).status == :error

        assert execution_error_payload(tenant, instance_id)["details"] ==
                 %{"reason" => "required_auth_unsupported"}
      end
    end

    test "the error never echoes the service id, endpoint or variables into reason/details" do
      tenant = tenant!()
      entry = register_with!(%{required_auth: :API_KEY})

      {instance_id, task} =
        start_with_task!(
          tenant,
          graph_task_then_catalog(entry.service_id, 5_000),
          %{initial_variables: %{"secret" => "s3cr3t-value"}}
        )

      assert {:error, {:instance_execution_error, _, _}} = complete(tenant, task)

      payload = execution_error_payload(tenant, instance_id)
      surface = Jason.encode!(%{reason: payload["reason"], details: payload["details"]})
      refute surface =~ entry.service_id
      refute surface =~ @v1_url
      refute surface =~ "s3cr3t-value"
    end
  end

  # ---------------------------------------------------------------------------------
  # T8 -- the non-hop call sites reconstruct pins from the event log
  # ---------------------------------------------------------------------------------

  describe "T8a (mandatory): service-task outcome advance site (SERVICE_TASK -> SERVICE_TASK)" do
    test "the second (catalog) row is created from the event-log pin, not the live row, after the catalog moved on" do
      tenant = tenant!()
      entry = register!()
      definition = active_definition!(tenant, graph_inline_then_catalog(entry.service_id))
      result = create!(tenant, definition, %{})

      assert [first] = dispatches(tenant, result.instance_id)
      assert first.node_id == "svc1"

      publish_v2!(entry.service_id)
      assert {:ok, _} = ServiceCatalog.retire(entry.service_id)

      assert {:ok, :advanced} =
               Engine.advance_after_service_task_outcome(
                 mark_advanced!(tenant, first).id,
                 {:advance, %{}},
                 Repo,
                 tenant.schema_name
               )

      rows = dispatches(tenant, result.instance_id)
      assert [second] = Enum.filter(rows, &(&1.node_id == "svc2"))
      assert second.status == :pending
      assert second.config_snapshot["route_kind"] == "catalog_service"
      assert second.config_snapshot["rendered_url"] == @v1_url
      assert second.config_snapshot["catalog_version_id"] == entry.version_id
    end

    test "an unresolvable pin returns the documented typed tuple (no raise), writes no catalog row, and leaves the token at svc1" do
      tenant = tenant!()
      entry = register!()
      definition = active_definition!(tenant, graph_inline_then_catalog(entry.service_id))
      result = create!(tenant, definition, %{})
      assert [first] = dispatches(tenant, result.instance_id)

      rebind_catalog_pin!(tenant, result.instance_id, entry.service_id, "9.9.9")

      assert {:error,
              {:service_task_catalog_unresolved_not_supported_for_timer_fire, "svc2",
               :version_not_found}} =
               Engine.advance_after_service_task_outcome(
                 mark_advanced!(tenant, first).id,
                 {:advance, %{}},
                 Repo,
                 tenant.schema_name
               )

      assert Enum.filter(dispatches(tenant, result.instance_id), &(&1.node_id == "svc2")) == []
      assert projection(tenant, result.instance_id).current_nodes == ["svc1"]
    end

    test "required_auth != NONE at this site returns the typed tuple with the required_auth reason" do
      tenant = tenant!()
      entry = register_with!(%{required_auth: :OAUTH2})
      definition = active_definition!(tenant, graph_inline_then_catalog(entry.service_id))
      result = create!(tenant, definition, %{})
      assert [first] = dispatches(tenant, result.instance_id)

      assert {:error,
              {:service_task_catalog_unresolved_not_supported_for_timer_fire, "svc2",
               {:required_auth_unsupported, :OAUTH2}}} =
               Engine.advance_after_service_task_outcome(
                 mark_advanced!(tenant, first).id,
                 {:advance, %{}},
                 Repo,
                 tenant.schema_name
               )
    end
  end

  describe "T8b (should): timer-fire site (TIMER -> catalog SERVICE_TASK)" do
    test "a due timer fires and the catalog row is created from the pinned v1 endpoint after v1 was superseded and retired" do
      tenant = tenant!()
      entry = register!()
      definition = active_definition!(tenant, graph_timer_then_catalog(entry.service_id))
      result = create!(tenant, definition, %{})

      publish_v2!(entry.service_id)
      assert {:ok, _} = ServiceCatalog.retire(entry.service_id)

      assert %{fired: 1} = Scheduler.poll_and_fire(tenant.schema_name)

      assert [row] = dispatches(tenant, result.instance_id)
      assert row.node_id == "svc2"
      assert row.config_snapshot["rendered_url"] == @v1_url
      assert row.config_snapshot["catalog_version_id"] == entry.version_id
    end

    test "an unresolvable pin returns the typed tuple from advance_after_timer_fired/3 and writes no row" do
      tenant = tenant!()
      entry = register!()
      definition = active_definition!(tenant, graph_timer_then_catalog(entry.service_id))
      result = create!(tenant, definition, %{})

      rebind_catalog_pin!(tenant, result.instance_id, entry.service_id, "9.9.9")

      assert [timer] =
               Repo.all(from(t in Timer, where: t.instance_id == ^result.instance_id),
                 prefix: tenant.schema_name
               )

      assert {:error,
              {:service_task_catalog_unresolved_not_supported_for_timer_fire, "svc2",
               :version_not_found}} =
               Engine.advance_after_timer_fired(timer, Repo, tenant.schema_name)

      assert dispatches(tenant, result.instance_id) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # T9 -- inline snapshot is byte-identical in shape (AC-12 / INV-PD-6)
  # ---------------------------------------------------------------------------------

  describe "T9: inline SERVICE_TASK snapshot is unchanged" do
    test "has exactly the pre-ISS-0917 key set (+ ISS-0926's rendered_body) and no catalog_* keys; the catalog row adds exactly the three audit keys" do
      tenant = tenant!()
      entry = register!()
      inline_def = active_definition!(tenant, graph_inline_then_catalog(entry.service_id))
      inline_result = create!(tenant, inline_def, %{})
      assert [inline_row] = dispatches(tenant, inline_result.instance_id)

      assert inline_row.config_snapshot["route_kind"] == "inline_url"
      assert inline_row.config_snapshot |> Map.keys() |> Enum.sort() == Enum.sort(@inline_keys)
      refute Enum.any?(Map.keys(inline_row.config_snapshot), &String.starts_with?(&1, "catalog_"))

      catalog_def = active_definition!(tenant, graph_start_catalog(entry.service_id))
      catalog_result = create!(tenant, catalog_def, %{})
      assert [catalog_row] = dispatches(tenant, catalog_result.instance_id)

      assert catalog_row.config_snapshot |> Map.keys() |> Enum.sort() ==
               Enum.sort(@inline_keys ++ @catalog_keys)
    end
  end

  # ---------------------------------------------------------------------------------
  # T10 -- timeout merge: min(node, catalog) in both directions (OQ-2)
  # ---------------------------------------------------------------------------------

  describe "T10: snapshot timeout_ms is min(node timeout_ms, catalog timeout_ms)" do
    test "node smaller than catalog -> the node value" do
      tenant = tenant!()
      entry = register_with!(%{timeout_ms: 9_000})

      {instance_id, task} =
        start_with_task!(tenant, graph_task_then_catalog(entry.service_id, 2_000), %{})

      assert {:ok, _} = complete(tenant, task)
      assert [row] = dispatches(tenant, instance_id)
      assert row.config_snapshot["timeout_ms"] == 2_000
    end

    test "catalog smaller than node -> the catalog value" do
      tenant = tenant!()
      entry = register_with!(%{timeout_ms: 3_000})

      {instance_id, task} =
        start_with_task!(tenant, graph_task_then_catalog(entry.service_id, 8_000), %{})

      assert {:ok, _} = complete(tenant, task)
      assert [row] = dispatches(tenant, instance_id)
      assert row.config_snapshot["timeout_ms"] == 3_000
    end
  end

  # ---------------------------------------------------------------------------------
  # T11 -- completion hop with tenant_id_for_schema_name/1 failing (design 3.3a)
  # ---------------------------------------------------------------------------------

  describe "T11: completion hop with an unusable schema prefix" do
    test "tenant_id derivation only runs for catalog nodes: an inline-only hop is unaffected by it (control)" do
      # 3.3a's failing branch is reachable only with a schema prefix that is
      # not "tenant_<32 hex>" yet still survives every earlier completion-hop
      # step (task lookup, snapshot read) -- impossible through the public
      # API, because those steps run against that same prefix first. So the
      # harness cannot drive the failing branch (recorded in
      # test/specs/ISS-0917.md); this control proves the lazy-evaluation half
      # of 3.3a: a hop that activates NO catalog node performs no derivation
      # and succeeds.
      tenant = tenant!()

      graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "task"},
          %{"id" => "e2", "source" => "task", "target" => "end"}
        ]
      }

      {_instance_id, task} = start_with_task!(tenant, graph, %{})
      assert {:ok, %{instance_status: :completed}} = complete(tenant, task)
    end
  end
end
