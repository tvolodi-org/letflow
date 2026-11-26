defmodule Letflow.ServiceCatalogTest do
  @moduledoc """
  Tests for REQ-191 -- `Letflow.ServiceCatalog` (context module), its
  `Entry` schema, and the `service_catalog` migration. See
  `test/specs/REQ-191.md` for the full acceptance-criterion -> test-case
  mapping and rationale. Design authority:
  `lib/letflow/design/req191-service-catalog-core.md`. Implementation
  authority: `lib/letflow/service_catalog.ex` /
  `lib/letflow/service_catalog/entry.ex` / the
  `20260830000001_create_service_catalog.exs` migration, all of which already
  passed SECURITY-REVIEWER and REVIEWER.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file. `service_catalog` is a GLOBAL table (no tenant
  schema, no `:prefix`), so most tests here need only a lightweight
  `Letflow.Identity.Tenant` row (`insert_tenant!/1`, no schema provisioning)
  to satisfy `owner_tenant_id`'s foreign key. The referential-guard tests
  (AC6/AC7) and the `ServiceScopeValidator` integration test (AC8) need a
  *real provisioned tenant schema* with a real `process_definitions` row,
  since `Letflow.ServiceCatalog`'s referential guard walks
  `Letflow.TenantProvisioning.list_registrations/0` and queries each tenant
  schema's own `process_definitions` table -- those use
  `Letflow.TenantFixture.provisioned_tenant!/1`.

  `async: false`: real, committed (non-sandboxed-transaction) schema
  creation/teardown for the provisioned-tenant tests, and
  `Letflow.TenantProvisioning.list_registrations/0` reads real, uncommitted-
  by-us global state -- both need serialization against every other
  `async: false` file in this suite, mirroring `dlq_test.exs` /
  `engine_complete_task_test.exs`'s own established pattern.

  Every `service_catalog` row this file creates is deleted in `on_exit/1` --
  `service_id` is this table's PK and globally unique, so a leftover row from
  a failed test run could otherwise collide with a later run's fixture.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Api.Pagination
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ServiceScopeValidator
  alias Letflow.Identity.Tenant
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.ServiceCatalog.Version
  alias Letflow.TenantFixture

  # `service_catalog` is a GLOBAL table -- unlike the tenant-schema-scoped
  # data most other DataCase tests write, its rows are never cleaned up by a
  # `DROP SCHEMA ... CASCADE`, so every test needs real, explicit cleanup.
  # `on_exit/1` callbacks run in a process distinct from the test process and
  # cannot use a `:manual`/`{:shared, pid}` sandboxed connection once that
  # test process has exited (`Ecto.Adapters.SQL.Sandbox`'s "owner exited"
  # failure) -- exactly the reason `Letflow.TenantFixture.provisioned_tenant!/1`
  # itself switches to `:auto` mode before doing anything it must later clean
  # up in `on_exit/1`. This file follows the same discipline for every test,
  # not only the ones that provision a tenant schema.
  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp unique_service_id(prefix \\ "req191-svc") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # Lightweight tenant: no schema provisioning, just a real `tenants` row so
  # `owner_tenant_id`'s FK is satisfiable. Used by every test that does not
  # need the referential guard (which walks real tenant schemas).
  defp insert_tenant!(slug_prefix \\ "req191-svc-tenant") do
    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug(slug_prefix),
          display_name: "REQ-191 ServiceCatalog Test Tenant"
        },
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn -> Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id)) end)

    tenant
  end

  defp cleanup_entry!(service_id) do
    Repo.delete_all(from(v in Version, where: v.service_id == ^service_id))
    Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
  end

  defp register_attrs(overrides) do
    %{
      service_id: unique_service_id(),
      endpoint_url: "https://example.test/svc",
      required_auth: :NONE,
      timeout_ms: 5_000,
      scope: :global
    }
    |> Map.merge(overrides)
  end

  defp register!(overrides) do
    attrs = register_attrs(overrides)
    on_exit(fn -> cleanup_entry!(attrs.service_id) end)
    assert {:ok, entry} = ServiceCatalog.register(attrs)
    entry
  end

  # A real, provisioned tenant schema (`TenantFixture.provisioned_tenant!/1`)
  # -- needed only by tests exercising the referential guard or the
  # ServiceScopeValidator integration, since both walk real
  # `process_definitions` rows in real tenant schemas.
  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-191 ServiceCatalog Provisioned Tenant"
    )
  end

  defp service_task_node(id, service_id) do
    %{"id" => id, "node_type" => "SERVICE_TASK", "attributes" => %{"service_id" => service_id}}
  end

  # A node that is NOT a SERVICE_TASK, whose attributes string-contain
  # `service_id` as a plain substring -- proves the referential guard's
  # structural (node_type, attribute-key) match, not a LIKE/substring scan.
  defp unrelated_substring_node(id, needle) do
    %{
      "id" => id,
      "node_type" => "HUMAN_TASK",
      "attributes" => %{"description" => "internal note mentioning #{needle} in passing"}
    }
  end

  defp insert_active_definition!(schema_name, nodes, name_prefix \\ "req191-def") do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(
      "process_definitions",
      [
        %{
          id: Ecto.UUID.dump!(id),
          name: name_prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic])),
          version: "1.0.0",
          status: "active",
          graph: %{"nodes" => nodes, "edges" => []},
          created_by: Ecto.UUID.dump!(Ecto.UUID.generate()),
          sequence_number: 0,
          created_at: now,
          updated_at: now
        }
      ],
      prefix: schema_name
    )

    id
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- scope/owner_tenant_id consistency CHECK, enforced at the DATABASE
  # level (raw SQL, deliberately bypassing Entry.insert_changeset/2 and its
  # check_constraint/3 mapping entirely, so a passing test can only mean the
  # database itself rejects the row -- not that the changeset does).
  # ---------------------------------------------------------------------------------

  describe "AC1: scope/owner_tenant_id consistency is a DATABASE-level CHECK" do
    test "scope = 'global' with a non-null owner_tenant_id is rejected by the database" do
      tenant = insert_tenant!()
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO service_catalog " <>
                   "(service_id, endpoint_url, required_auth, timeout_ms, scope, owner_tenant_id, created_at, updated_at, published_at) " <>
                   "VALUES ($1, 'https://example.test', 'NONE', 5000, 'global', $2, now(), now(), now())",
                 [service_id, Ecto.UUID.dump!(tenant.id)]
               )

      refute Repo.get(Entry, service_id)
    end

    test "scope = 'tenant' with a null owner_tenant_id is rejected by the database" do
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO service_catalog " <>
                   "(service_id, endpoint_url, required_auth, timeout_ms, scope, owner_tenant_id, created_at, updated_at, published_at) " <>
                   "VALUES ($1, 'https://example.test', 'NONE', 5000, 'tenant', NULL, now(), now(), now())",
                 [service_id]
               )

      refute Repo.get(Entry, service_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- required_auth / timeout_ms are DATABASE-level CHECKs
  # ---------------------------------------------------------------------------------

  describe "AC2: required_auth and timeout_ms are DATABASE-level CHECKs" do
    test "required_auth = 'BASIC' is rejected by the database" do
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO service_catalog " <>
                   "(service_id, endpoint_url, required_auth, timeout_ms, scope, owner_tenant_id, created_at, updated_at, published_at) " <>
                   "VALUES ($1, 'https://example.test', 'BASIC', 5000, 'global', NULL, now(), now(), now())",
                 [service_id]
               )

      refute Repo.get(Entry, service_id)
    end

    test "timeout_ms = 0 is rejected by the database" do
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO service_catalog " <>
                   "(service_id, endpoint_url, required_auth, timeout_ms, scope, owner_tenant_id, created_at, updated_at, published_at) " <>
                   "VALUES ($1, 'https://example.test', 'NONE', 0, 'global', NULL, now(), now(), now())",
                 [service_id]
               )

      refute Repo.get(Entry, service_id)
    end

    test "timeout_ms = 3_600_001 is rejected by the database" do
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO service_catalog " <>
                   "(service_id, endpoint_url, required_auth, timeout_ms, scope, owner_tenant_id, created_at, updated_at, published_at) " <>
                   "VALUES ($1, 'https://example.test', 'NONE', 3600001, 'global', NULL, now(), now(), now())",
                 [service_id]
               )

      refute Repo.get(Entry, service_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- get_for_tenant/2's three-way visibility rule. Per REVIEWER's own
  # note on the handoff: this predicate is now the SOLE tenant-isolation
  # mechanism for this data (no physical schema separation backstops it), so
  # this is treated as load-bearing, not an ordinary business-rule check.
  # ---------------------------------------------------------------------------------

  describe "AC3: get_for_tenant/2 three-way visibility" do
    test "a global service is visible to any tenant" do
      entry = register!(%{scope: :global})
      requester = insert_tenant!()

      assert {:ok, %Entry{service_id: service_id}} =
               ServiceCatalog.get_for_tenant(entry.service_id, requester.id)

      assert service_id == entry.service_id
    end

    test "a tenant-scoped service is visible to its owner" do
      owner = insert_tenant!()
      entry = register!(%{scope: :tenant, owner_tenant_id: owner.id})

      assert {:ok, %Entry{service_id: service_id}} =
               ServiceCatalog.get_for_tenant(entry.service_id, owner.id)

      assert service_id == entry.service_id
    end

    test "a tenant-scoped service owned by a different tenant is NOT_FOUND, not forbidden" do
      owner = insert_tenant!()
      other = insert_tenant!()
      entry = register!(%{scope: :tenant, owner_tenant_id: owner.id})

      assert {:error, :not_found} = ServiceCatalog.get_for_tenant(entry.service_id, other.id)
    end

    test "a real-but-invisible service and a genuinely missing service produce the identical error shape" do
      owner = insert_tenant!()
      other = insert_tenant!()
      entry = register!(%{scope: :tenant, owner_tenant_id: owner.id})

      invisible_result = ServiceCatalog.get_for_tenant(entry.service_id, other.id)

      missing_result =
        ServiceCatalog.get_for_tenant(unique_service_id("req191-nonexistent"), other.id)

      assert invisible_result == {:error, :not_found}
      assert missing_result == {:error, :not_found}
      # Not merely equal atoms -- the exact same tuple shape, no extra metadata
      # anywhere that could let a caller tell the two cases apart.
      assert invisible_result == missing_result
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- service_id is globally unique across all tenants and both scopes
  # ---------------------------------------------------------------------------------

  describe "AC4: service_id is globally unique" do
    test "registering the same service_id for a second, different tenant fails, even when the first is tenant-scoped" do
      tenant_a = insert_tenant!()
      tenant_b = insert_tenant!()
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)

      assert {:ok, first} =
               ServiceCatalog.register(
                 register_attrs(%{
                   service_id: service_id,
                   scope: :tenant,
                   owner_tenant_id: tenant_a.id
                 })
               )

      assert {:error, :duplicate_service_id} =
               ServiceCatalog.register(
                 register_attrs(%{
                   service_id: service_id,
                   scope: :tenant,
                   owner_tenant_id: tenant_b.id
                 })
               )

      # The original row is untouched -- no silent overwrite.
      assert {:ok, reloaded} = ServiceCatalog.get_for_tenant(service_id, tenant_a.id)
      assert reloaded.owner_tenant_id == first.owner_tenant_id
      assert reloaded.owner_tenant_id == tenant_a.id
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- register/1 with scope: :tenant naming a non-existent tenant
  # ---------------------------------------------------------------------------------

  describe "AC5: register/1 rejects a non-existent tenant, no row created" do
    test "returns {:error, :tenant_not_found} and creates no row" do
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)
      nonexistent_tenant_id = Ecto.UUID.generate()

      assert {:error, :tenant_not_found} =
               ServiceCatalog.register(
                 register_attrs(%{
                   service_id: service_id,
                   scope: :tenant,
                   owner_tenant_id: nonexistent_tenant_id
                 })
               )

      refute Repo.get(Entry, service_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- delete/1's referential guard, structural not substring
  # ---------------------------------------------------------------------------------

  describe "AC6: delete/1 referential guard" do
    test "delete of a service referenced by an ACTIVE definition is refused, naming the referencing definition id" do
      %{schema_name: schema_name} = provisioned_tenant("req191-del-ref")
      entry = register!(%{scope: :global})

      definition_id =
        insert_active_definition!(schema_name, [service_task_node("n1", entry.service_id)])

      assert {:error, {:referenced_by_active_definitions, definition_ids}} =
               ServiceCatalog.delete(entry.service_id)

      assert definition_id in definition_ids
      # Refused -- the row must still exist.
      assert Repo.get(Entry, entry.service_id)
    end

    test "delete of an unreferenced service succeeds" do
      provisioned_tenant("req191-del-unref")
      entry = register!(%{scope: :global})

      assert :ok = ServiceCatalog.delete(entry.service_id)
      refute Repo.get(Entry, entry.service_id)
    end

    test "a service id appearing only as a substring inside an unrelated string does NOT block delete" do
      %{schema_name: schema_name} = provisioned_tenant("req191-del-substr")
      entry = register!(%{scope: :global})

      # This node mentions the service_id as plain text inside an unrelated
      # HUMAN_TASK attribute -- never as a SERVICE_TASK node's own
      # "service_id" attribute. R-Co's LIKE-based guard would over-match this;
      # Letflow's structural guard must not.
      insert_active_definition!(schema_name, [
        unrelated_substring_node("n1", entry.service_id)
      ])

      assert :ok = ServiceCatalog.delete(entry.service_id)
      refute Repo.get(Entry, entry.service_id)
    end

    # Regression coverage for the SECURITY-REVIEWER rework this handoff names
    # (WF02-REQ191-20260830 Step 2c FAIL -> unhandled `Ecto.StaleEntryError`):
    # `delete_entry/1`'s own comment documents a real window between `delete/1`'s
    # initial `Repo.get/2` and its own `Repo.delete/1` in which a concurrent
    # caller can delete the same row first. This deterministically forces that
    # exact window (rather than hoping two processes race by chance) by holding
    # a real Postgres row-level lock open in one process while `delete/1` runs
    # concurrently in another: the second `DELETE` blocks on the lock, then
    # resumes against a row that is already gone once the lock releases --
    # exactly the 0-rows-affected condition `Repo.delete/1` turns into
    # `Ecto.StaleEntryError` by default.
    test "a concurrent delete of the same row is treated as a benign not-found, not a crash" do
      entry = register!(%{scope: :global})
      test_pid = self()

      {:ok, locker} =
        Task.start(fn ->
          Repo.transaction(fn ->
            Repo.delete_all(from(e in Entry, where: e.service_id == ^entry.service_id))
            send(test_pid, :row_locked)

            receive do
              :release_lock -> :ok
            end
          end)
        end)

      assert_receive :row_locked, 1_000

      delete_task = Task.async(fn -> ServiceCatalog.delete(entry.service_id) end)

      # Give delete/1's own Repo.get + Repo.delete a moment to run and block on
      # the row lock `locker` is holding, before releasing it.
      Process.sleep(200)
      send(locker, :release_lock)

      assert {:error, :not_found} = Task.await(delete_task, 5_000)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- update_scope/2: narrow refused (naming conflicting tenants),
  # widen always allowed
  # ---------------------------------------------------------------------------------

  describe "AC7: update_scope/2 narrow/widen" do
    test "narrowing global -> tenant is refused, naming the conflicting tenant, when another tenant's ACTIVE definition references it" do
      %{tenant_id: assignee_tenant_id} = provisioned_tenant("req191-narrow-assignee")

      %{tenant_id: other_tenant_id, schema_name: other_schema} =
        provisioned_tenant("req191-narrow-other")

      entry = register!(%{scope: :global})
      insert_active_definition!(other_schema, [service_task_node("n1", entry.service_id)])

      assert {:error, {:referenced_by_active_definitions, conflicts}} =
               ServiceCatalog.update_scope(entry.service_id, %{
                 scope: :tenant,
                 owner_tenant_id: assignee_tenant_id
               })

      assert Enum.any?(conflicts, &(&1.tenant_id == other_tenant_id))
      # Refused -- scope is unchanged.
      assert {:ok, %Entry{scope: :global}} =
               ServiceCatalog.get_for_tenant(entry.service_id, assignee_tenant_id)
    end

    test "narrowing global -> tenant succeeds when only the assignee tenant itself references it (self-exemption)" do
      %{tenant_id: assignee_tenant_id, schema_name: assignee_schema} =
        provisioned_tenant("req191-narrow-self")

      entry = register!(%{scope: :global})
      insert_active_definition!(assignee_schema, [service_task_node("n1", entry.service_id)])

      assert {:ok, %Entry{scope: :tenant, owner_tenant_id: ^assignee_tenant_id}} =
               ServiceCatalog.update_scope(entry.service_id, %{
                 scope: :tenant,
                 owner_tenant_id: assignee_tenant_id
               })
    end

    test "widening tenant -> global always succeeds, even with other tenants' ACTIVE references" do
      owner = insert_tenant!()
      %{schema_name: other_schema} = provisioned_tenant("req191-widen-other")

      entry = register!(%{scope: :tenant, owner_tenant_id: owner.id})
      insert_active_definition!(other_schema, [service_task_node("n1", entry.service_id)])

      assert {:ok, %Entry{scope: :global, owner_tenant_id: nil}} =
               ServiceCatalog.update_scope(entry.service_id, %{
                 scope: :global,
                 owner_tenant_id: nil
               })
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 -- ServiceScopeValidator.validate/3 works unchanged with a Lookup
  # backed by this catalog. service_scope_validator.ex itself is untouched
  # (confirmed via git diff, quoted in the handoff report, not re-asserted
  # here since it is a repository-history fact, not something ExUnit checks).
  # ---------------------------------------------------------------------------------

  describe "AC8: ServiceScopeValidator integration via scope_validator_lookup/1" do
    test "a definition referencing a service not visible to its tenant is rejected at activation" do
      owner = insert_tenant!()
      requester = insert_tenant!()
      entry = register!(%{scope: :tenant, owner_tenant_id: owner.id})

      graph = %Graph{
        nodes: [
          %Graph.Node{
            id: "n1",
            node_type: :SERVICE_TASK,
            attributes: %{"service_id" => entry.service_id}
          }
        ]
      }

      lookup = ServiceCatalog.scope_validator_lookup(requester.id)

      assert {:error, %ServiceScopeValidator.Violation{reason: :service_not_available_to_tenant}} =
               ServiceScopeValidator.validate(graph, requester.id, lookup)
    end

    test "a definition referencing a visible service activates" do
      entry = register!(%{scope: :global})
      requester = insert_tenant!()

      graph = %Graph{
        nodes: [
          %Graph.Node{
            id: "n1",
            node_type: :SERVICE_TASK,
            attributes: %{"service_id" => entry.service_id}
          }
        ]
      }

      lookup = ServiceCatalog.scope_validator_lookup(requester.id)

      assert :ok = ServiceScopeValidator.validate(graph, requester.id, lookup)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC9 -- migration + moduledoc state the GLOBAL divergence and cite
  # decision 0003 / REVIEWER sign-off. Simple content-presence check.
  # ---------------------------------------------------------------------------------

  describe "AC9: migration and moduledoc document the GLOBAL-table divergence" do
    test "the migration header cites decision 0003 and REVIEWER sign-off" do
      migration_source =
        File.read!("priv/repo/migrations/20260830000001_create_service_catalog.exs")

      assert migration_source =~ "0003-ecto-schema-strategy.md"
      assert migration_source =~ "REVIEWER sign-off"
      assert migration_source =~ "GLOBAL"
    end

    test "Letflow.ServiceCatalog's moduledoc cites decision 0003 and REVIEWER sign-off" do
      module_source = File.read!("lib/letflow/service_catalog.ex")

      assert module_source =~ "0003"
      assert module_source =~ "REVIEWER sign-off"
      assert module_source =~ "GLOBAL"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC10 -- SolutionPack's service_catalog_entries hard-fail is still in
  # place, REQ-192 named as owner
  # ---------------------------------------------------------------------------------

  describe "AC10: SolutionPack.service_catalog_entries hard-fail retained, ownership status documented" do
    test "SolutionPack's moduledoc documents the service_catalog_entries policy as settled by 0027" do
      module_source = File.read!("lib/letflow/definitions/solution_pack.ex")

      assert module_source =~ "service_catalog_entries"
      assert module_source =~ "0027-solution-pack-service-catalog-install-policy.md"
      assert module_source =~ "permanently NOT PERMITTED"
    end

    test "export/3 always emits service_catalog_entries: []" do
      %{schema_name: schema_name} = provisioned_tenant("req191-pack-export")

      definition_id =
        insert_active_definition!(schema_name, [%{"id" => "start", "node_type" => "START"}])

      assert {:ok, %{service_catalog_entries: []}} =
               Letflow.Definitions.SolutionPack.export(
                 [definition_id],
                 nil,
                 prefix: schema_name
               )
    end

    test "install/3 rejects a non-empty service_catalog_entries array with {:error, :unsupported_pack_section}" do
      %{schema_name: schema_name} = provisioned_tenant("req191-pack-install")

      document = %{
        "pack_id" => "req191-pack-#{System.unique_integer([:positive, :monotonic])}",
        "version" => "1.0.0",
        "bpm_export_schema_version" => Letflow.Definitions.ExportImport.export_schema_version(),
        "definitions" => [],
        "variable_schemas" => [],
        "service_catalog_entries" => [%{"service_id" => "should-not-install"}]
      }

      assert {:error, :unsupported_pack_section} =
               Letflow.Definitions.SolutionPack.install(
                 document,
                 Ecto.UUID.generate(),
                 prefix: schema_name
               )

      # All-or-nothing: nothing from this document was written.
      %{rows: rows} =
        Repo.query!(
          ~s(SELECT 1 FROM "#{schema_name}".process_definitions),
          []
        )

      assert rows == []
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-192 -- Letflow.ServiceCatalog.list_all/1 (added by REQ-192, design
  # req192-service-catalog-routes.md §5). These tests were NOT part of the
  # original REQ-191 acceptance criteria above (AC1-AC11); they cover only
  # the new list_all/1 function's own behavior, added here rather than in a
  # separate file since list_all/1 lives in this same module and this file
  # already carries the fixture helpers (insert_tenant!/register!) it needs.
  # list_for_tenant/2 itself is untouched and not re-tested here.
  # ---------------------------------------------------------------------------------

  describe "REQ-192 list_all/1: cross-tenant visibility, no tenant/scope filtering" do
    test "returns rows across multiple tenants and the global scope in one call -- none filtered out" do
      tenant_a = insert_tenant!("req192-list-all-a")
      tenant_b = insert_tenant!("req192-list-all-b")

      global_entry = register!(%{scope: :global})
      entry_a = register!(%{scope: :tenant, owner_tenant_id: tenant_a.id})
      entry_b = register!(%{scope: :tenant, owner_tenant_id: tenant_b.id})

      assert {:ok, %{items: items}} = ServiceCatalog.list_all(%{page_size: 200})
      ids = Enum.map(items, & &1.service_id)

      # The core behavior distinguishing list_all/1 from list_for_tenant/2:
      # tenant_a's own row, tenant_b's own row, AND the global row are all
      # present in a single unfiltered call -- no `tenant_id` argument exists
      # to narrow this result at all.
      assert global_entry.service_id in ids
      assert entry_a.service_id in ids
      assert entry_b.service_id in ids
    end

    test "a row list_for_tenant/2 would hide from a given tenant is nonetheless present via list_all/1 -- the actual behavioral difference, not just 'also sees global rows'" do
      tenant_a = insert_tenant!("req192-list-all-diff-a")
      tenant_b = insert_tenant!("req192-list-all-diff-b")
      entry_b = register!(%{scope: :tenant, owner_tenant_id: tenant_b.id})

      assert {:ok, %{items: tenant_a_items}} =
               ServiceCatalog.list_for_tenant(%{page_size: 200}, tenant_a.id)

      refute entry_b.service_id in Enum.map(tenant_a_items, & &1.service_id)

      assert {:ok, %{items: all_items}} = ServiceCatalog.list_all(%{page_size: 200})
      assert entry_b.service_id in Enum.map(all_items, & &1.service_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-192 -- list_all/1 vs list_for_tenant/2: SCA:/SC: cross-endpoint cursor
  # isolation (INV-9, Letflow.Api.Pagination.decode_cursor/4's check_prefix/2).
  # A cursor minted by one function must be structurally unusable against the
  # other -- this is the concrete, testable expression of "two functions, two
  # cursor prefixes, never interchangeable" from design §5.
  # ---------------------------------------------------------------------------------

  describe "REQ-192 list_all/1 <-> list_for_tenant/2: SCA2:/SC2: cursor cross-endpoint isolation (INV-9)" do
    test "a cursor minted by list_for_tenant/2 (SC2: prefix) is rejected by list_all/1 with {:error, :wrong_endpoint}" do
      tenant = insert_tenant!()
      register!(%{scope: :global})
      register!(%{scope: :global})

      assert {:ok, %{next_cursor: sc_cursor}} =
               ServiceCatalog.list_for_tenant(%{page_size: 1}, tenant.id)

      assert is_binary(sc_cursor)
      assert String.starts_with?(Base.url_decode64!(sc_cursor, padding: false), "SC2:")

      assert {:error, :wrong_endpoint} =
               ServiceCatalog.list_all(%{page_size: 1, cursor: sc_cursor})
    end

    test "a cursor minted by list_all/1 (SCA2: prefix) is rejected by list_for_tenant/2 with {:error, :wrong_endpoint}" do
      tenant = insert_tenant!()
      register!(%{scope: :global})
      register!(%{scope: :global})

      assert {:ok, %{next_cursor: sca_cursor}} = ServiceCatalog.list_all(%{page_size: 1})

      assert is_binary(sca_cursor)
      assert String.starts_with?(Base.url_decode64!(sca_cursor, padding: false), "SCA2:")

      assert {:error, :wrong_endpoint} =
               ServiceCatalog.list_for_tenant(%{page_size: 1, cursor: sca_cursor}, tenant.id)
    end

    test "SCA2: is not merely a longer match of SC2: -- neither prefix satisfies the other's check" do
      # Guards against a regression where @list_all_cursor_prefix and
      # @list_cursor_prefix accidentally shared a common prefix relationship
      # (e.g. if list_all/1 had been given "S:" and list_for_tenant/2 "SC:",
      # a naive `starts_with?` check could misfire in one direction). With
      # the real prefixes ("SC2:" vs "SCA2:") neither is a prefix of the
      # other, so both cross-checks above must independently fail closed.
      tenant = insert_tenant!()
      register!(%{scope: :global})
      register!(%{scope: :global})

      assert {:ok, %{next_cursor: sc_cursor}} =
               ServiceCatalog.list_for_tenant(%{page_size: 1}, tenant.id)

      assert {:ok, %{next_cursor: sca_cursor}} = ServiceCatalog.list_all(%{page_size: 1})

      refute String.starts_with?(Base.url_decode64!(sc_cursor, padding: false), "SCA2:")
      refute String.starts_with?(Base.url_decode64!(sca_cursor, padding: false), "SC2:")
    end

    test "the current and the previous cursor generation are told apart by their prefix alone" do
      # A `service_id` is a free-form string and may contain a colon, so the
      # number of colon-separated fields cannot say which generation a cursor
      # belongs to. The prefix does.
      tenant = insert_tenant!()
      register!(%{scope: :global})
      # Registered last, so it is the newest row and therefore the one the
      # first page's cursor points at.
      newest = register!(%{service_id: "acme:billing", scope: :global})

      assert {:ok, %{items: [first], next_cursor: current}} =
               ServiceCatalog.list_for_tenant(%{page_size: 1}, tenant.id)

      assert first.service_id == newest.service_id

      payload = Base.url_decode64!(current, padding: false)
      assert String.starts_with?(payload, "SC2:")

      # The issue time comes first (that is the field the 24h expiry window
      # counts from) and the service_id comes last (so a colon inside it
      # cannot shift the slots).
      ["SC2", mint_str, created_at_str, service_id] = String.split(payload, ":", parts: 4)

      {mint_us, ""} = Integer.parse(mint_str)
      assert_in_delta System.system_time(:microsecond) - mint_us, 0, 60_000_000

      {created_at_us, ""} = Integer.parse(created_at_str)
      assert created_at_us == DateTime.to_unix(first.created_at, :microsecond)
      assert service_id == "acme:billing"

      # The previous generation carries the seek key only, under its own
      # prefix -- it is read as that, never as the current form.
      previous =
        "SC:"
        |> Pagination.build_raw_cursor(DateTime.to_unix(DateTime.utc_now(), :microsecond), "x:1")
        |> Pagination.encode_cursor()

      assert {:ok, %{items: [_]}} =
               ServiceCatalog.list_for_tenant(%{page_size: 1, cursor: previous}, tenant.id)
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-192 -- list_all/1 standard pagination correctness: next_cursor set
  # when more rows remain, nil once exhausted. Mirrors the page_size+1-fetch/
  # drop-the-extra-row idiom list_all/1 shares with list_for_tenant/2
  # (service_catalog.ex's split_list_page/3).
  # ---------------------------------------------------------------------------------

  describe "REQ-192 list_all/1 pagination correctness" do
    # ISS-0409: `service_catalog` is a real, globally-committed table (see
    # moduledoc) -- unlike every other DataCase fixture in this suite, its rows
    # are never rolled back by a sandboxed transaction and are never dropped by
    # a tenant-schema `DROP SCHEMA ... CASCADE`. This describe block's
    # assertions are exact counts/splits (`length(page1) == 2`, `cursor2 ==
    # nil`), which silently assumed the table held *only* the rows this test
    # itself was about to create. That assumption broke intermittently in the
    # full suite: a stray global-scope row left behind by an interrupted prior
    # `mix test` run (real commits survive a `Ctrl-C` since `on_exit/1` never
    # fires) is enough to shift `list_all/1`'s page split and fail
    # `length(page2) == 1` / `cursor2 == nil` -- while the same test always
    # passed in isolation, where no such stray row happened to be sitting in
    # the database at that moment. This file and `admin_services_test.exs` are
    # the only two places that ever write real rows to this table, and both
    # already discipline themselves to delete every row they create -- so the
    # fix is this describe block asserting its own precondition (an empty
    # table) rather than assuming it, per `test_developer_guide.md` §1's "No
    # test pollution" / "doesn't depend on execution order" directive. Each
    # test below also cleans up its own created entries via `on_exit/1`
    # (this file's own established discipline, see `cleanup_entry!/1`) so this
    # describe block cannot become the NEXT run's source of stray rows --
    # the `setup`-time wipe alone only guards against rows already left by a
    # crashed prior run; it does not stop these tests from leaving new ones.
    setup do
      Repo.delete_all(Entry)
      :ok
    end

    test "rows older than 24 hours remain pageable through both catalog list functions" do
      tenant = insert_tenant!("cursor-issue-time-catalog")
      entries = for _ <- 1..3, do: register!(%{scope: :global})
      on_exit(fn -> Enum.each(entries, &cleanup_entry!(&1.service_id)) end)
      ids = Enum.map(entries, & &1.service_id)
      old = DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(e in Entry, where: e.service_id in ^ids), set: [created_at: old])

      for list_page <- [
            fn cursor -> ServiceCatalog.list_all(%{cursor: cursor, page_size: 1}) end,
            fn cursor ->
              ServiceCatalog.list_for_tenant(%{cursor: cursor, page_size: 1}, tenant.id)
            end
          ] do
        assert {:ok, %{items: [_], next_cursor: cursor1}} = list_page.(nil)
        assert {:ok, %{items: [_], next_cursor: cursor2}} = list_page.(cursor1)
        assert {:ok, %{items: [_], next_cursor: nil}} = list_page.(cursor2)
      end
    end

    test "a service_id containing a colon is paged exactly once per row (the id never shifts the cursor slots)" do
      tenant = insert_tenant!("cursor-colon-service-id")

      # The colon-carrying service_id is registered last and sorts highest,
      # so it heads the listing's (created_at DESC, service_id DESC) order
      # under either tiebreak -- and it is therefore the row whose cursor
      # the second page has to read.
      ids = ["aaa-one", "aaa-two", "acme:billing"]

      for id <- ids, do: register!(%{service_id: id, scope: :global})

      same = DateTime.utc_now() |> DateTime.truncate(:second)
      Repo.update_all(from(e in Entry, where: e.service_id in ^ids), set: [created_at: same])

      for list_page <- [
            fn cursor -> ServiceCatalog.list_all(%{cursor: cursor, page_size: 1}) end,
            fn cursor ->
              ServiceCatalog.list_for_tenant(%{cursor: cursor, page_size: 1}, tenant.id)
            end
          ] do
        assert {:ok, %{items: [first]}} = list_page.(nil)
        assert first.service_id == "acme:billing"

        # Walking the pages must visit every row exactly once and stop: a
        # cursor whose slots shift (a colon inside the service_id) makes the
        # second page restart at the top of the list, and a client that
        # follows `next_cursor` until it is nil then never stops.
        {seen, _last_cursor} =
          Enum.reduce_while(1..6, {[], nil}, fn _page, {seen, cursor} ->
            case list_page.(cursor) do
              {:ok, %{items: [item], next_cursor: nil}} ->
                {:halt, {Enum.reverse([item.service_id | seen]), nil}}

              {:ok, %{items: [item], next_cursor: next}} ->
                {:cont, {[item.service_id | seen], next}}

              {:ok, %{items: [], next_cursor: nil}} ->
                {:halt, {Enum.reverse(seen), nil}}
            end
          end)

        # Every row exactly once -- a repeat means the page restarted at the
        # top of the list.
        assert Enum.sort(seen) == Enum.sort(ids)
        assert length(seen) == length(ids)
      end
    end

    test "a legacy two-slot cursor with a colon in its service_id pages the rows behind it" do
      tenant = insert_tenant!("cursor-legacy-colon-service-id")
      colon_id = "acme:billing"
      register!(%{service_id: colon_id, scope: :global})
      register!(%{service_id: "plain-one", scope: :global})

      base = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.update_all(from(e in Entry, where: e.service_id == ^colon_id),
        set: [created_at: base]
      )

      Repo.update_all(from(e in Entry, where: e.service_id == "plain-one"),
        set: [created_at: DateTime.add(base, -60, :second)]
      )

      # The pre-fix two-slot form: "<prefix><created_at_us>:<service_id>". Its
      # service_id is free-form and may contain a colon -- which is exactly
      # what the three-slot form must never be confused with.
      legacy =
        "SC:"
        |> Pagination.build_raw_cursor(DateTime.to_unix(base, :microsecond), colon_id)
        |> Pagination.encode_cursor()

      legacy_admin =
        "SCA:"
        |> Pagination.build_raw_cursor(DateTime.to_unix(base, :microsecond), colon_id)
        |> Pagination.encode_cursor()

      assert {:ok, %{items: [%Entry{service_id: "plain-one"}], next_cursor: nil}} =
               ServiceCatalog.list_for_tenant(%{cursor: legacy, page_size: 1}, tenant.id)

      assert {:ok, %{items: [%Entry{service_id: "plain-one"}], next_cursor: nil}} =
               ServiceCatalog.list_all(%{cursor: legacy_admin, page_size: 1})
    end

    test "a legacy two-slot cursor is never read as the three-slot form" do
      # A service_id whose last colon-separated segment is a number is the
      # case the three-slot form swallows: its datetime slot would read that
      # segment as a timestamp and the seek key would be nonsense (a 1970
      # created_at), which loses rows instead of returning them.
      colon_id = "acme:123"
      register!(%{service_id: colon_id, scope: :global})
      register!(%{service_id: "plain-one", scope: :global})

      base = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.update_all(from(e in Entry, where: e.service_id == ^colon_id),
        set: [created_at: base]
      )

      Repo.update_all(from(e in Entry, where: e.service_id == "plain-one"),
        set: [created_at: DateTime.add(base, -60, :second)]
      )

      legacy =
        "SCA:"
        |> Pagination.build_raw_cursor(DateTime.to_unix(base, :microsecond), colon_id)
        |> Pagination.encode_cursor()

      assert {:ok, %{items: [%Entry{service_id: "plain-one"}], next_cursor: nil}} =
               ServiceCatalog.list_all(%{cursor: legacy, page_size: 1})
    end

    test "a legacy two-slot cursor for a row older than 24 hours answers expired, never wrong rows" do
      register!(%{service_id: "acme:billing", scope: :global})
      register!(%{service_id: "plain-one", scope: :global})

      old = DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second) |> DateTime.truncate(:second)
      ids = ["acme:billing", "plain-one"]
      Repo.update_all(from(e in Entry, where: e.service_id in ^ids), set: [created_at: old])

      legacy =
        "SCA:"
        |> Pagination.build_raw_cursor(DateTime.to_unix(old, :microsecond), "acme:billing")
        |> Pagination.encode_cursor()

      assert {:error, :expired} = ServiceCatalog.list_all(%{cursor: legacy, page_size: 1})
    end

    test "next_cursor is non-nil while more rows remain, and nil on the final page" do
      entries = for _ <- 1..3, do: register!(%{scope: :global})
      on_exit(fn -> Enum.each(entries, &cleanup_entry!(&1.service_id)) end)
      expected_ids = entries |> Enum.map(& &1.service_id) |> Enum.sort()

      assert {:ok, %{items: page1, next_cursor: cursor1}} =
               ServiceCatalog.list_all(%{page_size: 2})

      assert length(page1) == 2
      assert is_binary(cursor1)

      assert {:ok, %{items: page2, next_cursor: cursor2}} =
               ServiceCatalog.list_all(%{page_size: 2, cursor: cursor1})

      assert length(page2) == 1
      assert cursor2 == nil

      all_ids = (page1 ++ page2) |> Enum.map(& &1.service_id) |> Enum.sort()
      assert all_ids == expected_ids
    end

    test "next_cursor is nil on the first page when the full result set fits within page_size" do
      entry = register!(%{scope: :global})
      on_exit(fn -> cleanup_entry!(entry.service_id) end)

      assert {:ok, %{items: items, next_cursor: nil}} = ServiceCatalog.list_all(%{page_size: 200})
      assert entry.service_id in Enum.map(items, & &1.service_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC11 -- no route/controller file added or modified (structural, no git
  # history dependency: confirms the routers directory carries nothing named
  # for this catalog, independent of when it was added).
  # ---------------------------------------------------------------------------------

  describe "AC11: no route/controller surface for the service catalog" do
    test "lib/letflow/routers/ contains no service-catalog route module" do
      routers_dir = "lib/letflow/routers"

      matches =
        routers_dir
        |> File.ls!()
        |> Enum.filter(&String.contains?(String.downcase(&1), "service_catalog"))

      assert matches == []
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-373 AC1 -- version identity + ACTIVE/RETIRED status. See
  # test/specs/req373-service-catalog-version-lifecycle.md for the full
  # rationale. Design authority:
  # lib/letflow/design/req373-service-catalog-version-lifecycle.md §1/§4.
  # ---------------------------------------------------------------------------------

  describe "REQ-373 AC1: version identity + ACTIVE/RETIRED status columns" do
    test "register/1 stamps a fresh row with version: \"1\", status: :ACTIVE, a version_id, published_at, and a nil retired_at" do
      entry = register!(%{scope: :global})

      assert entry.version == "1"
      assert entry.status == :ACTIVE
      assert is_binary(entry.version_id)
      assert %DateTime{} = entry.published_at
      assert entry.retired_at == nil
    end

    test "a database-level CHECK rejects status = 'BOGUS' -- chk_service_catalog_status" do
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO service_catalog " <>
                   "(service_id, endpoint_url, required_auth, timeout_ms, scope, owner_tenant_id, " <>
                   "created_at, updated_at, version, version_id, status, published_at) " <>
                   "VALUES ($1, 'https://example.test', 'NONE', 5000, 'global', NULL, " <>
                   "now(), now(), '1', gen_random_uuid(), 'BOGUS', now())",
                 [service_id]
               )

      refute Repo.get(Entry, service_id)
    end

    # NOTE (real finding, confirmed by running this test against the actual
    # migration): `version`'s Ecto migration type is plain `:string`, which the
    # Postgres adapter renders as `varchar(255)` by default (same as every
    # other `:string` column on this table, e.g. `endpoint_url`, whose own
    # 2048-char limit is therefore ALSO only ever enforced at the changeset
    # level, never the database's, for the identical reason). Postgres itself
    # rejects a value that doesn't fit the column's own type width before it
    # ever reaches CHECK-constraint evaluation, so `chk_service_catalog_version_length`
    # (bound at the identical 255 the column type already enforces) can never
    # actually fire via any insert path -- the type-level rejection always
    # wins first. This test asserts the real, observed failure mode
    # (`:string_data_right_truncation`) rather than the design's stated one
    # (`:check_violation`) -- the acceptance criterion ("an over-length version
    # is rejected by the database") still holds, just via a different, and
    # here provably unreachable, mechanism than the migration's own comment
    # implies. Flagged for REVIEWER/ELIXIR-DEV rather than silently
    # rewritten to hide the discrepancy.
    test "a 256-character version string is rejected by the database (via the varchar(255) column type -- chk_service_catalog_version_length is provably unreachable, see note above)" do
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)
      too_long_version = String.duplicate("v", 256)

      assert {:error, %Postgrex.Error{postgres: %{code: :string_data_right_truncation}}} =
               Repo.query(
                 "INSERT INTO service_catalog " <>
                   "(service_id, endpoint_url, required_auth, timeout_ms, scope, owner_tenant_id, " <>
                   "created_at, updated_at, version, version_id, status, published_at) " <>
                   "VALUES ($1, 'https://example.test', 'NONE', 5000, 'global', NULL, " <>
                   "now(), now(), $2, gen_random_uuid(), 'ACTIVE', now())",
                 [service_id, too_long_version]
               )

      refute Repo.get(Entry, service_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-373 -- publish/3 and retire/1 core behavior. Not individually numbered
  # acceptance criteria, but load-bearing infrastructure every AC2-5 test in
  # test/letflow/engine_pin_resolver_catalog_test.exs builds on -- see this
  # file's own spec doc.
  # ---------------------------------------------------------------------------------

  defp publish_attrs(overrides \\ %{}) do
    %{
      endpoint_url: "https://example.test/svc-v2",
      required_auth: :NONE,
      timeout_ms: 6_000
    }
    |> Map.merge(overrides)
  end

  describe "REQ-373 publish/3" do
    test "against a nonexistent service_id returns {:error, :not_found}" do
      assert {:error, :not_found} =
               ServiceCatalog.publish(
                 unique_service_id("req373-pub-missing"),
                 "2",
                 publish_attrs()
               )
    end

    test "a version equal to the row's own current version returns {:error, :duplicate_version}" do
      entry = register!(%{scope: :global})

      assert {:error, :duplicate_version} =
               ServiceCatalog.publish(entry.service_id, entry.version, publish_attrs())
    end

    test "a version equal to an already-archived version returns {:error, :duplicate_version} -- checks service_catalog_versions, not only the live row" do
      entry = register!(%{scope: :global})

      assert {:ok, _v2} = ServiceCatalog.publish(entry.service_id, "2", publish_attrs())

      # "1" is no longer the live row's version (that's now "2") but it IS
      # archived in service_catalog_versions -- the duplicate check must catch
      # this, not only compare against the current row.
      assert {:error, :duplicate_version} =
               ServiceCatalog.publish(entry.service_id, "1", publish_attrs())
    end

    test "a successful publish archives the previous row's snapshot and updates the live row in place" do
      entry = register!(%{scope: :global, endpoint_url: "https://example.test/svc-v1"})
      original_version_id = entry.version_id

      assert {:ok, updated} =
               ServiceCatalog.publish(
                 entry.service_id,
                 "2",
                 publish_attrs(%{endpoint_url: "https://example.test/svc-v2"})
               )

      # Live row updated in place.
      assert updated.service_id == entry.service_id
      assert updated.version == "2"
      assert updated.status == :ACTIVE
      assert updated.endpoint_url == "https://example.test/svc-v2"
      assert updated.retired_at == nil
      assert updated.version_id != original_version_id

      # Previous version's full snapshot archived under its OWN (pre-publish)
      # version_id, never regenerated.
      archived = Repo.get(Version, original_version_id)
      assert archived
      assert archived.service_id == entry.service_id
      assert archived.version == "1"
      assert archived.endpoint_url == "https://example.test/svc-v1"
      assert %DateTime{} = archived.retired_at
    end

    test "publishing following a bare retire archives the retired row exactly as publishing following an active one would" do
      entry = register!(%{scope: :global})
      assert {:ok, retired} = ServiceCatalog.retire(entry.service_id)
      assert retired.status == :RETIRED

      assert {:ok, updated} = ServiceCatalog.publish(entry.service_id, "2", publish_attrs())

      assert updated.status == :ACTIVE
      archived = Repo.get(Version, retired.version_id)
      assert archived
      assert archived.version == "1"
    end
  end

  describe "REQ-373 retire/1" do
    test "against a nonexistent service_id returns {:error, :not_found}" do
      assert {:error, :not_found} = ServiceCatalog.retire(unique_service_id("req373-ret-missing"))
    end

    test "against an already-RETIRED row returns {:error, :already_retired}, not a silent :ok" do
      entry = register!(%{scope: :global})
      assert {:ok, _retired} = ServiceCatalog.retire(entry.service_id)

      assert {:error, :already_retired} = ServiceCatalog.retire(entry.service_id)
    end

    test "a successful retire sets status: :RETIRED, stamps retired_at, and leaves every version-specific field untouched -- no service_catalog_versions insert" do
      entry = register!(%{scope: :global, endpoint_url: "https://example.test/svc-retire"})

      assert {:ok, retired} = ServiceCatalog.retire(entry.service_id)

      assert retired.status == :RETIRED
      assert %DateTime{} = retired.retired_at
      assert retired.endpoint_url == entry.endpoint_url
      assert retired.version == entry.version
      assert retired.version_id == entry.version_id

      refute Repo.get(Version, entry.version_id)
    end
  end
end
