defmodule Letflow.Routers.EntitiesAttachmentsManagedByTest do
  @moduledoc """
  GH #2582 (decision 0050 D7, REQ-496): the record ATTACHMENT write routes of
  `Letflow.Routers.Entities` (upload, delete) refuse a module-managed entity type with the same
  constant 403 as the record routes (`Letflow.Api.Error.entity_type_managed/0`), while the owning
  module's own `EntityAttachments` calls still write. Reads (list, content GET) are unchanged.

  The test-only `Letflow.Modules.FixtureManaged` is installed through the real
  `Letflow.Modules.Installs.install/3` (`fxm_site` managed, `fxm_free` the unmanaged control).
  Requests go straight into `Letflow.Routers.Entities` with a hand-assigned `auth_context` and a
  pinned `trace_id`, as `entities_managed_by_test.exs` does.

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Api.Error
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EventTypes
  alias Letflow.Identity.User
  alias Letflow.Modules.FixtureManaged
  alias Letflow.Modules.Installs
  alias Letflow.Repository.EntityAttachments
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @entities_opts Letflow.Routers.Entities.init([])
  @trace "gh2582-managed-attachments-fixed-trace"
  @managed "fxm_site"
  @free "fxm_free"
  @admin ["TENANT_ADMIN"]
  @operator ["PROCESS_OPERATOR"]

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2582-att")

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    user = insert_user!(tenant.schema_name)

    {:ok, _tenant_module} =
      Installs.install("fixture_managed", user.id,
        prefix: tenant.schema_name,
        rationale: "GH #2582 test install"
      )

    {:ok, tenant_id: tenant.tenant_id, schema: tenant.schema_name, actor_id: user.id}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp insert_user!(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2582-user-#{Ecto.UUID.generate()}",
      display_name: "GH-2582 Test User",
      email: "gh2582-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp call_entities(ctx, roles, method, path, body \\ nil) do
    conn = Plug.Test.conn(method, path)
    conn = if body, do: %{conn | body_params: body}, else: conn

    conn
    |> assign(:auth_context, %{user_id: ctx.actor_id, tenant_id: ctx.tenant_id, roles: roles})
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.Entities.call(@entities_opts)
  end

  defp managed_body, do: Error.serialise(%{Error.entity_type_managed() | trace_id: @trace})

  defp assert_managed!(conn) do
    assert conn.status == 403, "#{conn.status} #{conn.resp_body}"
    assert conn.resp_body == managed_body()
  end

  defp upload_body do
    path = Path.join(System.tmp_dir!(), "gh2582-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "ATTACHMENT-BYTES")
    on_exit(fn -> File.rm(path) end)

    %{"file" => %Plug.Upload{path: path, filename: "note.txt", content_type: "text/plain"}}
  end

  defp owner_record!(ctx, type) do
    {:ok, %{record: record}} =
      FixtureManaged.create_record(type, %{"name" => "seeded by owner"}, ctx.schema)

    record
  end

  # The owning module's own path: `EntityAttachments` has no caller gate.
  defp owner_attach!(ctx, type, record_id) do
    {:ok, attachment} =
      EntityAttachments.upload(
        %{
          entity_type: type,
          record_id: record_id,
          raw_bytes: "OWNER-BYTES",
          file_name: "owner.txt",
          content_type: "text/plain",
          uploaded_by: ctx.actor_id,
          description: nil
        },
        prefix: ctx.schema
      )

    attachment
  end

  defp attachments_path(type, id), do: "/records/#{type}/#{id}/attachments"

  defp attachment_count(ctx),
    do: Repo.aggregate("entity_record_attachments", :count, prefix: ctx.schema)

  # ── tests ───────────────────────────────────────────────────────────────────────────────────

  describe "upload: POST /records/:type/:id/attachments" do
    test "a non-owner (admin and operator) gets the constant 403 and nothing is written", ctx do
      record = owner_record!(ctx, @managed)
      before = attachment_count(ctx)

      for roles <- [@admin, @operator] do
        conn =
          call_entities(
            ctx,
            roles,
            :post,
            attachments_path(@managed, record.record_id),
            upload_body()
          )

        assert_managed!(conn)
      end

      assert attachment_count(ctx) == before
    end

    test "the owner module still attaches to its own record", ctx do
      record = owner_record!(ctx, @managed)
      attachment = owner_attach!(ctx, @managed, record.record_id)
      assert attachment.entity_type == @managed
      assert attachment_count(ctx) == 1
    end

    test "an unmanaged type is unchanged: 201", ctx do
      {:ok, %{record: record}} =
        FixtureManaged.create_record(@free, %{"name" => "free"}, ctx.schema)

      conn =
        call_entities(
          ctx,
          @admin,
          :post,
          attachments_path(@free, record.record_id),
          upload_body()
        )

      assert conn.status == 201, conn.resp_body
    end
  end

  describe "delete: DELETE /records/:type/:id/attachments/:att" do
    test "a non-owner gets the constant 403 and the attachment stays", ctx do
      record = owner_record!(ctx, @managed)
      attachment = owner_attach!(ctx, @managed, record.record_id)

      for roles <- [@admin, @operator] do
        conn =
          call_entities(
            ctx,
            roles,
            :delete,
            attachments_path(@managed, record.record_id) <> "/#{attachment.id}"
          )

        assert_managed!(conn)
      end

      assert {:ok, _} = EntityAttachments.get(attachment.id, prefix: ctx.schema)
    end

    test "the owner module still deletes its own attachment", ctx do
      record = owner_record!(ctx, @managed)
      attachment = owner_attach!(ctx, @managed, record.record_id)

      assert {:ok, _} = EntityAttachments.delete(attachment.id, prefix: ctx.schema)
      assert {:error, :not_found} = EntityAttachments.get(attachment.id, prefix: ctx.schema)
    end
  end

  describe "a type hidden from the caller takes the absent path, not the managed 403 (INV-5)" do
    test "upload and delete answer 404 for a caller denied by TypeAccess on a managed type",
         ctx do
      record = owner_record!(ctx, @managed)
      attachment = owner_attach!(ctx, @managed, record.record_id)

      Repo.insert_all(
        "entity_type_restrictions",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: @managed,
            inserted_at: NaiveDateTime.utc_now(),
            updated_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: ctx.schema
      )

      upload =
        call_entities(
          ctx,
          @operator,
          :post,
          attachments_path(@managed, record.record_id),
          upload_body()
        )

      assert upload.status == 404, "#{upload.status} #{upload.resp_body}"

      delete =
        call_entities(
          ctx,
          @operator,
          :delete,
          attachments_path(@managed, record.record_id) <> "/#{attachment.id}"
        )

      assert delete.status == 404, "#{delete.status} #{delete.resp_body}"
      assert {:ok, _} = EntityAttachments.get(attachment.id, prefix: ctx.schema)
    end
  end

  describe "reads are unchanged on a managed type" do
    test "list and content GET still answer 200", ctx do
      record = owner_record!(ctx, @managed)
      attachment = owner_attach!(ctx, @managed, record.record_id)

      list = call_entities(ctx, @admin, :get, attachments_path(@managed, record.record_id))
      assert list.status == 200, list.resp_body
      assert [%{"id" => id}] = Jason.decode!(list.resp_body)["items"]
      assert id == attachment.id

      content =
        call_entities(
          ctx,
          @admin,
          :get,
          attachments_path(@managed, record.record_id) <> "/#{attachment.id}"
        )

      assert content.status == 200
      assert content.resp_body == "OWNER-BYTES"
    end
  end
end
