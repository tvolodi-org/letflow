defmodule Letflow.Scripts.EntityEventHookTest do
  @moduledoc """
  REQ-570 slice T-1 part 1 (GH #3248): the `entity_event` hook kind (K), its optional `writes`
  manifest declaration, and the `:record_triggers_enabled` flag (C). `async: false` (the platform
  tenant pin is VM-global).
  """

  use Letflow.DataCase, async: false

  alias Letflow.RecordTriggers
  alias Letflow.RecordTriggersFixture
  alias Letflow.Scripts
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScriptTaskFixture, as: F

  @designer ["PROCESS_DESIGNER"]
  @admin ["TENANT_ADMIN"]

  @manifest %{
    "input_schema" => %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}},
    "output_schema" => %{"type" => "object", "properties" => %{"y" => %{"type" => "integer"}}},
    "fail_codes" => ["too_big"],
    "writes" => [
      %{"entity_type" => "order", "mode" => "update_self", "fields" => ["note"]}
    ]
  }
  @source "if ctx.input.x > 10 then fail('too_big') end return {y = ctx.input.x * 2}"
  @test_cases [
    %{"name" => "doubles", "input" => %{"x" => 2}, "expect" => %{"output" => %{"y" => 4}}},
    %{"name" => "refuses", "input" => %{"x" => 11}, "expect" => %{"fail" => "too_big"}}
  ]

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  defp call(method, path, fixture, roles, body) do
    user_id = Ecto.UUID.generate()

    conn =
      Fixture.router_conn(method, path, fixture, roles, body)
      |> Plug.Conn.assign(:auth_context, %{
        user_id: user_id,
        tenant_id: fixture.tenant_id,
        roles: roles,
        credential: :oidc
      })

    Letflow.Routers.ScriptRules.call(conn, Letflow.Routers.ScriptRules.init([]))
  end

  defp body(overrides) do
    Map.merge(
      %{
        "hook_kind" => "entity_event",
        "source" => @source,
        "manifest" => @manifest,
        "test_cases" => @test_cases
      },
      overrides
    )
  end

  defp actor, do: %{user_id: Ecto.UUID.generate(), credential: :oidc, trace_id: "req570"}

  describe "K hook kind" do
    test "K1 an entity_event version is created and published through the script-rules routes",
         ctx do
      key = "k1_#{System.unique_integer([:positive])}"
      create = call(:post, "/#{key}/versions", ctx.a, @designer, body(%{}))
      assert create.status == 201, create.resp_body
      draft = Jason.decode!(create.resp_body)
      assert draft["hook_kind"] == "entity_event"

      publish =
        call(:post, "/#{key}/versions/1/publish", ctx.a, @admin, %{"sha256" => draft["sha256"]})

      assert publish.status == 200, publish.resp_body
      assert Jason.decode!(publish.resp_body)["status"] == "published"
    end

    test "K1b an unknown hook kind is still invalid_hook_kind", ctx do
      for kind <- ["bogus", "nope", "http", "", nil] do
        conn = call(:post, "/k1b/versions", ctx.a, @designer, body(%{"hook_kind" => kind}))
        assert conn.status == 422, conn.resp_body
        assert Jason.decode!(conn.resp_body)["detail"] == "invalid_hook_kind"
      end
    end

    test "K2 the writes declaration is shape-checked and belongs to entity_event only", ctx do
      line = %{"entity_type" => "order", "mode" => "create", "fields" => ["note"]}

      bad = [
        "x",
        List.duplicate(line, 9),
        [%{line | "mode" => "delete"}],
        [%{line | "fields" => []}],
        [%{line | "fields" => ["a", "a"]}],
        [Map.put(line, "extra", 1)],
        [%{line | "entity_type" => ""}]
      ]

      for writes <- bad do
        manifest = Map.put(@manifest, "writes", writes)

        assert Scripts.create_draft(
                 ctx.a.schema_name,
                 "k2",
                 body(%{"manifest" => manifest}),
                 actor()
               ) == {:error, :invalid_manifest}
      end

      assert {:error, :invalid_manifest} =
               Scripts.create_draft(
                 ctx.a.schema_name,
                 "k2s",
                 body(%{"hook_kind" => "service_task"}),
                 actor()
               )

      assert {:ok, _} =
               Scripts.create_draft(
                 ctx.a.schema_name,
                 "k2ok",
                 body(%{"manifest" => Map.put(@manifest, "writes", [line])}),
                 actor()
               )
    end

    test "K3 a SERVICE_TASK node cannot bind an entity_event version", ctx do
      schema = ctx.a.schema_name
      rule = RecordTriggersFixture.script!(schema, "entity_event", :published)
      {:ok, graph} = Letflow.Definitions.Graph.from_map(F.script_graph(rule.key, rule.version))

      assert {:error, {:script_binding_invalid, "svc", :script_not_published}} =
               Letflow.Scripts.Runtime.check_bindings(graph, schema)
    end
  end

  describe "C flag" do
    test "C1 :record_triggers_enabled is false in config.exs and test.exs and the reader follows it" do
      # config.exs applies to every env (dev, test, prod); config/test.exs repeats it.
      assert File.read!("config/config.exs") =~ "config :letflow, :record_triggers_enabled, false"
      assert Application.get_env(:letflow, :record_triggers_enabled) == false

      assert File.read!("config/test.exs") =~ "config :letflow, :record_triggers_enabled, false"
      refute RecordTriggers.enabled?()

      Application.put_env(:letflow, :record_triggers_enabled, true)
      on_exit(fn -> Application.put_env(:letflow, :record_triggers_enabled, false) end)
      assert RecordTriggers.enabled?()
    end

    test "C2 no other lib file reads the flag" do
      readers =
        Path.wildcard("lib/**/*.ex")
        |> Enum.filter(&(File.read!(&1) =~ "record_triggers_enabled"))

      assert readers == ["lib/letflow/record_triggers.ex"]
    end
  end
end
