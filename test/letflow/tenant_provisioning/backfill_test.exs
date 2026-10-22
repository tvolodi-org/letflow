defmodule Letflow.TenantProvisioning.BackfillTest do
  @moduledoc """
  Regression tests for ISS-0332: `Letflow.TenantProvisioning.Backfill.run/1`
  backfills DEFINITION_PROMOTED to schema_version 2 for tenants provisioned before
  REQ-077 bumped the type from v1 (review_id type "string", non-null) to v2
  (review_id type ["string","null"]).

  WF-03 Step 4 fail-first requirement: since `Letflow.TenantProvisioning.Backfill`
  is a new module, running these tests against pre-fix code produces
  `UndefinedFunctionError`. In lieu of a pre-fix run, two mutants are applied to
  the shipped `Backfill.run/1` in sequence (see mutation results in
  handoffs/WF03-ISS0332-20260826/step-04-test-designer.json).

  `async: false` — required because `TenantFixture.provisioned_tenant!/1` switches
  `Letflow.Repo` to Sandbox `:auto` mode for real schema creation. See
  `test/letflow/event_store/registry_test.exs` moduledoc for the full empirical
  reasoning this file reuses rather than re-deriving.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.EventStore.Registry
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.Identity.Tenant
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Backfill
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # V1 attrs: review_id type "string" (non-null), as registered by pre-REQ-077
  # provisioning. Matches the schema that causes R10 to fail with a null review_id.
  defp v1_attrs do
    %{
      "name" => "DEFINITION_PROMOTED",
      "schema_version" => 1,
      "description" => "ISS-0332 v1 test fixture",
      "json_schema" => %{
        "type" => "object",
        "properties" => %{
          "review_id" => %{"type" => "string"},
          "source_tenant_id" => %{"type" => "string"},
          "target_tenant_id" => %{"type" => "string"},
          "source_definition_id" => %{"type" => "string"},
          "target_definition_id" => %{"type" => "string"},
          "process_key" => %{"type" => "string"}
        },
        "required" => [
          "review_id",
          "source_tenant_id",
          "target_tenant_id",
          "source_definition_id",
          "target_definition_id",
          "process_key"
        ]
      }
    }
  end

  # V2 attrs: review_id type ["string","null"] — exact copy of the entry in
  # @platform_event_type_seed_attrs (lib/letflow/tenant_provisioning.ex ~L770).
  # This is the argument Backfill.run/1 receives in production.
  defp v2_attrs do
    %{
      "name" => "DEFINITION_PROMOTED",
      "schema_version" => 2,
      "description" => "ISS-0332 v2 test fixture",
      "json_schema" => %{
        "type" => "object",
        "properties" => %{
          "review_id" => %{"type" => ["string", "null"]},
          "source_tenant_id" => %{"type" => "string"},
          "target_tenant_id" => %{"type" => "string"},
          "source_definition_id" => %{"type" => "string"},
          "target_definition_id" => %{"type" => "string"},
          "process_key" => %{"type" => "string"}
        },
        "required" => [
          "review_id",
          "source_tenant_id",
          "target_tenant_id",
          "source_definition_id",
          "target_definition_id",
          "process_key"
        ]
      }
    }
  end

  # A valid DEFINITION_PROMOTED payload with null review_id. Against v1 schema, this
  # fails (review_id must be a string). Against v2, it passes. This is the exact payload
  # shape that caused ISS-0332's Severity-1 event-append failure.
  defp null_review_id_payload do
    Jason.encode!(%{
      "review_id" => nil,
      "source_tenant_id" => Ecto.UUID.generate(),
      "target_tenant_id" => Ecto.UUID.generate(),
      "source_definition_id" => Ecto.UUID.generate(),
      "target_definition_id" => Ecto.UUID.generate(),
      "process_key" => "test-process-key"
    })
  end

  # Removes all DEFINITION_PROMOTED entries from the tenant's event_type_registry and
  # inserts a fresh v1 row, simulating a pre-REQ-077 provisioned tenant.
  # provisioned_tenant! seeds v2 during replay_migrations, so this downgrade is
  # necessary to reproduce the ISS-0332 pre-condition.
  defp downgrade_to_v1!(schema_name) do
    from(e in EventType, where: e.name == "DEFINITION_PROMOTED")
    |> Repo.delete_all(prefix: schema_name)

    EventType.changeset(%EventType{}, v1_attrs())
    |> Repo.insert!(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------
  # AC1: backfill updates pre-existing tenants' DEFINITION_PROMOTED to schema_version 2
  # ---------------------------------------------------------------------------

  test "regression: ISS-0332 -- backfill updates pre-existing tenant to schema_version 2" do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(slug_prefix: "iss0332-ac1")

    # Downgrade DEFINITION_PROMOTED to v1 to simulate a pre-REQ-077 tenant.
    downgrade_to_v1!(schema_name)

    assert {:ok, %EventType{schema_version: 1}} =
             Registry.get_type("DEFINITION_PROMOTED", tenant_id)

    assert {:ok, %{updated: updated, skipped: _skipped}} = Backfill.run(v2_attrs())
    assert updated >= 1

    # Post-backfill: highest registered version for this tenant is now 2.
    assert {:ok, %EventType{schema_version: 2}} =
             Registry.get_type("DEFINITION_PROMOTED", tenant_id)
  end

  # ---------------------------------------------------------------------------
  # AC2: R10 against a pre-existing tenant succeeds end-to-end
  # ---------------------------------------------------------------------------

  test "regression: ISS-0332 -- R10 event-append succeeds after backfill (validate_payload accepts null review_id)" do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(slug_prefix: "iss0332-ac2")

    downgrade_to_v1!(schema_name)

    payload = null_review_id_payload()

    # BEFORE backfill: v1 schema rejects null review_id — this is ISS-0332's bug.
    assert {:error, {:payload_validation_failed, _}} =
             Registry.validate_payload("DEFINITION_PROMOTED", payload, tenant_id)

    assert {:ok, _} = Backfill.run(v2_attrs())

    # AFTER backfill: v2 schema accepts null review_id — the fix is effective.
    assert :ok = Registry.validate_payload("DEFINITION_PROMOTED", payload, tenant_id)
  end

  # ---------------------------------------------------------------------------
  # AC3: idempotent on already-v2 tenants (skipped, not errored)
  # ---------------------------------------------------------------------------

  test "regression: ISS-0332 -- idempotent: already-v2 tenant is skipped, not errored" do
    %{tenant_id: tenant_id} =
      TenantFixture.provisioned_tenant!(slug_prefix: "iss0332-ac3")

    # provisioned_tenant! seeds DEFINITION_PROMOTED at v2 via replay_migrations.
    assert {:ok, %EventType{schema_version: 2}} =
             Registry.get_type("DEFINITION_PROMOTED", tenant_id)

    assert {:ok, %{updated: _updated, skipped: skipped}} = Backfill.run(v2_attrs())
    assert skipped >= 1

    # Schema version unchanged after backfill.
    assert {:ok, %EventType{schema_version: 2}} =
             Registry.get_type("DEFINITION_PROMOTED", tenant_id)
  end

  # ---------------------------------------------------------------------------
  # Additional: higher existing schema_version is also skipped (schema_version_not_monotonic)
  # ---------------------------------------------------------------------------

  test "regression: ISS-0332 -- higher existing schema_version is skipped (schema_version_not_monotonic)" do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(slug_prefix: "iss0332-monotonic")

    # Replace v2 (seeded at provisioning) with v3 to simulate a hypothetical
    # future-versioned tenant. register_type/2 enforces monotonicity, so we bypass
    # it via direct Repo.insert! here — consistent with downgrade_to_v1!/1's
    # approach for the opposite direction.
    from(e in EventType, where: e.name == "DEFINITION_PROMOTED")
    |> Repo.delete_all(prefix: schema_name)

    EventType.changeset(%EventType{}, %{
      "name" => "DEFINITION_PROMOTED",
      "schema_version" => 3,
      "description" => "ISS-0332 v3 fixture (hypothetical future version)",
      "json_schema" => %{"type" => "object"}
    })
    |> Repo.insert!(prefix: schema_name)

    assert {:ok, %EventType{schema_version: 3}} =
             Registry.get_type("DEFINITION_PROMOTED", tenant_id)

    # Backfill with v2 attrs must skip the v3 tenant without error.
    assert {:ok, %{updated: _updated, skipped: skipped}} = Backfill.run(v2_attrs())
    assert skipped >= 1

    # v3 is untouched.
    assert {:ok, %EventType{schema_version: 3}} =
             Registry.get_type("DEFINITION_PROMOTED", tenant_id)
  end

  # ---------------------------------------------------------------------------
  # ISS-0343 regression: a tenant whose Registration row survives its own
  # schema being dropped mid-sweep is skipped, not a crash of the whole run.
  # ---------------------------------------------------------------------------

  # Provisions a real tenant, then drops its physical schema WITHOUT deleting the
  # Registration row -- the exact "Registration exists, schema does not" window
  # ISS-0343's concurrent teardown/offboarding race produces. Mirrors
  # test/letflow/event_store/registry_tenant_schema_missing_test.exs's own
  # tenant_with_vanished_schema/1 helper (this file needs its own copy since it lives
  # in a different test module).
  defp tenant_with_vanished_schema!(prefix) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug(prefix),
          display_name: "ISS-0343 Backfill Test Tenant"
        },
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn ->
      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))

    tenant.id
  end

  # ---------------------------------------------------------------------------
  # ISS-0583: TASK_COMPLETED backfill (REQ-292 v1 -> v2 bump)
  # ---------------------------------------------------------------------------

  # V1 attrs: event enum only admits "variable_overwritten", item-level
  # required: ["event", "key"] -- the exact pre-REQ-292 seed
  # (git show 18f68e12^ -- lib/letflow/tenant_provisioning.ex).
  defp task_completed_v1_attrs do
    %{
      "name" => "TASK_COMPLETED",
      "schema_version" => 1,
      "description" => "ISS-0583 v1 test fixture",
      "json_schema" => %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string"},
          "node_id" => %{"type" => "string"},
          "output_variables" => %{"type" => "object"},
          "merged_variable_events" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "event" => %{"type" => "string", "enum" => ["variable_overwritten"]},
                "key" => %{"type" => "string"}
              },
              "required" => ["event", "key"]
            }
          },
          "activated_nodes" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["task_id", "node_id", "output_variables", "activated_nodes"]
      }
    }
  end

  # V2 attrs: exact copy of lib/letflow/tenant_provisioning.ex lines ~788-821
  # (independently transcribed from tenant_provisioning.ex, not from the mix
  # task's own @task_completed_v2_attrs, per design doc §5.1).
  defp task_completed_v2_attrs do
    %{
      "name" => "TASK_COMPLETED",
      "schema_version" => 2,
      "description" => "ISS-0583 v2 test fixture",
      "json_schema" => %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string"},
          "node_id" => %{"type" => "string"},
          "output_variables" => %{"type" => "object"},
          "merged_variable_events" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "event" => %{
                  "type" => "string",
                  "enum" => [
                    "variable_overwritten",
                    "computed_field_disagreement",
                    "visible_when_false_value_discarded"
                  ]
                },
                "key" => %{"type" => "string"},
                "field" => %{"type" => "string"},
                "old_value" => %{},
                "new_value" => %{},
                "submitted_value" => %{},
                "server_value" => %{},
                "discarded_value" => %{}
              },
              "required" => ["event"]
            }
          },
          "activated_nodes" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["task_id", "node_id", "output_variables", "activated_nodes"]
      }
    }
  end

  # V3 attrs: exact copy of lib/letflow/tenant_provisioning.ex's current
  # @platform_event_type_seed_attrs entry for "TASK_COMPLETED" (REQ-391:
  # adds "attachments_at_decision", the snapshot-embedding requirement) --
  # independently transcribed, not shared with the mix task's own
  # @event_type_backfills, per design doc §5.1.
  defp task_completed_v3_attrs do
    %{
      "name" => "TASK_COMPLETED",
      "schema_version" => 3,
      "description" => "REQ-391 v3 test fixture",
      "json_schema" => %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string"},
          "node_id" => %{"type" => "string"},
          "output_variables" => %{"type" => "object"},
          "merged_variable_events" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "event" => %{
                  "type" => "string",
                  "enum" => [
                    "variable_overwritten",
                    "computed_field_disagreement",
                    "visible_when_false_value_discarded"
                  ]
                },
                "key" => %{"type" => "string"},
                "field" => %{"type" => "string"},
                "old_value" => %{},
                "new_value" => %{},
                "submitted_value" => %{},
                "server_value" => %{},
                "discarded_value" => %{}
              },
              "required" => ["event"]
            }
          },
          "activated_nodes" => %{"type" => "array", "items" => %{"type" => "string"}},
          "attachments_at_decision" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "attachment_id" => %{"type" => "string"},
                "file_name" => %{"type" => "string"},
                "content_type" => %{"type" => "string"},
                "byte_size" => %{"type" => "integer"},
                "uploaded_by" => %{"type" => "string"},
                "created_at" => %{"type" => "string"}
              },
              "required" => ["attachment_id", "file_name"]
            }
          }
        },
        "required" => ["task_id", "node_id", "output_variables", "activated_nodes"]
      }
    }
  end

  # Removes all TASK_COMPLETED entries from the tenant's event_type_registry and
  # inserts a fresh v1 row, simulating a pre-REQ-292 provisioned tenant.
  defp downgrade_task_completed_to_v1!(schema_name) do
    from(e in EventType, where: e.name == "TASK_COMPLETED")
    |> Repo.delete_all(prefix: schema_name)

    EventType.changeset(%EventType{}, task_completed_v1_attrs())
    |> Repo.insert!(prefix: schema_name)
  end

  describe "TASK_COMPLETED backfill (ISS-0583)" do
    test "regression: ISS-0583 -- backfill updates pre-existing tenant to schema_version 2" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0583-ac1")

      downgrade_task_completed_to_v1!(schema_name)

      assert {:ok, %EventType{schema_version: 1}} =
               Registry.get_type("TASK_COMPLETED", tenant_id)

      assert {:ok, %{updated: updated, skipped: _skipped}} =
               Backfill.run(task_completed_v2_attrs())

      assert updated >= 1

      assert {:ok, %EventType{schema_version: 2}} =
               Registry.get_type("TASK_COMPLETED", tenant_id)
    end

    test "regression: ISS-0583 -- idempotent: already-current-version tenant is skipped, not errored" do
      # template: :replay -- the default :clone path clones from the cached
      # "tenant_template" schema (ISS-0427), which is only self-checked against
      # applied migration *versions*, not against event_type_registry seed
      # *content* (test/support/tenant_template.ex's self-check). A template
      # built before REQ-292/REQ-391 landed would still carry TASK_COMPLETED at
      # an older version even though current code seeds v3, which would make
      # this specific assertion about provisioned_tenant!'s default seed state
      # flaky against a stale cache. :replay drives the real
      # TenantProvisioning.replay_migrations/1 path, which always reflects the
      # current in-code seed.
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0583-ac3", template: :replay)

      # provisioned_tenant! (via :replay) seeds TASK_COMPLETED at v4 (decision 0062 R8h-5 bumped
      # the default seed from v3 to v4; task_completed_v3_attrs/0 is now the older version).
      assert {:ok, %EventType{schema_version: 4}} =
               Registry.get_type("TASK_COMPLETED", tenant_id)

      assert {:ok, %{updated: _updated, skipped: skipped}} =
               Backfill.run(task_completed_v3_attrs())

      assert skipped >= 1

      assert {:ok, %EventType{schema_version: 4}} =
               Registry.get_type("TASK_COMPLETED", tenant_id)
    end
  end

  test "regression: ISS-0343 -- a tenant whose schema vanished mid-sweep is skipped, not a crash of the whole run" do
    # A normal, healthy tenant that the sweep must still update.
    %{tenant_id: healthy_tenant_id, schema_name: healthy_schema_name} =
      TenantFixture.provisioned_tenant!(slug_prefix: "iss0343-backfill-healthy")

    downgrade_to_v1!(healthy_schema_name)

    # A tenant whose Registration row exists but whose physical schema has already
    # been dropped -- the exact race Backfill.run/1's Registration -> Registry.register_type/2
    # window can hit (design doc section 1). Pre-fix, Registry.register_type/2 let the
    # resulting Postgrex.Error (undefined_table) propagate uncaught, which unwound
    # straight out of Enum.reduce_while/3 and crashed the ENTIRE run -- including the
    # still-healthy tenant above, which would never get updated.
    vanished_tenant_id = tenant_with_vanished_schema!("iss0343-backfill-vanished")

    assert {:ok, %{updated: updated, skipped: skipped}} = Backfill.run(v2_attrs())
    assert updated >= 1
    assert skipped >= 1

    # The healthy tenant was updated despite the other tenant's schema having vanished --
    # proof the vanished tenant did not halt/crash the sweep for everyone else.
    assert {:ok, %EventType{schema_version: 2}} =
             Registry.get_type("DEFINITION_PROMOTED", healthy_tenant_id)

    # Direct, tenant_id-scoped confirmation that the vanished tenant was specifically
    # routed to :skipped (not merely unvisited): calling the same function Backfill.run/1
    # calls internally for this tenant reproduces the same error, since the physical
    # schema is still gone.
    assert {:error, :tenant_schema_missing} =
             Registry.register_type(v2_attrs(), vanished_tenant_id)

    # The vanished tenant's Registration row is still queryable (it was never deleted --
    # only its physical schema is gone), confirming this test exercised the intended
    # "Registration present, schema absent" window rather than :tenant_not_provisioned.
    assert %Registration{} = Repo.get_by(Registration, tenant_id: vanished_tenant_id)
  end
end
