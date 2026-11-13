defmodule Letflow.Routers.CurrenciesTest do
  @moduledoc """
  REQ-824 / GH #4393 -- `Letflow.Routers.Currencies` through its own `call/2` (the real Authorize
  plug), over provisioned tenant schemas. Test IDs follow the acceptance criteria:
  R1 read by a user with no admin role, W1..W6 writes and refusals, F1 uniform 403,
  X1 cross-tenant negative (INV-10), A1 audit.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Currencies.init([])
  @keys ["active", "code", "minor_units", "names", "numeric_code"]

  defp tenant!, do: TenantFixture.provisioned_tenant!(slug_prefix: "req824")

  defp call(method, path, t, opts) do
    conn(method, path)
    |> Map.put(:body_params, Keyword.get(opts, :body, %{}))
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Keyword.get(opts, :user_id, Ecto.UUID.generate()),
      tenant_id: t.tenant_id,
      roles: Keyword.get(opts, :roles, ["TENANT_ADMIN"])
    })
    |> assign(:trace_id, "req824-trace")
    |> Letflow.Routers.Currencies.call(@opts)
  end

  defp read(t, opts \\ []) do
    conn = call(:get, "/", t, opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp put(t, code, body, opts \\ []), do: call(:put, "/#{code}", t, [body: body] ++ opts)

  defp find(body, code), do: Enum.find(body["currencies"], &(&1["code"] == code))

  describe "R1 read" do
    test "a user with no admin role reads the directory; keys are exactly the contract" do
      t = tenant!()
      assert {200, body} = read(t, roles: ["TASK_WORKER"])
      assert body["tenant_currency"] == "KZT"
      assert body["currencies"] != []

      for item <- body["currencies"] do
        assert item |> Map.keys() |> Enum.sort() == @keys
        assert item["names"] |> Map.keys() |> Enum.sort() == ["en", "kk", "ru"]
      end

      assert find(body, "KZT")["active"] == true
      assert find(body, "USD")["active"] == false
    end
  end

  describe "W1..W6 writes" do
    test "W1 switching USD on shows in the next GET" do
      t = tenant!()
      conn = put(t, "USD", %{"active" => true})
      assert conn.status == 200
      assert find(Jason.decode!(conn.resp_body), "USD")["active"] == true
      assert {200, body} = read(t)
      assert find(body, "USD")["active"] == true
      assert body["tenant_currency"] == "KZT"
    end

    test "W2 active and tenant_currency true makes USD the tenant currency" do
      t = tenant!()
      conn = put(t, "USD", %{"active" => true, "tenant_currency" => true})
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["tenant_currency"] == "USD"
      assert find(body, "USD")["active"] == true
    end

    test "W3..W6 refusals are 422 with a fixed reason and leave the GET body unchanged" do
      t = tenant!()
      {200, before_body} = read(t)

      cases = [
        {"USD", %{"tenant_currency" => true}, "invalid_body"},
        {"KZT", %{"active" => false}, "currency_is_tenant_currency"},
        {"ABC", %{"active" => true}, "currency_unknown"},
        {"USD", %{"active" => true, "other" => 1}, "invalid_body"}
      ]

      for {code, body, reason} <- cases do
        conn = put(t, code, body)
        assert conn.status == 422, reason
        assert conn.resp_body =~ reason
        refute conn.resp_body =~ "other"
        assert {200, ^before_body} = read(t)
      end
    end
  end

  describe "F1 uniform 403" do
    test "a user without CurrenciesManage gets the same body for a known and an unknown code" do
      t = tenant!()

      for role <- ["TASK_WORKER", "TENANT_AUDITOR", "PROCESS_DESIGNER"] do
        known = put(t, "USD", %{"active" => true}, roles: [role])
        unknown = put(t, "ABC", %{"active" => true}, roles: [role])
        assert known.status == 403
        assert unknown.status == 403
        assert drop_trace(known.resp_body) == drop_trace(unknown.resp_body)
      end

      assert {200, body} = read(t)
      assert find(body, "USD")["active"] == false
    end

    test "the platform admin is refused outside the platform tenant" do
      t = tenant!()
      assert put(t, "USD", %{"active" => true}, roles: ["PLATFORM_ADMIN"]).status == 403
    end
  end

  describe "X1 cross-tenant (INV-10)" do
    test "tenant B's id in body and query changes nothing in tenant B" do
      a = tenant!()
      b = tenant!()

      conn =
        conn(:put, "/USD?tenant_id=#{b.tenant_id}")
        |> Map.put(:body_params, %{"active" => true, "tenant_id" => b.tenant_id})
        |> put_req_header("content-type", "application/json")
        |> assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: a.tenant_id,
          roles: ["TENANT_ADMIN"]
        })
        |> assign(:trace_id, "req824-trace")
        |> Letflow.Routers.Currencies.call(@opts)

      # the extra body key is refused, and the same call without it changes only tenant A
      assert conn.status == 422

      assert put(a, "USD", %{"active" => true}).status == 200
      assert {200, body_b} = read(b)
      assert find(body_b, "USD")["active"] == false

      assert Repo.all(from(s in Letflow.Currencies.Switch, select: s.code), prefix: b.schema_name) ==
               []

      assert Repo.all(from(s in Letflow.Currencies.Switch, select: s.code), prefix: a.schema_name) ==
               ["USD"]
    end
  end

  describe "A1 audit" do
    test "an accepted switch writes one currencies.switched entry; a refusal writes none" do
      t = tenant!()

      count = fn ->
        Repo.aggregate(from(e in Entry, where: e.action == "currencies.switched"), :count,
          prefix: t.schema_name
        )
      end

      assert put(t, "ABC", %{"active" => true}).status == 422
      assert count.() == 0
      assert put(t, "USD", %{"active" => true}).status == 200
      assert count.() == 1
    end
  end

  defp drop_trace(body), do: body |> Jason.decode!() |> Map.drop(["trace_id"])
end
