defmodule Letflow.Routers.SolutionPacksManagedByTest do
  @moduledoc """
  REQ-496 / GH #2530 AC3, design `lib/letflow/design/req496-managed-by-and-scope-node-paths.md`
  §3.3, D8 and §9 T-16, T-17 (spec `test/specs/REQ-496.md`): a TENANT pack that defines an entity
  type whose name a module manages is refused on both solution-pack write routes with the uniform
  403 `Letflow.Api.Error.entity_type_managed/0` (the designer's pick under AC3), and afterwards no
  new `entity_definitions` version exists under that name.

    * T-16: `POST /solution-packs/install` -- the whole install rolls back, including the
      unmanaged type the same pack carries and the `solution_pack_installs` row.
    * T-17: `POST /solution-packs/:pack_id/update-apply` -- refused when the managed name is the
      `artefact_id`, only inside `content`, or only inside a resolution's `resolved_content`; no
      `pack_update_resolutions` row. A control with an unmanaged name is not refused by the guard.

  `fixture_managed` is installed first (its pack id `fixture-managed-foundation` is the pack the
  update-apply calls target). Requests go straight into the router with a hand-assigned
  `auth_context` and a pinned `trace_id`, so the body is compared byte for byte.

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Api.Error
  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Modules.Installs
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @solution_packs_opts Letflow.Routers.SolutionPacks.init([])
  @trace "req496-solution-packs-trace"
  @module_pack_id "fixture-managed-foundation"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req496-packs")

    on_exit(fn ->
      Repo.delete_all(from(r in PackUpdateResolution, where: r.tenant_id == ^tenant.tenant_id))
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    {:ok, _tenant_module} =
      Installs.install("fixture_managed", Ecto.UUID.generate(),
        prefix: tenant.schema_name,
        rationale: "REQ-496 solution-pack test install"
      )

    {:ok, tenant_id: tenant.tenant_id, schema: tenant.schema_name}
  end

  defp call_packs(ctx, path, body) do
    Plug.Test.conn(:post, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: ctx.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)
  end

  defp managed_body, do: Error.serialise(%{Error.entity_type_managed() | trace_id: @trace})

  defp count_named(schema, name) do
    Repo.aggregate(from(d in EntityDefinition, where: d.name == ^name), :count, prefix: schema)
  end

  defp resolution_count(tenant_id) do
    Repo.aggregate(from(r in PackUpdateResolution, where: r.tenant_id == ^tenant_id), :count)
  end

  defp entity_entry(name, display_name) do
    %{
      "entity_definition_id" => Ecto.UUID.generate(),
      "name" => name,
      "display_name" => display_name,
      "logical_shape_version" =>
        Base.encode16(:crypto.hash(:sha256, name <> display_name), case: :lower),
      "definition_json" => %{
        "name" => name,
        "display_name" => display_name,
        "fields" => [
          %{"name" => "name", "type" => "string", "required" => true},
          %{"name" => "tenant_note", "type" => "string"}
        ]
      }
    }
  end

  defp tenant_pack(entries) do
    %{
      "pack_id" => "req496-tenant-pack-#{System.unique_integer([:positive])}",
      "version" => "1.0.0",
      "bpm_export_schema_version" => "bpm/definition/v1",
      "exported_at" => "2026-10-14T00:00:00Z",
      "manifest" => %{"required_roles" => []},
      "definitions" => [],
      "variable_schemas" => [],
      "service_catalog_entries" => [],
      "entity_definitions" => entries
    }
  end

  describe "T-16: POST /solution-packs/install" do
    test "a tenant pack defining org_unit (plus an unmanaged type) -> uniform 403, nothing written",
         ctx do
      org_unit_before = count_named(ctx.schema, "org_unit")

      pack =
        tenant_pack([
          entity_entry("fxm_tenant_extra", "Tenant extra"),
          entity_entry("org_unit", "Tenant org unit")
        ])

      conn = call_packs(ctx, "/install", pack)

      assert conn.status == 403, conn.resp_body
      assert conn.resp_body == managed_body()

      assert count_named(ctx.schema, "org_unit") == org_unit_before
      assert count_named(ctx.schema, "fxm_tenant_extra") == 0

      refute Repo.exists?(
               from(i in SolutionPackInstall,
                 where: i.tenant_id == ^ctx.tenant_id and i.pack_id == ^pack["pack_id"]
               )
             )
    end

    test "control: the same pack without the managed name installs (200)", ctx do
      pack = tenant_pack([entity_entry("fxm_tenant_extra", "Tenant extra")])
      conn = call_packs(ctx, "/install", pack)

      assert conn.status == 200, conn.resp_body
      assert count_named(ctx.schema, "fxm_tenant_extra") == 1
    end
  end

  defp entity_artefact(artefact_id, content) do
    %{"artefact_type" => "entity_definition", "artefact_id" => artefact_id, "content" => content}
  end

  describe "T-17: POST /solution-packs/:pack_id/update-apply" do
    test "a managed name as artefact_id, only in content, or only in resolved_content -> uniform 403",
         ctx do
      org_unit_before = count_named(ctx.schema, "org_unit")
      resolutions_before = resolution_count(ctx.tenant_id)
      in_content = Jason.encode!(%{"name" => "org_unit", "fields" => []})

      bodies = [
        artefact_id: %{
          "target_version" => "0.2.0",
          "theirs_artefacts" => [],
          "incoming_artefacts" => [entity_artefact("org_unit", "{}")],
          "resolutions" => []
        },
        content_only: %{
          "target_version" => "0.2.0",
          "theirs_artefacts" => [entity_artefact("renamed_artefact", "{}")],
          "incoming_artefacts" => [entity_artefact("renamed_artefact", in_content)],
          "resolutions" => []
        },
        resolved_content_only: %{
          "target_version" => "0.2.0",
          "theirs_artefacts" => [entity_artefact("renamed_artefact", "{}")],
          "incoming_artefacts" => [entity_artefact("renamed_artefact", "{}")],
          "resolutions" => [
            %{
              "artefact_type" => "entity_definition",
              "artefact_id" => "renamed_artefact",
              "resolution" => "merged",
              "resolved_content" => in_content
            }
          ]
        }
      ]

      for {label, body} <- bodies do
        conn = call_packs(ctx, "/#{@module_pack_id}/update-apply", body)

        assert conn.status == 403, "#{label}: #{conn.status} #{conn.resp_body}"
        assert conn.resp_body == managed_body(), label
      end

      assert resolution_count(ctx.tenant_id) == resolutions_before
      assert count_named(ctx.schema, "org_unit") == org_unit_before
    end

    test "control: an unmanaged entity_definition artefact is not refused by the managed guard",
         ctx do
      body = %{
        "target_version" => "0.2.0",
        "theirs_artefacts" => [entity_artefact("fxm_free", "{}")],
        "incoming_artefacts" => [
          entity_artefact("fxm_free", Jason.encode!(%{"name" => "fxm_free"}))
        ],
        "resolutions" => []
      }

      conn = call_packs(ctx, "/#{@module_pack_id}/update-apply", body)
      refute conn.status == 403, conn.resp_body
      refute conn.resp_body =~ "entity-type-managed"
    end
  end
end
