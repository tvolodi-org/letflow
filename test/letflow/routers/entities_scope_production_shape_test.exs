defmodule Letflow.Routers.EntitiesScopeProductionShapeTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-ii, T-W21 and T-W18 (design `lib/letflow/design/req518-compiler-scope-filter.md`
  F3, 5.3, R-3, R-8, 10.2; spec `test/specs/REQ-518-2c-ii.md`; SEC code-gate step-17 merge
  condition and design-gate C-5): what a scoped caller meets in PRODUCTION, where no module may
  declare an UNMANAGED type (the test-only allowlist
  `:scope_declaration_unmanaged_modules` is `[]`).

  With the allowlist emptied the fixture types `scoped_item`, `scoped_child` and `scoped_master`
  are UNDECLARED and only the MANAGED `scoped_managed_item` keeps its declaration. For a scoped
  OIDC user (stored mode `on`, `TENANT_ADMIN` at subtree `a`) through the FULL router:

    * a declared MANAGED type is the constant 403 `entity_type_managed` on POST, PUT, DELETE and
      import, whatever the id, body or scope (T-W18: independent of scope, equal to what a
      tenant-wide caller gets);
    * an UNDECLARED and a `:tenant_wide`-declared type are the generic 404 on every write route,
      byte for byte the answer for a NONEXISTENT type, and the four attachment routes answer as
      for a nonexistent parent (create 404, list the empty page, content GET and delete 404);
    * a database assertion after every refused call: no row, event, attachment or artifact was
      written, no stored value changed, no attachment removed.

  Record attachments of a MANAGED type are outside the managed-type lock by design (#2582): the
  design's T-W21 sentence lists a 403 for them too, but the as-built attachment routes have no
  managed check; the observed behavior (a record in scope is served, an out-of-scope one is the
  nonexistent answer) is pinned below and reported.

  `async: false`: a dedicated provisioned OIDC tenant, committed writes, VM-global config
  (the allowlist is restored in `on_exit`).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Records
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScopeWritesFixture, as: W

  @managed "scoped_managed_item"
  @empty_page %{"items" => [], "next_cursor" => nil}
  @key :scope_declaration_unmanaged_modules

  setup do
    fx = W.provision!("r518-wp")
    managed_a = create_managed!(fx, "sf-a")
    managed_b = create_managed!(fx, "sf-b")
    master = F.create!(fx.schema_name, "scoped_master", %{"name" => "master"})

    {:ok,
     fx: fx,
     managed_a: managed_a,
     managed_b: managed_b,
     master: master,
     att_item: W.attach!(fx, "scoped_item", fx.items.a.record_id),
     att_master: W.attach!(fx, "scoped_master", master.record_id),
     att_managed_a: W.attach!(fx, @managed, managed_a.record_id),
     att_managed_b: W.attach!(fx, @managed, managed_b.record_id)}
  end

  defp create_managed!(fx, node) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: @managed,
          field_values: %{"name" => "managed-#{node}", "scope_node" => node},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        fx.schema_name,
        ManagedTypes.owner_for!(Letflow.Modules.FixtureScoped)
      )

    record
  end

  defp production_allowlist! do
    original = Application.get_env(:letflow, @key)
    Application.put_env(:letflow, @key, [])
    on_exit(fn -> Application.put_env(:letflow, @key, original) end)
  end

  # every write route as the scoped caller for `type` and (when given) a record id; returns
  # `[{label, conn}]`
  defp write_calls(fx, type, id) do
    body = W.item_body("sf-a")

    [
      {"POST", W.request(fx, :post, W.records_path(type, nil), body)},
      {"PUT", W.request(fx, :put, W.records_path(type, id), body)},
      {"DELETE", W.request(fx, :delete, W.records_path(type, id), nil)},
      {"IMPORT", W.request(fx, :post, W.import_path(type), W.import_body(type, ["sf-a"]))}
    ]
  end

  defp attachment_calls(fx, type, id, attachment_id) do
    [
      {"attach create", W.multipart(fx, W.attachments_path(type, id), :file)},
      {"attach list", W.request(fx, :get, W.attachments_path(type, id), nil)},
      {"attach content", W.request(fx, :get, W.item_path(type, id, attachment_id), nil)},
      {"attach delete", W.request(fx, :delete, W.item_path(type, id, attachment_id), nil)}
    ]
  end

  # ===========================================================================================
  describe "T-W18 the managed-type lock is independent of scope" do
    test "managed type: one constant 403 for any id, body and node; same bytes as for a tenant-wide caller",
         %{fx: fx, managed_a: a, managed_b: b} do
      before = W.counts(fx)

      answers =
        for id <- [a.record_id, b.record_id, Ecto.UUID.generate(), "not-a-uuid"],
            {label, conn} <- write_calls(fx, @managed, id) do
          assert conn.status == 403, "#{label} #{id}: #{conn.resp_body}"
          {label, W.norm(conn)}
        end

      for label <- ["POST", "PUT", "DELETE", "IMPORT"] do
        distinct = answers |> Enum.filter(&(elem(&1, 0) == label)) |> Enum.uniq_by(&elem(&1, 1))
        assert length(distinct) == 1, "#{label}: one answer whatever the id"
      end

      wide =
        for {label, call} <- [
              {"POST",
               W.admin_request(fx, :post, W.records_path(@managed, nil), W.item_body("sf-a"))},
              {"PUT",
               W.admin_request(
                 fx,
                 :put,
                 W.records_path(@managed, a.record_id),
                 W.item_body("sf-a")
               )}
            ] do
          {label, W.norm(call)}
        end

      for {label, norm} <- wide do
        assert norm == answers |> Enum.find(&(elem(&1, 0) == label)) |> elem(1), label
      end

      assert W.counts(fx) == before
      assert W.stored_values(fx, @managed, a.record_id)["name"] == "managed-sf-a"
    end
  end

  # ===========================================================================================
  describe "T-W21 production allowlist []" do
    setup do
      production_allowlist!()
      :ok
    end

    test "managed declared type: 403 on every write route, writes nothing", %{
      fx: fx,
      managed_a: a
    } do
      before = W.counts(fx)

      for {label, conn} <- write_calls(fx, @managed, a.record_id) do
        assert conn.status == 403, "#{label}: #{conn.resp_body}"
      end

      assert W.counts(fx) == before
      assert W.stored_values(fx, @managed, a.record_id)["name"] == "managed-sf-a"
    end

    test "undeclared types: the four write routes equal a NONEXISTENT type's answer and write nothing",
         %{fx: fx} do
      before = W.counts(fx)

      for {label, absent} <- write_calls(fx, "no_such_type", Ecto.UUID.generate()) do
        for type <- ["scoped_item", "scoped_child"],
            id <- [fx.items.a.record_id, fx.items.b.record_id, Ecto.UUID.generate()] do
          {^label, conn} = Enum.find(write_calls(fx, type, id), &(elem(&1, 0) == label))
          assert conn.status == 404, "#{label} #{type}: #{conn.resp_body}"
          assert W.norm(conn) == W.norm(absent), "#{label} #{type} #{id}"
        end
      end

      assert W.counts(fx) == before
      assert W.stored_values(fx, "scoped_item", fx.items.a.record_id)["name"] == "item-a"
      assert W.stored_row(fx, "scoped_item", fx.items.a.record_id).deleted == false
    end

    test "the :tenant_wide-declared type is refused the same way",
         %{
           fx: fx,
           master: master
         } do
      before = W.counts(fx)

      for {label, absent} <- write_calls(fx, "no_such_type", Ecto.UUID.generate()) do
        {^label, conn} =
          Enum.find(write_calls(fx, "scoped_master", master.record_id), &(elem(&1, 0) == label))

        assert W.norm(conn) == W.norm(absent), label
      end

      assert W.counts(fx) == before
      assert W.stored_values(fx, "scoped_master", master.record_id)["name"] == "master"
    end

    test "attachments of undeclared and tenant_wide types answer as for a nonexistent parent",
         %{fx: fx, master: master, att_item: att_item, att_master: att_master} do
      before = W.counts(fx)

      for {type, id, att} <- [
            {"scoped_item", fx.items.a.record_id, att_item},
            {"scoped_master", master.record_id, att_master}
          ] do
        real = attachment_calls(fx, type, id, att.id)
        absent = attachment_calls(fx, type, Ecto.UUID.generate(), Ecto.UUID.generate())

        for {{label, conn}, {label, expected}} <- Enum.zip(real, absent) do
          assert W.norm(conn) == W.norm(expected), "#{type} #{label}"
          refute conn.resp_body =~ "ATTACHED-BYTES"
        end

        assert Jason.decode!(Enum.at(real, 1) |> elem(1) |> Map.fetch!(:resp_body)) == @empty_page

        wide = W.admin_request(fx, :get, W.attachments_path(type, id), nil)
        assert [%{"id" => wide_id}] = W.json(wide)["items"]
        assert wide_id == att.id
      end

      assert W.counts(fx) == before
    end

    test "managed type attachments are outside the managed lock (#2582): served in scope, hidden out of scope",
         %{fx: fx, managed_a: a, managed_b: b, att_managed_a: att_a, att_managed_b: att_b} do
      assert [%{"id" => id}] =
               W.request(fx, :get, W.attachments_path(@managed, a.record_id), nil)
               |> W.json()
               |> Map.fetch!("items")

      assert id == att_a.id
      assert W.request(fx, :get, W.item_path(@managed, a.record_id, att_a.id), nil).status == 200

      absent = attachment_calls(fx, @managed, Ecto.UUID.generate(), Ecto.UUID.generate())
      real = attachment_calls(fx, @managed, b.record_id, att_b.id)

      for {{label, conn}, {label, expected}} <- Enum.zip(real, absent) do
        assert W.norm(conn) == W.norm(expected), label
      end
    end
  end
end
