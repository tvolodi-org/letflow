defmodule Letflow.Routers.NumberSequencesTest do
  @moduledoc """
  REQ-575 / GH #3263: the `/number-sequences` routes. Each test names its design ID and the
  REQ-575 criterion (C1/C1b/L1 criteria 1-2, F criterion 3, P1 criterion 4, X1 criterion 6,
  X2 criterion 7, A1 audit).

  Dispatch: real `Letflow.Routers.NumberSequences.call/2` (and `Letflow.Routers.Entities.call/2`
  for C1b). Sandbox `:auto` mode with committed tenants, as `RecordsNumberingTest`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Audit
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.NumberSequences
  alias Letflow.NumberSequences.Number
  alias Letflow.Repo
  alias Letflow.Routers.NumberSequences, as: Router
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  @opts Router.init([])
  @admin ["TENANT_ADMIN"]

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    base = Fx.committed_tenant_case!("gh3263")

    on_exit(fn ->
      Application.delete_env(:letflow, :number_sequences_clock)
      Fx.drop_committed_tenant!(base.tenant.tenant_id)
      SandboxAutoMode.exit_auto_mode!(Repo)
    end)

    Fx.define_type!(base.schema, "ns_order", %{append_only: false})
    Fx.define_type!(base.schema, "ns_other", %{append_only: false})
    Fx.define_type!(base.schema, "ns_log", %{})
    %{base: base}
  end

  defp call(base, method, path, roles, body \\ %{}) do
    conn(method, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: base.tenant.tenant_id,
      roles: roles
    })
    |> assign(:scoped_opts, prefix: base.schema)
    |> assign(:trace_id, "req575-trace")
    |> Router.call(@opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "key" => "order_no",
        "entity_type" => "ns_order",
        "prefix" => "ORD",
        "padding" => 6,
        "period" => "year"
      },
      overrides
    )
  end

  defp items(base), do: base |> call(:get, "/", @admin) |> json() |> Map.fetch!("items")

  defp audit_count(base) do
    {:ok, %{items: items}} =
      Audit.list_entries(%{
        prefix: base.schema,
        page_size: 100,
        resource_type: "number_sequence_definition"
      })

    length(items)
  end

  defp other_tenant!(tenants_slug) do
    other = Fx.committed_tenant_case!(tenants_slug)
    on_exit(fn -> Fx.drop_committed_tenant!(other.tenant.tenant_id) end)
    other
  end

  test "C1 create answers 201 with the documented fields and GET lists it", %{base: base} do
    conn = call(base, :post, "/", @admin, attrs())
    assert conn.status == 201
    created = json(conn)

    assert Enum.sort(Map.keys(created)) ==
             ~w(entity_type id inserted_at key padding period prefix)

    assert %{"key" => "order_no", "entity_type" => "ns_order", "prefix" => "ORD"} = created
    assert %{"padding" => 6, "period" => "year"} = created
    assert items(base) == [created]
  end

  test "C1 padding 1 and 12 are accepted", %{base: base} do
    assert call(base, :post, "/", @admin, attrs(%{"padding" => 1})).status == 201

    other = attrs(%{"key" => "other_no", "entity_type" => "ns_other", "padding" => 12})
    assert call(base, :post, "/", @admin, other).status == 201
  end

  test "C1b a record created through the existing route gets ORD-<year>-000001", %{base: base} do
    assert call(base, :post, "/", @admin, attrs()).status == 201

    conn =
      conn(:post, "/records/ns_order")
      |> Map.put(:body_params, %{
        "field_values" => %{"label" => "x"},
        "idempotency_key" => Fx.unique("k")
      })
      |> put_req_header("content-type", "application/json")
      |> assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: base.tenant.tenant_id,
        roles: @admin
      })
      |> assign(:trace_id, "req575-c1b")
      |> Letflow.Routers.Entities.call(Letflow.Routers.Entities.init([]))

    assert conn.status in 200..299, conn.resp_body

    assert [%{formatted: value}] = Repo.all(Number, prefix: base.schema)
    assert value == "ORD-#{Date.utc_today().year}-000001"
  end

  test "L1 an empty tenant lists [] and the list is ordered by key", %{base: base} do
    empty = call(base, :get, "/", @admin)
    assert {empty.status, json(empty)} == {200, %{"items" => []}}

    assert call(base, :post, "/", @admin, attrs(%{"key" => "z_no"})).status == 201

    second = attrs(%{"key" => "a_no", "entity_type" => "ns_other"})
    assert call(base, :post, "/", @admin, second).status == 201

    assert Enum.map(items(base), & &1["key"]) == ["a_no", "z_no"]
  end

  describe "F1..F9 refusals answer 422 and store nothing" do
    test "each case", %{base: base} do
      assert call(base, :post, "/", @admin, attrs()).status == 201
      :ok = Fx.install_managed_fixture!(base.schema)
      before_items = items(base)

      cases = [
        {"unknown type", attrs(%{"key" => "k1", "entity_type" => "ns_missing"})},
        {"managed type", attrs(%{"key" => "k2", "entity_type" => "fxm_ledger"})},
        {"append-only type", attrs(%{"key" => "k3", "entity_type" => "ns_log"})},
        {"duplicate key", attrs(%{"entity_type" => "ns_other"})},
        {"second definition on a type", attrs(%{"key" => "k4"})},
        {"prefix too long",
         attrs(%{"key" => "k5", "entity_type" => "ns_other", "prefix" => "ABCDEFGHI"})},
        {"prefix with dash",
         attrs(%{"key" => "k5", "entity_type" => "ns_other", "prefix" => "A-B"})},
        {"padding 0", attrs(%{"key" => "k5", "entity_type" => "ns_other", "padding" => 0})},
        {"padding 13", attrs(%{"key" => "k5", "entity_type" => "ns_other", "padding" => 13})},
        {"bad period", attrs(%{"key" => "k5", "entity_type" => "ns_other", "period" => "month"})}
      ]

      missing =
        for field <- ~w(key entity_type prefix padding period) do
          {"missing #{field}",
           Map.delete(attrs(%{"key" => "k6", "entity_type" => "ns_other"}), field)}
        end

      for {label, body} <- cases ++ missing do
        conn = call(base, :post, "/", @admin, body)
        assert conn.status == 422, "#{label}: #{conn.resp_body}"
        assert {"content-type", ct} = List.keyfind(conn.resp_headers, "content-type", 0)
        assert ct =~ "application/problem+json", label
        refute conn.resp_body =~ "ns_missing", label
        assert items(base) == before_items, label
      end

      assert audit_count(base) == 1
    end

    test "one 422 text for a managed, append-only and unknown type", %{base: base} do
      :ok = Fx.install_managed_fixture!(base.schema)

      bodies =
        for type <- ["fxm_ledger", "ns_log", "ns_missing"] do
          call(base, :post, "/", @admin, attrs(%{"entity_type" => type})).resp_body
        end

      assert length(Enum.uniq(bodies)) == 1
    end

    test "a tenant_id in the body is ignored", %{base: base} do
      foreign = Ecto.UUID.generate()
      conn = call(base, :post, "/", @admin, attrs(%{"tenant_id" => foreign}))
      assert conn.status == 201
      refute Map.has_key?(json(conn), "tenant_id")
      assert [%{tenant_id: tenant_id}] = Repo.all(NumberSequences.Definition, prefix: base.schema)
      assert tenant_id == base.tenant.tenant_id
    end
  end

  describe "P1 permission (INV-5)" do
    test "other tenant roles get an identical 403 on both routes", %{base: base} do
      for role <- ["PROCESS_DESIGNER", "TASK_WORKER", "TENANT_AUDITOR"] do
        assert call(base, :get, "/", [role]).status == 403, role

        valid = call(base, :post, "/", [role], attrs())
        invalid = call(base, :post, "/", [role], %{"key" => "x"})
        assert valid.status == 403, role

        observe = fn c ->
          {c.status, c.resp_body, List.keyfind(c.resp_headers, "content-type", 0)}
        end

        assert observe.(valid) == observe.(invalid), role
      end

      assert items(base) == []
      assert audit_count(base) == 0
    end
  end

  test "A1 a create writes one audit entry and a refusal writes none", %{base: base} do
    assert call(base, :post, "/", @admin, attrs()).status == 201
    assert audit_count(base) == 1
    assert call(base, :post, "/", @admin, attrs(%{"padding" => 0})).status == 422
    assert audit_count(base) == 1
  end

  test "X1 tenants are isolated and a tenant_id in body or query lands in the caller's tenant",
       %{base: a} do
    b = other_tenant!("gh3263-b")
    Fx.define_type!(b.schema, "ns_order", %{append_only: false})

    created = a |> call(:post, "/", @admin, attrs()) |> json()
    assert items(b) == []
    assert items(a) == [created]

    # B reuses A's key and entity type name.
    assert call(b, :post, "/", @admin, attrs()).status == 201

    # tenant_id of A in B's body and query string
    smuggle =
      attrs(%{"key" => "b2_no", "entity_type" => "ns_other", "tenant_id" => a.tenant.tenant_id})

    Fx.define_type!(b.schema, "ns_other", %{append_only: false})
    assert call(b, :post, "/?tenant_id=#{a.tenant.tenant_id}", @admin, smuggle).status == 201

    assert Enum.map(items(b), & &1["key"]) == ["b2_no", "order_no"]
    assert Enum.map(items(a), & &1["key"]) == ["order_no"]
    assert [%{tenant_id: tid} | _] = Repo.all(NumberSequences.Definition, prefix: b.schema)
    assert tid == b.tenant.tenant_id
  end

  test "X2 a PLATFORM_ADMIN sees only the platform tenant's own definitions", %{base: a} do
    p = other_tenant!("gh3263-p")
    Fx.define_type!(p.schema, "ns_order", %{append_only: false})

    assert call(a, :post, "/", @admin, attrs(%{"key" => "tenant_a_no"})).status == 201
    assert call(p, :post, "/", @admin, attrs(%{"key" => "plat_no"})).status == 201

    PlatformTenantFixture.pin!(p.tenant.tenant_id)

    conn = call(p, :get, "/", ["PLATFORM_ADMIN"])
    assert conn.status == 200
    assert conn |> json() |> Map.fetch!("items") |> Enum.map(& &1["key"]) == ["plat_no"]

    # outside the platform tenant the role has no such permission
    assert call(a, :get, "/", ["PLATFORM_ADMIN"]).status == 403
  end
end
