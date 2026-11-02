defmodule Letflow.CodesFixture do
  @moduledoc """
  Shared fixtures for the codes behaviour and read API tests (GH #3588 / REQ-648).

  `installed_tenant!/1` provisions a real tenant, seeds its event types and installs the real
  `codes` module through the real `Letflow.Routers.TenantModules`. The owner writers go
  through `Letflow.Entities.Records` with
  `ManagedTypes.owner_for!(Letflow.Modules.Codes)`, exactly as the module's own code will
  (the module ships no write functions in this slice).

  This is a `.exs` under `test/letflow/modules/codes/`, NOT a `test/support/**/*.ex`
  file: the R1/R2 caller guard in `managed_types_callers_test.exs` scans `test/support/**/*.ex`
  and rejects `owner_for!(Codes)` outside `lib/letflow/modules/codes`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Records
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @install_opts Letflow.Routers.TenantModules.init([])

  @doc "A provisioned tenant with `codes` installed: `%{tenant_id: _, schema: _}`."
  @spec installed_tenant!(String.t()) :: %{tenant_id: String.t(), schema: String.t()}
  def installed_tenant!(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    install_codes!(tenant.tenant_id)

    %{tenant_id: tenant.tenant_id, schema: tenant.schema_name}
  end

  @doc "Installs `codes` in the tenant through the real router as TENANT_ADMIN; raises unless 201."
  def install_codes!(tenant_id) do
    conn =
      Plug.Test.conn(:post, "/")
      |> Map.put(:body_params, %{
        "module_id" => "codes",
        "rationale" => "GH-3588 test install"
      })
      |> put_req_header("content-type", "application/json")
      |> assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> assign(:trace_id, "gh3588-codes-fixture-trace")
      |> Letflow.Routers.TenantModules.call(@install_opts)

    if conn.status != 201,
      do: raise("codes install failed: #{conn.status} #{conn.resp_body}")

    :ok
  end

  @doc "The Owner authority of the codes module."
  def owner, do: ManagedTypes.owner_for!(Letflow.Modules.Codes)

  @doc "Owner-path create with a fresh actor and idempotency key."
  def create(schema, type, field_values) do
    create(schema, type, field_values, Ecto.UUID.generate())
  end

  @doc "Owner-path create with a fresh actor and an explicit idempotency key."
  def create(schema, type, field_values, key) do
    Records.create_record(
      %{
        entity_type: type,
        field_values: field_values,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: key
      },
      schema,
      owner()
    )
  end

  @doc "Owner-path create that must succeed; returns the stored `Latest` row."
  def create!(schema, type, field_values) do
    {:ok, %{record: record}} = create(schema, type, field_values)
    record
  end

  @doc "Owner-path soft delete that must succeed."
  def delete!(schema, record) do
    {:ok, _} =
      Records.delete_record(
        %{
          entity_type: record.entity_type,
          record_id: record.record_id,
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        schema,
        owner()
      )

    :ok
  end

  @doc "An owner-path code_tag; `extra` overrides fields."
  def tag!(schema, value, extra \\ %{}) do
    create!(schema, "code_tag", values("code_tag", value, extra))
  end

  @doc "An open (or, with `extra`, closed) owner-path code_assignment of `tag` to a target."
  def assign!(schema, tag, target_type, target_id, extra \\ %{}) do
    create!(
      schema,
      "code_assignment",
      values("code_assignment", tag.record_id, %{
        "target_type" => target_type,
        "target_id" => target_id
      })
      |> Map.merge(extra)
    )
  end

  @doc "Closes an assignment row (released_at and released_by set); returns the stored row."
  def release!(schema, assignment, at \\ "2026-11-02T11:00:00Z") do
    update!(
      schema,
      assignment,
      Map.merge(assignment.field_values, %{"released_at" => at, "released_by" => "u-1"})
    )
  end

  @doc "Sets the status of a code_tag (full-document update)."
  def set_status!(schema, tag, status) do
    update!(schema, tag, Map.put(tag.field_values, "status", status))
  end

  @doc "Owner-path full-document update that must succeed; returns the stored `Latest` row."
  def update!(schema, record, field_values) do
    {:ok, %{record: updated}} =
      Records.update_record(
        %{
          entity_type: record.entity_type,
          record_id: record.record_id,
          field_values: field_values,
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        schema,
        owner()
      )

    updated
  end

  @doc "Valid field values for `type`; `extra` overrides or adds. For a history type `a` is the code id."
  def values("code_tag", value, extra) do
    Map.merge(%{"value" => value, "kind" => "barcode", "status" => "not_assigned"}, extra)
  end

  def values("code_assignment", code_id, extra) do
    Map.merge(
      %{
        "code_id" => code_id,
        "target_type" => "location_node",
        "target_id" => Ecto.UUID.generate(),
        "assigned_at" => "2026-11-02T10:00:00Z",
        "assigned_by" => "u-1"
      },
      extra
    )
  end

  def values("code_value_change", code_id, extra) do
    Map.merge(
      %{
        "code_id" => code_id,
        "old_value" => "old",
        "new_value" => "new",
        "changed_at" => "2026-11-02T10:00:00Z",
        "changed_by" => "u-1"
      },
      extra
    )
  end
end
