defmodule Letflow.Routers.DocumentsPrintOverridesTest do
  @moduledoc """
  REQ-579 / GH #3289, part 2: the five `/print-overrides` routes of `Letflow.Routers.Documents`.
  Design: state/tasks/T-0651/design.md, IDs S2-save, D5-redact, C3-manage, S2-sod, A-refuse,
  P1, L1 (R9 is in `documents_route_classes_test.exs`).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Letflow.DocumentSqlFixture, only: [exec!: 2, table: 2]

  alias Letflow.Api.Authorization
  alias Letflow.Documents.Canonical
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @router Letflow.Routers.Documents
  @admin "TENANT_ADMIN"
  @sentinel "SENTINEL-4d7e-literal"
  @declared ~s({"order": ["number", "total"], "line": ["sku"]})
  @go %{"reason_code" => "go_live"}
  @conflict_text "override is not in a status that allows this action"

  defp layout(text \\ "Order") do
    %{
      "layout_schema_version" => 1,
      "blocks" => [
        %{"type" => "page", "size" => "A4", "margin_mm" => 10, "font" => "dejavu-sans"},
        %{"type" => "text", "text" => text},
        %{"type" => "field", "entity_type" => "order", "field_name" => "number"},
        %{
          "type" => "table",
          "entity_type" => "line",
          "columns" => [%{"field_name" => "sku", "header" => "SKU", "width" => 40}]
        },
        %{"type" => "spacer", "height_mm" => 5}
      ]
    }
  end

  defp world!(slug) do
    fx = S.tenant!(slug)

    exec!(
      """
      INSERT INTO #{table(fx.schema_name, "document_types")}
        (key, tenant_id, owner_module, numbering_scope, number_prefix, number_pad,
         legal_entity_required, declared_fields, inserted_at)
      VALUES ('invoice', $1::uuid, 'procurement', 'year', 'IN', 4, false, '#{@declared}'::jsonb, now())
      """,
      [fx.tenant_id]
    )

    Map.put(fx, :second, RSG.user!(fx.schema_name))
  end

  defp call(fx, method, path, body \\ %{}, opts \\ []) do
    On.call(
      @router,
      method,
      path,
      fx,
      opts[:user] || fx.admin.id,
      opts[:roles] || [@admin],
      :off,
      body
    )
  end

  defp save(fx, extra \\ %{}, opts \\ []) do
    body = Map.merge(%{"type_key" => "invoice", "locale" => "ru", "layout" => layout()}, extra)
    call(fx, :post, "/print-overrides", body, opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp saved!(fx, extra \\ %{}) do
    conn = save(fx, extra)
    assert conn.status == 201
    json(conn)
  end

  defp activate(fx, id, opts \\ []) do
    call(fx, :post, "/print-overrides/#{id}/activate", @go, opts)
  end

  defp retire(fx, id, opts \\ []) do
    call(fx, :post, "/print-overrides/#{id}/retire", @go, opts)
  end

  defp second(fx), do: [user: fx.second.id]

  defp count(fx) do
    [[n]] =
      exec!("SELECT count(*) FROM #{table(fx.schema_name, "document_print_overrides")}", []).rows

    n
  end

  defp audit_count(fx) do
    [[n]] =
      exec!(
        "SELECT count(*) FROM #{table(fx.schema_name, "audit_entries")} WHERE action LIKE 'document.print_override_%'",
        []
      ).rows

    n
  end

  defp status_of(fx, id) do
    [[s]] =
      exec!(
        "SELECT status FROM #{table(fx.schema_name, "document_print_overrides")} WHERE id = $1::uuid",
        [id]
      ).rows

    s
  end

  defp restrict!(fx, entity, field) do
    exec!(
      "INSERT INTO #{table(fx.schema_name, "entity_field_restrictions")} (id, entity_type, field_name, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, $2, now(), now())",
      [entity, field]
    )
  end

  defp same_response?(a, b),
    do: a.status == b.status and a.resp_body == b.resp_body

  describe "S2-save" do
    test "201, server-owned body fields ignored, versions count up" do
      fx = world!("r579-s2")

      conn =
        save(fx, %{
          "tenant_id" => Ecto.UUID.generate(),
          "version_no" => 99,
          "status" => "active",
          "created_by" => Ecto.UUID.generate(),
          "layout_hash" => "x"
        })

      assert conn.status == 201
      body = json(conn)
      assert body["status"] == "draft"
      assert body["version_no"] == 1
      assert body["created_by"] == fx.admin.id
      refute Map.has_key?(body, "tenant_id")

      {:ok, bytes} = Canonical.canonicalize(layout())
      assert body["layout_hash"] == :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

      assert saved!(fx)["version_no"] == 2
      assert count(fx) == 2
    end

    test "422 leaves nothing stored" do
      fx = world!("r579-s2b")
      bad_layout = put_in(layout(), ["blocks"], [%{"type" => "bogus"}])

      for extra <- [
            %{"type_key" => "no_such_type"},
            %{"locale" => "en"},
            %{"layout" => bad_layout},
            %{"layout" => "not a map"}
          ] do
        conn = save(fx, extra)
        assert conn.status == 422
      end

      assert count(fx) == 0
      assert audit_count(fx) == 0
    end

    test "the 422 path does not echo a caller-chosen key name" do
      fx = world!("r579-s2c")
      key = "KEYNAME-4d7e"
      blocks = [%{"type" => "text", "text" => "x", key => 1}]
      conn = save(fx, %{"layout" => %{"layout_schema_version" => 1, "blocks" => blocks}})
      assert conn.status == 422
      refute conn.resp_body =~ key
      assert Enum.any?(json(conn)["errors"], &(&1["rule"] == "unknown_key"))
    end
  end

  describe "D5-redact" do
    test "activation after a restriction is a 422 with no value in body, log or audit" do
      fx = world!("r579-d5")
      id = saved!(fx, %{"layout" => layout(@sentinel)})["id"]
      restrict!(fx, "order", "number")

      log =
        capture_log(fn ->
          conn = activate(fx, id, second(fx))
          assert conn.status == 422
          refute conn.resp_body =~ @sentinel
          errors = json(conn)["errors"]
          assert Enum.any?(errors, &(&1["rule"] == "field_restricted"))
        end)

      refute log =~ @sentinel
      assert status_of(fx, id) == "draft"

      rows =
        exec!(
          "SELECT after_state::text, before_state::text FROM #{table(fx.schema_name, "audit_entries")}",
          []
        ).rows

      refute inspect(rows) =~ @sentinel
    end

    test "saving a layout that uses a restricted or an undeclared field is a 422" do
      fx = world!("r579-d5b")
      restrict!(fx, "order", "number")
      assert save(fx).status == 422

      undeclared =
        put_in(layout(), ["blocks"], [
          %{"type" => "field", "entity_type" => "order", "field_name" => "zzz"}
        ])

      conn = save(fx, %{"layout" => undeclared})
      assert conn.status == 422
      refute conn.resp_body =~ "zzz"
      assert count(fx) == 0
    end
  end

  describe "C3-manage" do
    test "another tenant's id, an absent id and a malformed id are the same response" do
      a = world!("r579-c3a")
      b = world!("r579-c3b")
      b_id = saved!(b)["id"]
      absent = Ecto.UUID.generate()

      for {method, suffix} <- [{:get, ""}, {:post, "/activate"}, {:post, "/retire"}] do
        run = fn id -> call(a, method, "/print-overrides/#{id}#{suffix}", @go) end
        other = run.(b_id)
        assert other.status == 404
        assert same_response?(other, run.(absent))
        assert same_response?(other, run.("not-a-uuid"))
      end

      assert status_of(b, b_id) == "draft"
      assert json(call(a, :get, "/print-overrides"))["overrides"] == []
    end

    test "no route takes a tenant identifier and a tenant_id in the request changes nothing" do
      a = world!("r579-c3c")
      b = world!("r579-c3d")

      routes =
        @router.__authz_routes__()
        |> Enum.filter(fn {_m, p, _k} -> String.contains?(p, "print-overrides") end)

      assert length(routes) == 5
      refute Enum.any?(routes, fn {_m, p, _k} -> String.contains?(p, "tenant") end)

      conn = save(a, %{"tenant_id" => b.tenant_id})
      assert conn.status == 201
      assert count(a) == 1
      assert count(b) == 0

      conn = call(a, :get, "/print-overrides?tenant_id=#{b.tenant_id}")
      assert length(json(conn)["overrides"]) == 1
    end
  end

  describe "S2-sod" do
    test "creator cannot activate, a second admin can, the previous active one is retired" do
      fx = world!("r579-sod")
      first = saved!(fx)["id"]

      conn = activate(fx, first)
      assert conn.status == 409
      assert json(conn)["detail"] == "activation needs a second administrator"
      assert status_of(fx, first) == "draft"

      conn = activate(fx, first, second(fx))
      assert conn.status == 200
      assert json(conn)["activated_by"] == fx.second.id
      assert status_of(fx, first) == "active"

      next = saved!(fx)["id"]
      assert activate(fx, next, second(fx)).status == 200
      assert status_of(fx, first) == "retired"
      assert status_of(fx, next) == "active"
    end

    test "creator may retire, and the status rule is a 409" do
      fx = world!("r579-sod2")
      id = saved!(fx)["id"]

      conn = retire(fx, id)
      assert conn.status == 409
      assert json(conn)["detail"] == @conflict_text
      assert status_of(fx, id) == "draft"

      assert activate(fx, id, second(fx)).status == 200
      conn = activate(fx, id, second(fx))
      assert conn.status == 409
      assert json(conn)["detail"] == @conflict_text

      assert retire(fx, id).status == 200
      assert status_of(fx, id) == "retired"
      assert retire(fx, id).status == 409
      assert activate(fx, id, second(fx)).status == 409
    end
  end

  describe "A-refuse" do
    test "refusals write no audit row, a success writes one per call" do
      fx = world!("r579-aud")
      id = saved!(fx)["id"]
      assert audit_count(fx) == 1
      stranger = Ecto.UUID.generate()

      assert save(fx, %{}, user: stranger, roles: ["TENANT_AUDITOR"]).status == 403
      assert save(fx, %{}, user: stranger, roles: ["TASK_WORKER"]).status == 403
      assert activate(fx, Ecto.UUID.generate(), second(fx)).status == 404
      assert activate(fx, id).status == 409
      assert retire(fx, id).status == 409
      assert save(fx, %{"locale" => "en"}).status == 422
      assert call(fx, :post, "/print-overrides/#{id}/activate", %{}, second(fx)).status == 422
      assert audit_count(fx) == 1

      assert activate(fx, id, second(fx)).status == 200
      assert audit_count(fx) == 2
      assert retire(fx, id).status == 200
      assert audit_count(fx) == 3
    end
  end

  describe "P1" do
    @perm :DocumentPrintTemplatesManage

    test "the permission is the last core permission, tenant scope" do
      assert Authorization.permission_scope(@perm) == :tenant

      assert Authorization.core_permissions() |> Enum.take(-3) == [
               @perm,
               :SolutionOverridesManage,
               :EntitiesExtensionsManage
             ]

      assert Authorization.required_permission(@perm) == @perm
      assert Authorization.has_permission_in_scope?([:TENANT_ADMIN], @perm, false)
      assert Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], @perm, true)

      for role <-
            ~w(TENANT_AUDITOR PROCESS_DESIGNER PROCESS_OPERATOR TASK_WORKER CANDIDATE AGENT_RUNNER)a do
        refute Authorization.has_permission_in_scope?([role], @perm, false)
      end
    end

    test "the auditor gets the same 403 as a task worker on all five routes" do
      fx = world!("r579-p1")
      id = saved!(fx)["id"]
      stranger = Ecto.UUID.generate()

      for {method, path} <- [
            {:get, "/print-overrides"},
            {:get, "/print-overrides/#{id}"},
            {:post, "/print-overrides"},
            {:post, "/print-overrides/#{id}/activate"},
            {:post, "/print-overrides/#{id}/retire"}
          ] do
        auditor = call(fx, method, path, @go, user: stranger, roles: ["TENANT_AUDITOR"])
        worker = call(fx, method, path, @go, user: stranger, roles: ["TASK_WORKER"])
        assert auditor.status == 403
        assert same_response?(auditor, worker)
      end

      assert count(fx) == 1
    end
  end

  describe "L1" do
    test "list is metadata only and filterable, get includes the layout" do
      fx = world!("r579-l1")
      id = saved!(fx)["id"]
      saved!(fx, %{"locale" => "kk"})

      all = json(call(fx, :get, "/print-overrides"))["overrides"]
      assert length(all) == 2
      refute Enum.any?(all, &(Map.has_key?(&1, "layout") or Map.has_key?(&1, "tenant_id")))

      only = json(call(fx, :get, "/print-overrides?locale=kk"))["overrides"]
      assert Enum.map(only, & &1["locale"]) == ["kk"]
      assert json(call(fx, :get, "/print-overrides?type_key=nope"))["overrides"] == []

      one = call(fx, :get, "/print-overrides/#{id}")
      assert one.status == 200
      assert json(one)["layout"] == layout()
      refute Map.has_key?(json(one), "tenant_id")
    end
  end
end
