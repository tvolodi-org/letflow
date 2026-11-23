defmodule Letflow.Routers.NotificationTemplatesCatalogueTest do
  @moduledoc """
  T-2600 (pilot gap G5b) -- `GET /notification-templates/catalogue`: the COMPILED catalogue of the
  registered template keys and their placeholder allow-lists, the read the designer's template
  picker needs to offer a template without code.

  C1 the answer names every registered key with its placeholder allow-list, C2 the answer carries
  no template TEXT (platform data only: no subject, no body, no tenant override), C3 a caller
  without `:DefinitionsRead` gets the uniform 403, C4 a definition reader (PROCESS_DESIGNER) may
  read it, C5 the catalogue answers in every tenant (it is compiled, not tenant data).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.NotificationTemplates.Registry
  alias Letflow.TenantFixture

  @opts Letflow.Routers.NotificationTemplates.init([])

  defp tenant!, do: TenantFixture.provisioned_tenant!(slug_prefix: "t2600")

  defp call(t, opts \\ []) do
    conn(:get, "/catalogue")
    |> assign(:auth_context, %{
      user_id: Keyword.get(opts, :user_id, Ecto.UUID.generate()),
      tenant_id: t.tenant_id,
      roles: Keyword.get(opts, :roles, ["PROCESS_DESIGNER"])
    })
    |> assign(:trace_id, "t2600-trace")
    |> Letflow.Routers.NotificationTemplates.call(@opts)
  end

  defp catalogue(t, opts \\ []) do
    conn = call(t, opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "C1 the answer names every registered key with its placeholders" do
    t = tenant!()
    assert {200, %{"items" => items}} = catalogue(t)

    keys = Enum.map(items, & &1["template_key"])
    assert keys == Registry.keys()
    assert "tenant_registered" in keys

    for item <- items do
      assert item["placeholders"] == Registry.placeholders(item["template_key"])
    end

    registered = Enum.find(items, &(&1["template_key"] == "tenant_registered"))
    assert registered["placeholders"] == ["tenant_name", "tenant_slug", "registered_by"]
  end

  test "C2 the answer carries no template text and no tenant data" do
    t = tenant!()
    conn = call(t)
    body = Jason.decode!(conn.resp_body)

    # The compiled catalogue is keys and placeholder NAMES only: no subject, no body, no locale.
    for item <- body["items"] do
      assert Map.keys(item) |> Enum.sort() == ["placeholders", "template_key"]
    end

    refute conn.resp_body =~ "Hello"
    refute conn.resp_body =~ "subject"
    refute conn.resp_body =~ "body"
    refute conn.resp_body =~ "locale"
  end

  test "C3 a caller without DefinitionsRead gets the uniform 403" do
    t = tenant!()

    for role <- ["CANDIDATE", "AGENT_RUNNER", "STOREKEEPER"] do
      conn = call(t, roles: [role])
      assert conn.status == 403, role
      assert Jason.decode!(conn.resp_body)["detail"] == "insufficient permissions", role
    end
  end

  test "C4 a definition reader may read the catalogue" do
    t = tenant!()

    for role <- ["PROCESS_DESIGNER", "TASK_WORKER", "TENANT_ADMIN", "TENANT_AUDITOR"] do
      assert {200, %{"items" => items}} = catalogue(t, roles: [role])
      assert items != [], role
    end
  end

  test "C5 the catalogue is the same in every tenant (it is compiled, not tenant data)" do
    a = tenant!()
    b = tenant!()
    assert {200, %{"items" => first}} = catalogue(a)
    assert {200, %{"items" => second}} = catalogue(b)
    assert first == second
  end
end
