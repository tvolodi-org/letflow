defmodule Letflow.Routers.OutboundDestinationsTest do
  @moduledoc """
  T-2597 (pilot gap G14) -- `Letflow.Routers.OutboundDestinations` through its own `call/2` (the
  real Authorize plug), over provisioned tenant schemas.

  Test ids follow the acceptance criteria: R1 the list, W1..W3 the writes and their
  refusals, F1 the uniform 403, X1 the cross-tenant negative (INV-10), A1 the audit.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Audit.Entry
  alias Letflow.TenantFixture

  @opts Letflow.Routers.OutboundDestinations.init([])

  defp tenant! do
    TenantFixture.provisioned_tenant!(slug_prefix: "t2597-router")
  end

  defp call(method, path, t, opts) do
    conn(method, path)
    |> Map.put(:body_params, Keyword.get(opts, :body, %{}))
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Keyword.get(opts, :user_id, Ecto.UUID.generate()),
      tenant_id: t.tenant_id,
      roles: Keyword.get(opts, :roles, ["TENANT_ADMIN"])
    })
    |> assign(:trace_id, "t2597-trace")
    |> Letflow.Routers.OutboundDestinations.call(@opts)
  end

  defp read(t, opts \\ []), do: call(:get, "/", t, opts)

  defp post(t, body, opts \\ []), do: call(:post, "/", t, [body: body] ++ opts)

  defp delete(t, query, opts \\ []) do
    call(:delete, "/?#{query}", t, opts)
  end

  describe "R1 the list" do
    test "R1 a fresh tenant's list is EMPTY: the tenant may reach nothing outside" do
      t = tenant!()

      conn = read(t)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["entries"] == []
    end

    test "R2 a TENANT_ADMIN adds a channel and a destination, and reads them back" do
      t = tenant!()

      assert post(t, %{"channel" => "email"}).status == 201

      assert post(t, %{"channel" => "email", "destination" => "uat.letflow.internal"}).status ==
               201

      conn = read(t)
      assert conn.status == 200

      entries = Jason.decode!(conn.resp_body)["entries"]

      assert %{"channel" => "email", "destination" => nil} =
               Enum.find(entries, &is_nil(&1["destination"]))

      assert %{"channel" => "email", "destination" => "uat.letflow.internal"} =
               Enum.find(entries, &(&1["destination"] == "uat.letflow.internal"))
    end
  end

  describe "W1..W3 the writes and their refusals" do
    test "W1 a destination that is not a name is refused with 422 and nothing is written" do
      t = tenant!()

      conn = post(t, %{"channel" => "email", "destination" => "person@example.com"})
      assert conn.status == 422

      assert Jason.decode!(conn.resp_body)["detail"] == "destination is invalid"
      assert Jason.decode!(read(t).resp_body)["entries"] == []
    end

    test "W2 an unknown channel is refused with 422" do
      t = tenant!()

      conn = post(t, %{"channel" => "telegram"})
      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["detail"] == "channel is invalid"
    end

    test "W3 removing an entry that is not there answers 404" do
      t = tenant!()

      conn = delete(t, "channel=email")
      assert conn.status == 404
    end
  end

  describe "F1 the authority" do
    test "F1 a PROCESS_DESIGNER is refused on every route with the same 403" do
      t = tenant!()

      for conn <- [
            read(t, roles: ["PROCESS_DESIGNER"]),
            post(t, %{"channel" => "email"}, roles: ["PROCESS_DESIGNER"]),
            delete(t, "channel=email", roles: ["PROCESS_DESIGNER"])
          ] do
        assert conn.status == 403
      end

      # The refusal wrote nothing.
      assert Jason.decode!(read(t).resp_body)["entries"] == []
    end
  end

  describe "X1 the cross-tenant negative (INV-10)" do
    test "X1 one tenant's list is not another's" do
      a = tenant!()
      b = tenant!()

      assert post(a, %{"channel" => "email"}).status == 201

      assert post(a, %{"channel" => "email", "destination" => "uat.letflow.internal"}).status ==
               201

      assert Jason.decode!(read(b).resp_body)["entries"] == []
    end
  end

  describe "A1 the audit" do
    test "A1 every change is an audit row with the actor" do
      t = tenant!()
      user = Ecto.UUID.generate()

      assert post(t, %{"channel" => "email"}, user_id: user).status == 201

      rows = Repo.all(Entry, prefix: t.schema_name)
      added = Enum.find(rows, &(&1.action == "outbound_destinations.add"))

      assert added.actor_id == user
      assert added.resource_type == "outbound_destination"
    end
  end
end
