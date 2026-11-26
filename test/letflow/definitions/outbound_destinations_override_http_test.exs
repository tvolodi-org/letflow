defmodule Letflow.Definitions.OutboundDestinationsOverrideHttpTest do
  @moduledoc """
  T-2597 (pilot gap G14), H6: the solution-pack OVERRIDE ACTIVATION surface answers a
  typed 422 `outbound_destinations_invalid` (never a 500) for an allow-list refusal,
  and activates nothing; the same request answers 200 once the mail channel is listed.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.OutboundDestinations
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t2597-secovr")
    Fixture.pin!(tenant.tenant_id)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "sec-ovr-#{Ecto.UUID.generate()}",
        display_name: "Sec Override Caller",
        email: "sec-ovr-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: token}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: tenant.schema_name
      )

    %{tenant: tenant, token: token, user: user}
  end

  defp declaration do
    %{
      "template_key" => "tenant_registered",
      "recipient" => %{"var" => "admin_email"},
      "values" => %{
        "tenant_name" => %{"var" => "tenant_name"},
        "tenant_slug" => %{"const" => "acme"}
      }
    }
  end

  defp schemas do
    [
      %{variable_key: "admin_email", json_schema: %{"type" => "string"}},
      %{variable_key: "tenant_name", json_schema: %{"type" => "string"}}
    ]
  end

  # START -> the notification step -> END.
  defp notify_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "step",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"notify" => declaration()}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "step"},
        %{"id" => "e2", "source" => "step", "target" => "end"}
      ]
    }
  end

  defp call(method, path, token, tenant, body) do
    method
    |> Fixture.api_conn(path, token, tenant.tenant.slug, body)
    |> Fixture.dispatch_api()
  end

  test "the same activation answers 200 once the mail channel is on the list", ctx do
    {:ok, _entry} =
      OutboundDestinations.add(ctx.tenant.schema_name, ctx.user.id, "email", nil)

    {status, _body, actives} = run_activation(ctx)
    assert status == 200
    assert actives == 1
  end

  test "H6 the override activation answers a typed 422 for the allow-list refusal", ctx do
    {status, body, actives} = run_activation(ctx)

    assert status == 422,
           "expected a typed 422 (outbound_destinations_invalid), got #{status}: #{body}"

    decoded = Jason.decode!(body)
    assert decoded["error"] == "outbound_destinations_invalid"
    assert [%{"node_id" => "step", "code" => code}] = decoded["violations"]
    assert code in ["outbound_channel_not_allowed", "outbound_destination_not_allowed"]
    assert actives == 0
  end

  defp run_activation(ctx) do
    # The installed definition of the pack: a DRAFT (never activated, so the
    # activation fence never ran on it) whose graph reaches outside the tenant.
    {:ok, draft} =
      Definitions.create_with_variable_schemas(
        %{
          name: "sec-ovdef-#{System.unique_integer([:positive])}",
          version: "1.0.0",
          graph: notify_graph(),
          created_by: Ecto.UUID.generate()
        },
        schemas(),
        prefix: ctx.tenant.schema_name
      )

    pack_id = "secpack-#{System.unique_integer([:positive])}"
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    %SolutionPackInstall{}
    |> SolutionPackInstall.insert_changeset(%{
      tenant_id: ctx.tenant.tenant_id,
      pack_id: pack_id,
      installed_version: "1.0.0",
      installed_at: now
    })
    |> Repo.insert!()

    %SolutionPackArtefactBase{}
    |> SolutionPackArtefactBase.upsert_changeset(%{
      tenant_id: ctx.tenant.tenant_id,
      pack_id: pack_id,
      artefact_type: "process_definition",
      artefact_id: draft.id,
      base_version: "1.0.0",
      base_content: "base",
      captured_at: now
    })
    |> Repo.insert!()

    # The rows reference the tenant: delete them before the fixture drops it.
    on_exit(fn ->
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.pack_id == ^pack_id))
      Repo.delete_all(from(i in SolutionPackInstall, where: i.pack_id == ^pack_id))
    end)

    base = "/api/v1/solution-packs/#{pack_id}/overrides"

    created =
      call(:post, base, ctx.token, ctx.tenant, %{
        "artefact_type" => "process_definition",
        "artefact_id" => draft.id,
        "patch" => %{"nodes.step.label" => "Sign"},
        "reason" => "local wording"
      })

    assert created.status == 201, created.resp_body
    override_id = Jason.decode!(created.resp_body)["override_id"]

    activated =
      call(:post, "#{base}/#{override_id}/activate", ctx.token, ctx.tenant, %{
        "reason" => "go live"
      })

    # What the guardrail did: nothing was activated.
    actives =
      Repo.one(
        from(d in ProcessDefinition,
          where: d.status == :active,
          select: count(d.id)
        ),
        prefix: ctx.tenant.schema_name
      )

    {activated.status, activated.resp_body, actives}
  end
end
