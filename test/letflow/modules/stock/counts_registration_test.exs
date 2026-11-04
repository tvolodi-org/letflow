Code.require_file("counts_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountsRegistrationTest do
  @moduledoc """
  REQ-700 / GH #3737 criterion 1 (R-MANIFEST, R-INSTALL): the manifest of module `stock` 0.2.0 and what an
  install of it leaves in a fresh tenant: three active managed types, a closed generic entity route, four
  document types, a second install that changes nothing.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.CountsFixture, as: F
  alias Letflow.Documents.DocumentType
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Stock

  test "R-MANIFEST one new permission atom, three managed scoped types, no role grants" do
    m = Stock.manifest()
    assert Catalog.validate(m) == :ok

    assert m.permissions ==
             [:StockPost, :StockReverse, :StockRead, :StockReconcile, :StockCountOrder]

    refute :StockCountRecord in m.permissions
    assert m.role_grants == %{}

    assert m.manages_entity_types == [
             "count_order",
             "count_order_scope",
             "count_commission_member"
           ]

    assert Map.values(m.scope_declarations) |> Enum.uniq() == [{:column, "org_unit_id"}]
    assert Map.keys(m.scope_declarations) |> Enum.sort() == Enum.sort(m.manages_entity_types)
    assert m.depends_on == ["org", "locations"]

    for {_method, _path, permission} <- m.route_policies,
        do: assert(permission in m.permissions)
  end

  test "R-INSTALL the install activates the types and registers the four document types" do
    t = F.tenant!()
    s = t.schema

    rows =
      Repo.all(
        from(d in EntityDefinition, select: {d.name, d.managed_by, d.status}, order_by: d.name),
        prefix: s
      )

    assert Enum.filter(rows, &(elem(&1, 1) == "stock")) ==
             Enum.map(
               ~w(count_commission_member count_order count_order_scope),
               &{&1, "stock", :active}
             )

    assert Letflow.Entities.ScopeDeclaration.for_type("count_order", s) ==
             {:column, "org_unit_id"}

    for type <- ~w(count_order count_order_scope count_commission_member) do
      conn =
        Plug.Test.conn(:post, "/records/#{type}")
        |> Map.put(:body_params, %{"field_values" => %{"kind" => "full"}})
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: t.tenant_id,
          roles: ["TENANT_ADMIN"]
        })
        |> Plug.Conn.assign(:trace_id, "req700-install-trace")
        |> Letflow.Routers.Entities.call(Letflow.Routers.Entities.init([]))

      assert conn.status == 403 and conn.resp_body =~ "entity_type_managed", type
    end

    types = Repo.all(from(d in DocumentType, order_by: d.key), prefix: s)

    assert Enum.map(types, &{&1.key, &1.number_prefix}) ==
             [
               {"count.differences", "CD"},
               {"count.order", "CO"},
               {"count.posting", "CP"},
               {"count.sheet", "CS"}
             ]

    for type <- types do
      assert type.owner_module == "stock"
      assert type.numbering_scope == :year
      assert type.legal_entity_required == false
    end

    # registering the same four types again changes nothing (an equal registration is a no-op)
    ctx = %{actor_id: Ecto.UUID.generate(), rationale: "test: REQ-700"}

    for type <- types do
      attrs = %{
        key: type.key,
        owner_module: "stock",
        numbering_scope: :year,
        number_prefix: type.number_prefix,
        number_pad: 4,
        legal_entity_required: false,
        declared_fields: %{}
      }

      assert {:ok, _} = Letflow.Documents.register_type(s, attrs, ctx)
    end

    assert length(Repo.all(DocumentType, prefix: s)) == 4
  end
end
