defmodule Letflow.Routers.SolutionPackOverrideActivateTest do
  @moduledoc """
  REQ-610 / GH #3419: `POST /solution-packs/:pack_id/overrides/:override_id/activate` through the
  full `Letflow.Router` pipeline (design ids A1, A2, I1, RR1, R1, U1, U2, V1, V2, RC1, C1..C3, P1,
  P2, S1). R2 (two concurrent activations) is race-only: the advisory lock serialises them and the
  loser sees the stored version (covered by A2 sequentially).

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the platform-tenant pin
  is VM-global.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Authorization
  alias Letflow.Definitions
  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Engine
  alias Letflow.Engine.VariableSchema
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @admin "TENANT_ADMIN"
  @value "Tier 987654.321"

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    ids = for t <- [tenants.a, tenants.b, tenants.p], do: t.tenant_id

    on_exit(fn ->
      Repo.delete_all(from(r in PackUpdateResolution, where: r.tenant_id in ^ids))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id in ^ids))
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id in ^ids))
    end)

    {:ok, tenants}
  end

  # -- helpers ------------------------------------------------------------------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "label" => "Approve",
          "attributes" => %{"role" => "approver"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # an active installed definition, plus the install and base rows of a pack covering it
  defp installed!(fx, opts) do
    {:ok, draft} =
      Definitions.create(
        %{
          name: unique("ovdef"),
          version: "1.0.0",
          graph: graph(),
          created_by: Ecto.UUID.generate()
        },
        prefix: fx.schema_name
      )

    if schemas = opts[:schemas] do
      {:ok, _} = Definitions.register_variable_schemas(draft.id, schemas, prefix: fx.schema_name)
    end

    {:ok, %{definition: active}} = Definitions.activate(draft.id, prefix: fx.schema_name)
    active
  end

  defp install!(fx, pack_id, artefact_id) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    %SolutionPackInstall{}
    |> SolutionPackInstall.insert_changeset(%{
      tenant_id: fx.tenant_id,
      pack_id: pack_id,
      installed_version: "1.0.0",
      installed_at: now
    })
    |> Repo.insert!()

    %SolutionPackArtefactBase{}
    |> SolutionPackArtefactBase.upsert_changeset(%{
      tenant_id: fx.tenant_id,
      pack_id: pack_id,
      artefact_type: "process_definition",
      artefact_id: artefact_id,
      base_version: "1.0.0",
      base_content: "base",
      captured_at: now
    })
    |> Repo.insert!()
  end

  defp base_path(pack_id), do: "/api/v1/solution-packs/#{pack_id}/overrides"

  defp call(method, path, token, fx, body) do
    method |> Fixture.api_conn(path, token, fx.tenant.slug, body) |> Fixture.dispatch_api()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp no_trace(body), do: body |> Jason.decode!() |> Map.delete("trace_id")

  defp create!(fx, token, pack_id, artefact_id, patch) do
    conn =
      call(:post, base_path(pack_id), token, fx, %{
        "artefact_type" => "process_definition",
        "artefact_id" => artefact_id,
        "patch" => patch,
        "reason" => "local wording"
      })

    assert conn.status == 201, conn.resp_body
    json(conn)["override_id"]
  end

  defp activate(fx, token, pack_id, id, body \\ %{"reason" => "go live"}),
    do: call(:post, base_path(pack_id) <> "/#{id}/activate", token, fx, body)

  defp new_version!(fx, token, pack_id, id, patch) do
    conn =
      call(:post, base_path(pack_id) <> "/#{id}/versions", token, fx, %{
        "patch" => patch,
        "reason" => "again"
      })

    assert conn.status == 200, conn.resp_body
  end

  defp count(table, fx) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{fx.schema_name}".#{table}|)
    n
  end

  defp activated_audits(fx) do
    Repo.query!(
      ~s|SELECT after_state FROM "#{fx.schema_name}".audit_entries WHERE action = 'solution_pack.override_activated'|
    ).rows
  end

  # tenant A, one admin token, an installed definition and a pack covering it
  defp world(ctx, opts \\ []) do
    pack_id = unique("s3pack")
    installed = installed!(ctx.a, opts)
    install!(ctx.a, pack_id, installed.id)
    {Fixture.mint_token!(ctx.a, [@admin]), pack_id, installed}
  end

  defp role_of(graph), do: Enum.at(graph["nodes"], 1)["attributes"]["role"]

  # -- A: the activation ----------------------------------------------------------------------

  describe "A activation" do
    test "A1: builds <installed>+ov1, activates it and deprecates the installed row", ctx do
      {token, pack_id, installed} = world(ctx)

      id =
        create!(ctx.a, token, pack_id, installed.id, %{
          "nodes.task.attributes.role" => "boss",
          "nodes.task.label" => "Sign"
        })

      conn = activate(ctx.a, token, pack_id, id)
      assert conn.status == 200, conn.resp_body

      assert %{
               "definition_id" => new_id,
               "name" => name,
               "version" => "1.0.0+ov1",
               "override_version" => 1,
               "previous_definition_id" => prev
             } = json(conn)

      assert name == installed.name and prev == installed.id

      new = Repo.get!(ProcessDefinition, new_id, prefix: ctx.a.schema_name)
      assert new.status == :active
      assert role_of(new.graph) == "boss"
      assert Enum.at(new.graph["nodes"], 1)["label"] == "Sign"
      assert new.graph["edges"] == graph()["edges"]

      old = Repo.get!(ProcessDefinition, installed.id, prefix: ctx.a.schema_name)
      assert old.status == :deprecated
      assert old.graph == installed.graph and old.version == "1.0.0"
      assert count("process_definitions", ctx.a) == 2
    end

    test "A2: a second call is refused, a new version builds +ov2 from installed + v2", ctx do
      {token, pack_id, installed} = world(ctx)
      id = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.attributes.role" => "boss"})
      assert activate(ctx.a, token, pack_id, id).status == 200

      before = {count("process_definitions", ctx.a), length(activated_audits(ctx.a))}
      conn = activate(ctx.a, token, pack_id, id)
      assert conn.status == 422 and conn.resp_body =~ "override_already_activated"
      assert before == {count("process_definitions", ctx.a), length(activated_audits(ctx.a))}

      new_version!(ctx.a, token, pack_id, id, %{"nodes.task.label" => "Only label"})
      conn = activate(ctx.a, token, pack_id, id)
      assert conn.status == 200
      assert %{"version" => "1.0.0+ov2", "definition_id" => new_id} = json(conn)
      new = Repo.get!(ProcessDefinition, new_id, prefix: ctx.a.schema_name)
      assert role_of(new.graph) == "approver"
      assert Enum.at(new.graph["nodes"], 1)["label"] == "Only label"
    end

    test "I1: a running instance keeps its snapshot; a new one snapshots +ov1", ctx do
      {token, pack_id, installed} = world(ctx)
      schema = ctx.a.schema_name

      {:ok, %{instance_id: running}} =
        Engine.create(
          %{
            definition_id: installed.id,
            initial_variables: %{},
            actor_id: Ecto.UUID.generate(),
            idempotency_key: unique("idem")
          },
          prefix: schema
        )

      snap = fn instance_id ->
        Repo.one(
          from(s in "instance_definition_snapshots",
            where: s.instance_id == type(^instance_id, Ecto.UUID),
            select: {s.definition_id, s.definition_ver, s.graph}
          ),
          prefix: schema
        )
      end

      before = snap.(running)
      instances = {count("instance_projections", ctx.a), count("events", ctx.a)}
      id = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.attributes.role" => "boss"})
      assert activate(ctx.a, token, pack_id, id).status == 200

      assert snap.(running) == before
      assert {count("instance_projections", ctx.a), count("events", ctx.a)} == instances
      assert {_, "1.0.0", snap_graph} = before
      assert role_of(snap_graph) == "approver"

      new = Repo.one!(from(d in ProcessDefinition, where: d.status == :active), prefix: schema)

      {:ok, %{instance_id: fresh}} =
        Engine.create(
          %{
            definition_id: new.id,
            initial_variables: %{},
            actor_id: Ecto.UUID.generate(),
            idempotency_key: unique("idem")
          },
          prefix: schema
        )

      assert {_, "1.0.0+ov1", fresh_graph} = snap.(fresh)
      assert role_of(fresh_graph) == "boss"
    end

    test "RR1: retire then activate gives a version equal to the installed graph", ctx do
      {token, pack_id, installed} = world(ctx)
      id = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.attributes.role" => "boss"})
      assert activate(ctx.a, token, pack_id, id).status == 200

      conn = call(:post, base_path(pack_id) <> "/#{id}/retire", token, ctx.a, %{"reason" => "x"})
      assert conn.status == 200

      conn = activate(ctx.a, token, pack_id, id)
      assert conn.status == 200
      assert %{"version" => "1.0.0+ov2", "definition_id" => new_id} = json(conn)
      new = Repo.get!(ProcessDefinition, new_id, prefix: ctx.a.schema_name)
      assert new.graph == installed.graph
    end

    test "RC1: a re-created override meets an existing +ov1", ctx do
      {token, pack_id, installed} = world(ctx)
      a = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.attributes.role" => "boss"})
      assert activate(ctx.a, token, pack_id, a).status == 200
      call(:post, base_path(pack_id) <> "/#{a}/retire", token, ctx.a, %{"reason" => "x"})
      assert activate(ctx.a, token, pack_id, a).status == 200

      b = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.attributes.role" => "other"})
      before = {count("process_definitions", ctx.a), length(activated_audits(ctx.a))}
      conn = activate(ctx.a, token, pack_id, b)
      assert conn.status == 422 and conn.resp_body =~ "override_version_clash"
      assert before == {count("process_definitions", ctx.a), length(activated_audits(ctx.a))}

      # the same patch as A's +ov1 yields the stored graph: already activated
      c_pack = pack_id
      call(:post, base_path(c_pack) <> "/#{b}/retire", token, ctx.a, %{"reason" => "x"})
      c = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.attributes.role" => "boss"})
      conn = activate(ctx.a, token, pack_id, c)
      assert conn.status == 422 and conn.resp_body =~ "override_already_activated"

      # version 3 is free
      new_version!(ctx.a, token, pack_id, c, %{"nodes.task.attributes.role" => "third"})
      new_version!(ctx.a, token, pack_id, c, %{"nodes.task.attributes.role" => "third"})
      conn = activate(ctx.a, token, pack_id, c)
      assert conn.status == 200 and json(conn)["version"] == "1.0.0+ov3"
    end

    test "V1: variable schemas are copied and still enforced on the new version", ctx do
      schemas = [%{variable_key: "amount", json_schema: %{"type" => "number"}, description: "d"}]
      {token, pack_id, installed} = world(ctx, schemas: schemas)
      id = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.attributes.role" => "boss"})
      conn = activate(ctx.a, token, pack_id, id)
      assert conn.status == 200, conn.resp_body
      new_id = json(conn)["definition_id"]
      schema = ctx.a.schema_name

      assert {:ok, copied} = VariableSchema.fetch_schemas(Repo, new_id, prefix: schema)
      assert {:ok, ^copied} = VariableSchema.fetch_schemas(Repo, installed.id, prefix: schema)
      assert copied == %{"amount" => %{"type" => "number"}}

      description =
        Repo.one(
          from(v in VariableSchema, where: v.definition_id == ^new_id, select: v.description),
          prefix: schema
        )

      assert description == "d"

      {_t, plain_pack, plain} = world(ctx)

      pid =
        create!(ctx.a, Fixture.mint_token!(ctx.a, [@admin]), plain_pack, plain.id, %{
          "nodes.task.label" => "x"
        })

      assert activate(ctx.a, token, plain_pack, pid).status == 200
      assert count("variable_schemas", ctx.a) == 2
    end
  end

  # -- R: refusals ----------------------------------------------------------------------------

  describe "R refusals" do
    test "R1a: reason required, nothing written", ctx do
      {token, pack_id, installed} = world(ctx)
      id = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.label" => "x"})
      before = count("process_definitions", ctx.a)

      for body <- [%{}, %{"reason" => "  "}, %{"reason" => 5}] do
        conn = activate(ctx.a, token, pack_id, id, body)
        assert conn.status == 422 and conn.resp_body =~ "reason_required"
      end

      assert before == count("process_definitions", ctx.a)
      assert activated_audits(ctx.a) == []
    end

    test "R1b: unknown id, other pack, no install, deleted installed row answer one 404", ctx do
      {token, pack_id, installed} = world(ctx)
      id = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.label" => "x"})
      other = unique("s3other")
      install!(ctx.a, other, installed.id)

      replies =
        for {path, _} <- [
              {base_path(pack_id) <> "/#{Ecto.UUID.generate()}/activate", 1},
              {base_path(pack_id) <> "/not-a-uuid/activate", 2},
              {base_path(other) <> "/#{id}/activate", 3},
              {base_path(unique("s3none")) <> "/#{id}/activate", 4}
            ] do
          conn = call(:post, path, token, ctx.a, %{"reason" => "x"})
          assert conn.status == 404
          no_trace(conn.resp_body)
        end

      assert length(Enum.uniq(replies)) == 1

      # the installed row is gone: same reply
      Repo.query!(
        ~s|UPDATE "#{ctx.a.schema_name}".solution_pack_overrides SET artefact_id = $1|,
        [Ecto.UUID.generate()]
      )

      conn = activate(ctx.a, token, pack_id, id)
      assert conn.status == 404
      assert no_trace(conn.resp_body) == hd(replies)
    end

    test "R1c: a variable_schema override row is refused as not supported", ctx do
      {token, pack_id, installed} = world(ctx)
      id = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.label" => "x"})

      Repo.query!(
        ~s|UPDATE "#{ctx.a.schema_name}".solution_pack_overrides SET artefact_type = 'variable_schema'|
      )

      before = count("process_definitions", ctx.a)
      conn = activate(ctx.a, token, pack_id, id)
      assert conn.status == 422 and conn.resp_body =~ "artefact_type_not_supported"
      assert before == count("process_definitions", ctx.a)
    end

    test "R1d: a module-owned installed definition is refused", ctx do
      {token, pack_id, installed} = world(ctx)
      id = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.label" => "x"})

      Repo.query!(~s|ALTER TABLE "#{ctx.a.schema_name}".process_definitions DISABLE TRIGGER USER|)

      Repo.query!(
        ~s|UPDATE "#{ctx.a.schema_name}".process_definitions SET owner_module = 'm', owner_module_version = '1', owner_manifest_hash = 'h', owner_body_hash = 'b' WHERE id = $1|,
        [Ecto.UUID.dump!(installed.id)]
      )

      before = count("process_definitions", ctx.a)
      conn = activate(ctx.a, token, pack_id, id)
      assert conn.status == 422 and conn.resp_body =~ "module_owned_definition_not_supported"
      assert before == count("process_definitions", ctx.a)
    end

    test "R1e: an effective graph failing validation gives the fixed text, no draft", ctx do
      {token, pack_id, installed} = world(ctx)
      id = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.label" => "x"})

      Repo.query!(
        ~s|UPDATE "#{ctx.a.schema_name}".solution_pack_overrides SET patch = $1::jsonb|,
        [%{"nodes.task.attributes.escalation_timer_duration" => @value}]
      )

      before = count("process_definitions", ctx.a)
      conn = activate(ctx.a, token, pack_id, id)
      assert conn.status == 422
      assert conn.resp_body =~ "effective definition failed validation"
      refute conn.resp_body =~ "987654"
      assert before == count("process_definitions", ctx.a)
    end
  end

  # -- U: audit -------------------------------------------------------------------------------

  describe "U audit" do
    test "U1: one entry with ids and hash, no patch value anywhere", ctx do
      {token, pack_id, installed} = world(ctx)
      id = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.label" => @value})

      {conn, log} =
        with_log([level: :info], fn -> activate(ctx.a, token, pack_id, id) end)

      assert conn.status == 200
      refute conn.resp_body =~ "987654"
      refute log =~ "987654"

      assert [[state]] = activated_audits(ctx.a)
      assert %{"override_id" => ^id, "override_version" => 1, "reason" => "go live"} = state
      assert is_binary(state["patch_hash"]) and state["definition_version"] == "1.0.0+ov1"
      refute inspect(state) =~ "987654"
    end

    test "U2: with audit_entries dropped the answer is 503 and no definition row remains", ctx do
      {token, pack_id, installed} = world(ctx)
      id = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.label" => "x"})
      before = count("process_definitions", ctx.a)
      Repo.query!(~s|DROP TABLE "#{ctx.a.schema_name}".audit_entries|)

      conn = activate(ctx.a, token, pack_id, id)
      assert conn.status == 503
      assert before == count("process_definitions", ctx.a)
      assert count("variable_schemas", ctx.a) == 0
    end
  end

  # -- C / P / S ------------------------------------------------------------------------------

  describe "C cross-tenant, P permission, S scoping" do
    test "C1/C2: tenant B cannot see or activate A's override; ids in path/query/body ignored",
         ctx do
      {token_a, pack_id, installed} = world(ctx)
      id = create!(ctx.a, token_a, pack_id, installed.id, %{"nodes.task.label" => "x"})
      token_b = Fixture.mint_token!(ctx.b, [@admin])
      install!(ctx.b, pack_id, installed.id)

      random = activate(ctx.b, token_b, pack_id, Ecto.UUID.generate())

      forged =
        call(
          :post,
          base_path(pack_id) <> "/#{id}/activate?tenant_id=#{ctx.a.tenant_id}",
          token_b,
          ctx.b,
          %{"reason" => "x", "tenant_id" => ctx.a.tenant_id}
        )

      assert forged.status == 404 and random.status == 404
      assert no_trace(forged.resp_body) == no_trace(random.resp_body)
      assert count("process_definitions", ctx.a) == 1
      assert count("process_definitions", ctx.b) == 0
    end

    test "C3: a PLATFORM_ADMIN token acts on its own tenant only", ctx do
      {token_a, pack_id, installed} = world(ctx)
      id = create!(ctx.a, token_a, pack_id, installed.id, %{"nodes.task.label" => "x"})
      token_p = Fixture.mint_token!(ctx.p, ["PLATFORM_ADMIN"])
      install!(ctx.p, pack_id, installed.id)

      assert activate(ctx.p, token_p, pack_id, id).status == 404
      assert count("process_definitions", ctx.a) == 1
    end

    test "P1: other roles get 403 and nothing is written", ctx do
      {token, pack_id, installed} = world(ctx)
      id = create!(ctx.a, token, pack_id, installed.id, %{"nodes.task.label" => "x"})
      before = count("process_definitions", ctx.a)

      for role <-
            ~w(PROCESS_DESIGNER PROCESS_OPERATOR TASK_WORKER AGENT_RUNNER CANDIDATE TENANT_AUDITOR) do
        t = Fixture.mint_token!(ctx.a, [role])
        assert activate(ctx.a, t, pack_id, id).status == 403, role
      end

      assert before == count("process_definitions", ctx.a)
    end

    test "P2: the policy key is :SolutionOverridesManage only (Q2)" do
      assert Authorization.endpoint_policy_key(
               "POST",
               "/solution-packs/:pack_id/overrides/:override_id/activate"
             ) == :SolutionOverridesManage
    end

    test "S1: every Repo call in the new modules passes a prefix" do
      for file <- [
            "lib/letflow/definitions/solution_pack_override_activation.ex",
            "lib/letflow/definitions/solution_pack_override_merge.ex"
          ] do
        src = File.read!(file)
        calls = Regex.scan(~r/Repo\.(?:all|one|one!|get|get!)\(/, src)
        prefixed = Regex.scan(~r/prefix: prefix/, src)
        assert length(prefixed) >= length(calls), file
        refute src =~ ~r/Repo\.(?:insert|update|delete)(?:_all)?\(/
      end
    end
  end
end
