defmodule Letflow.Definitions.SolutionPackOverridesTest do
  @moduledoc """
  REQ-596 / GH #3353 part A: the `solution_pack_overrides` tenant table and
  `Letflow.Definitions.SolutionPackOverrides` (no route, no permission). Test ids follow the
  T-0807 design: S2-1a..e storage, S2-3 closed list, S2-4 immutable history, S2-5 audit without
  values, S2-6 prefix scan.

  `async: false`: tenant provisioning switches the sandbox to `:auto` (same reasoning as
  `solution_packs_update_test.exs`), so the concurrent-writer test uses real connections.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Definitions.SolutionPackOverride
  alias Letflow.Definitions.SolutionPackOverrides, as: Overrides
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @router_opts Letflow.Routers.SolutionPacks.init([])
  @lib_file "lib/letflow/definitions/solution_pack_overrides.ex"
  @schema_file "lib/letflow/definitions/solution_pack_override.ex"

  defmodule PackModule do
    @moduledoc false
    # Test seam for the settings lookup: wraps the fixture pack "fixture-fk-pair" and declares one
    # setting, "threshold".
    def manifest do
      %{
        pack: "module_fixtures/fk_pair.json",
        settings_schema: %{"type" => "object", "properties" => %{"threshold" => %{}}}
      }
    end
  end

  # -- helpers ------------------------------------------------------------------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp tenant!(slug) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug)
    tenant_id = tenant.tenant_id

    on_exit(fn ->
      Repo.delete_all(from(r in PackUpdateResolution, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))
    end)

    tenant
  end

  defp install!(tenant, pack_id, version \\ "1.0.0") do
    %SolutionPackInstall{}
    |> SolutionPackInstall.insert_changeset(%{
      tenant_id: tenant.tenant_id,
      pack_id: pack_id,
      installed_version: version,
      installed_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
    })
    |> Repo.insert!()
  end

  defp base!(tenant, pack_id, artefact_id, content \\ nil) do
    %SolutionPackArtefactBase{}
    |> SolutionPackArtefactBase.upsert_changeset(%{
      tenant_id: tenant.tenant_id,
      pack_id: pack_id,
      artefact_type: "process_definition",
      artefact_id: artefact_id,
      base_version: "1.0.0",
      base_content: content || "base-#{artefact_id}",
      captured_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
    })
    |> Repo.insert!()
  end

  # a tenant with an active install of a fresh pack and a base for artefact "a1"
  defp setup_pack!(slug) do
    tenant = tenant!(slug)
    pack_id = unique("s2pack")
    install!(tenant, pack_id)
    base!(tenant, pack_id, "a1")
    {tenant, pack_id}
  end

  defp actor, do: Ecto.UUID.generate()

  defp input(pack_id, patch \\ %{"nodes.n1.label" => "Approve"}, extra \\ %{}) do
    Map.merge(
      %{
        pack_id: pack_id,
        artefact_type: "process_definition",
        artefact_id: "a1",
        patch: patch,
        reason: "local wording"
      },
      extra
    )
  end

  defp create!(tenant, pack_id, patch \\ %{"nodes.n1.label" => "Approve"}) do
    {:ok, row} =
      Overrides.create(tenant.schema_name, tenant.tenant_id, actor(), input(pack_id, patch))

    row
  end

  defp override_count(schema) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".solution_pack_overrides|)
    n
  end

  defp audit_count(schema) do
    %{rows: [[n]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{schema}".audit_entries WHERE resource_type = 'solution_pack_override'|
      )

    n
  end

  defp audit_rows(schema) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT action, actor_id, before_state::text, after_state::text FROM "#{schema}".audit_entries WHERE resource_type = 'solution_pack_override' ORDER BY timestamp|
      )

    Enum.map(rows, fn [action, actor_id, before, after_] ->
      [action, Ecto.UUID.load!(actor_id), before, after_]
    end)
  end

  defp plain(row), do: row |> Map.from_struct() |> Map.delete(:__meta__)

  defp global_snapshot(tenant_id) do
    for schema <- [SolutionPackInstall, SolutionPackArtefactBase, PackUpdateResolution] do
      schema
      |> then(&from(r in &1, where: r.tenant_id == ^tenant_id, order_by: r.id))
      |> Repo.all(prefix: "public")
      |> Enum.map(&plain/1)
    end
  end

  defp review_conn(path, tenant, body, user_id) do
    conn = %{conn(:post, path) | body_params: body}

    conn
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: tenant.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, "s2-override-trace")
    |> Letflow.Routers.SolutionPacks.call(@router_opts)
  end

  # -- S2-1: table, provisioning, replay, storage untouched --------------------------------

  describe "S2-1 table and storage" do
    test "S2-1a: a new tenant has the table, its columns (no tenant_id) and the unique key" do
      tenant = tenant!("s2ov-1a")

      assert %{rows: [[name]]} =
               Repo.query!("SELECT to_regclass($1)::text", [
                 ~s|"#{tenant.schema_name}".solution_pack_overrides|
               ])

      assert is_binary(name)

      %{rows: cols} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'solution_pack_overrides'",
          [tenant.schema_name]
        )

      assert cols |> List.flatten() |> Enum.sort() ==
               ~w(artefact_id artefact_type created_by id inserted_at made_against override_id override_version pack_id patch patch_hash reason status)

      %{rows: [[def_]]} =
        Repo.query!(
          "SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = $1 AND c.conname = 'uq_solution_pack_override_version'",
          [tenant.schema_name]
        )

      assert def_ == "UNIQUE (override_id, override_version)"
    end

    test "S2-1b: replaying the migration on an existing tenant schema finds the table, empty" do
      tenant = tenant!("s2ov-1b")
      schema = tenant.schema_name

      Repo.query!(~s|DROP TABLE "#{schema}".solution_pack_overrides|)
      Repo.query!(~s|DELETE FROM "#{schema}".schema_migrations WHERE version = 20261029100001|)

      assert {:ok, applied} = TenantProvisioning.replay_migrations(tenant.tenant_id)
      assert 20_261_029_100_001 in applied
      assert override_count(schema) == 0
    end

    test "S2-1c: a create, versions and a retire change no row of the three global tables" do
      {tenant, pack_id} = setup_pack!("s2ov-1c")
      before = global_snapshot(tenant.tenant_id)

      row = create!(tenant, pack_id)

      {:ok, _} =
        Overrides.new_version(tenant.schema_name, tenant.tenant_id, actor(), row.override_id, %{
          patch: %{"nodes.n1.label" => "Ok"},
          reason: "again",
          base_version: 1
        })

      {:ok, _} =
        Overrides.retire(tenant.schema_name, actor(), row.override_id, %{reason: "gone"})

      assert global_snapshot(tenant.tenant_id) == before
      assert [[_ | _], [_ | _], []] = before
    end

    test "S2-1d: update-review reply bytes do not change when overrides are written elsewhere" do
      tenant = tenant!("s2ov-1d")
      pack_p = unique("s2p")
      pack_q = unique("s2q")
      user_id = Ecto.UUID.generate()

      install!(tenant, pack_p)
      install!(tenant, pack_q)
      # a3's base is set up before R1: adding it later would change the reply for another reason
      for id <- ["a1", "a2", "a3"], do: base!(tenant, pack_p, id)
      base!(tenant, pack_q, "a1")

      body = %{
        "target_version" => "2.0.0",
        "theirs_artefacts" => [
          %{
            "artefact_type" => "process_definition",
            "artefact_id" => "a1",
            "content" => "base-a1"
          },
          %{
            "artefact_type" => "process_definition",
            "artefact_id" => "a2",
            "content" => "base-a2"
          }
        ],
        "incoming_artefacts" => [
          %{
            "artefact_type" => "process_definition",
            "artefact_id" => "a1",
            "content" => "base-a1"
          },
          %{"artefact_type" => "process_definition", "artefact_id" => "a2", "content" => "new-a2"}
        ]
      }

      path = "/#{pack_p}/update-review"
      r1 = review_conn(path, tenant, body, user_id)
      assert r1.status == 200
      assert r1.resp_body != ""
      assert is_list(Jason.decode!(r1.resp_body)["entries"])
      assert override_count(tenant.schema_name) == 0

      # Both cases on purpose: another pack Q (the install with no override stays untouched) and
      # another artefact of P itself (a stored override must not leak into P's replies).
      {:ok, _} =
        Overrides.create(tenant.schema_name, tenant.tenant_id, user_id, %{
          pack_id: pack_q,
          artefact_type: "process_definition",
          artefact_id: "a1",
          patch: %{"nodes.n1.label" => "Q"},
          reason: "q"
        })

      {:ok, _} =
        Overrides.create(tenant.schema_name, tenant.tenant_id, user_id, %{
          pack_id: pack_p,
          artefact_type: "process_definition",
          artefact_id: "a3",
          patch: %{"nodes.n1.label" => "P3"},
          reason: "p3"
        })

      assert override_count(tenant.schema_name) == 2
      r2 = review_conn(path, tenant, body, user_id)

      assert r2.status == r1.status
      assert get_resp_header(r2, "content-type") == get_resp_header(r1, "content-type")
      assert r2.resp_body == r1.resp_body
    end

    test "S2-1e: update-apply reply bytes are equal with and without override rows" do
      user_id = Ecto.UUID.generate()
      pack_p = unique("s2p")
      pack_q = unique("s2q")

      build = fn slug ->
        tenant = tenant!(slug)
        install!(tenant, pack_p)
        install!(tenant, pack_q)
        for id <- ["a1", "a2", "a3"], do: base!(tenant, pack_p, id)
        base!(tenant, pack_q, "a1")
        tenant
      end

      x = build.("s2ov-1ex")
      y = build.("s2ov-1ey")

      # only Y gets override rows, written before the apply call
      {:ok, _} =
        Overrides.create(y.schema_name, y.tenant_id, user_id, %{
          pack_id: pack_q,
          artefact_type: "process_definition",
          artefact_id: "a1",
          patch: %{"nodes.n1.label" => "Q"},
          reason: "q"
        })

      {:ok, _} =
        Overrides.create(y.schema_name, y.tenant_id, user_id, %{
          pack_id: pack_p,
          artefact_type: "process_definition",
          artefact_id: "a3",
          patch: %{"nodes.n1.label" => "P3"},
          reason: "p3"
        })

      assert override_count(x.schema_name) == 0
      assert override_count(y.schema_name) == 2

      art = fn id, content ->
        %{"artefact_type" => "process_definition", "artefact_id" => id, "content" => content}
      end

      body = %{
        "target_version" => "2.0.0",
        "theirs_artefacts" => [art.("a1", "base-a1"), art.("a2", "base-a2")],
        "incoming_artefacts" => [art.("a1", "base-a1"), art.("a2", "new-a2")],
        "resolutions" => []
      }

      path = "/#{pack_p}/update-apply"
      rx = review_conn(path, x, body, user_id)
      ry = review_conn(path, y, body, user_id)

      assert rx.status == 200
      assert rx.resp_body != ""
      assert ry.status == rx.status
      assert get_resp_header(ry, "content-type") == get_resp_header(rx, "content-type")
      assert ry.resp_body == rx.resp_body

      bases = fn t ->
        for id <- ["a1", "a2", "a3"] do
          b =
            Repo.one!(
              from(b in SolutionPackArtefactBase,
                where:
                  b.tenant_id == ^t.tenant_id and b.pack_id == ^pack_p and b.artefact_id == ^id
              )
            )

          {b.artefact_id, b.base_version, b.base_content}
        end
      end

      assert bases.(x) == bases.(y)
      assert {"a2", "2.0.0", "new-a2"} in bases.(x)
    end
  end

  # -- S2-3: closed list --------------------------------------------------------------------

  describe "S2-3 closed list" do
    test "S2-3a: the closed list is pinned" do
      node = "[A-Za-z0-9_-]{1,255}"

      assert Overrides.closed_list() == %{
               "process_definition" => [
                 {"\\Anodes\\.#{node}\\.label\\z", :text},
                 {"\\Anodes\\.#{node}\\.attributes\\.role\\z", :text},
                 {"\\Anodes\\.#{node}\\.attributes\\.escalation_role\\z", :text},
                 {"\\Anodes\\.#{node}\\.attributes\\.escalation_timer_duration\\z", :duration},
                 {"\\Anodes\\.#{node}\\.attributes\\.duration_iso8601\\z", :duration},
                 {"\\Asettings\\.[^.\\s][^\\s]{0,254}\\z", :setting}
               ],
               "variable_schema" => []
             }
    end

    test "S2-3b: listed paths are accepted; every unlisted path is refused and writes nothing" do
      {tenant, pack_id} = setup_pack!("s2ov-3b")

      ok = %{
        "nodes.n1.label" => "Approve",
        "nodes.n1.attributes.role" => "MANAGER",
        "nodes.n1.attributes.escalation_role" => "DIRECTOR",
        "nodes.n1.attributes.escalation_timer_duration" => "PT4H",
        "nodes.t1.attributes.duration_iso8601" => "P1DT2H"
      }

      assert {:ok, row} =
               Overrides.create(tenant.schema_name, tenant.tenant_id, actor(), input(pack_id, ok))

      assert row.patch == ok

      for path <- [
            "nodes.n1",
            "nodes",
            "nodes.n1.id",
            "nodes.n1.type",
            "edges.e1.target",
            "edges.e1",
            "nodes.g1.attributes.condition",
            "nodes.n1.attributes.script",
            "nodes.n1.attributes.endpoint",
            "nodes.n1.attributes.role.x",
            "nodes.n1.label.x",
            "variables.v1.name",
            "variables.v1.type",
            "x.nodes.n1.label",
            "nodes.n1.label\n",
            "settings",
            "settings.",
            "settings.a.b",
            "",
            :atom_key
          ] do
        before = {override_count(tenant.schema_name), audit_count(tenant.schema_name)}

        # a second pack so :override_exists cannot hide the real reason
        assert {:error, :property_not_overridable} =
                 Overrides.create(
                   tenant.schema_name,
                   tenant.tenant_id,
                   actor(),
                   input(pack_id, %{path => "x"})
                 ),
               "path #{inspect(path)} must be refused"

        assert before == {override_count(tenant.schema_name), audit_count(tenant.schema_name)}
      end
    end

    test "S2-3c: a mixed patch is refused whole" do
      {tenant, pack_id} = setup_pack!("s2ov-3c")

      assert {:error, :property_not_overridable} =
               Overrides.create(
                 tenant.schema_name,
                 tenant.tenant_id,
                 actor(),
                 input(pack_id, %{"nodes.n1.label" => "ok", "edges.e1.target" => "n2"})
               )

      assert override_count(tenant.schema_name) == 0
      assert audit_count(tenant.schema_name) == 0
    end

    test "S2-3d: wrong value kinds are refused whole with :invalid_patch_value" do
      {tenant, pack_id} = setup_pack!("s2ov-3d")

      for patch <- [
            %{"nodes.n1.label" => 5},
            %{"nodes.n1.label" => ""},
            %{"nodes.n1.attributes.escalation_timer_duration" => "soon"},
            %{"nodes.n1.attributes.duration_iso8601" => "P"},
            %{"nodes.n1.attributes.duration_iso8601" => "PT"},
            %{},
            "not a map"
          ] do
        assert {:error, :invalid_patch_value} =
                 Overrides.create(
                   tenant.schema_name,
                   tenant.tenant_id,
                   actor(),
                   input(pack_id, patch)
                 ),
               "patch #{inspect(patch)}"
      end

      assert override_count(tenant.schema_name) == 0
    end

    test "S2-3e: settings.<key> only for a key of the wrapping module's settings_schema (a, b, c)" do
      tenant = tenant!("s2ov-3e")
      wrapped = "fixture-fk-pair"
      unwrapped = unique("s2unwrapped")

      for pack <- [wrapped, unwrapped] do
        install!(tenant, pack)
        base!(tenant, pack, "a1")
      end

      opts = [modules: [PackModule]]
      create = &Overrides.create(tenant.schema_name, tenant.tenant_id, actor(), &1, opts)

      # (a) declared key
      assert {:ok, row} = create.(input(wrapped, %{"settings.threshold" => 987_654.321}))
      assert row.patch == %{"settings.threshold" => 987_654.321}

      {:ok, _} =
        Overrides.retire(tenant.schema_name, actor(), row.override_id, %{reason: "reset"})

      # (b) undeclared key of the same pack
      assert {:error, :property_not_overridable} =
               create.(input(wrapped, %{"settings.nope" => 1}))

      # (c) a pack no module wraps: every settings.* is refused, other listed paths still work
      assert {:error, :property_not_overridable} =
               create.(input(unwrapped, %{"settings.threshold" => 1}))

      assert {:ok, _} = create.(input(unwrapped, %{"nodes.n1.label" => "ok"}))
    end

    test "S2-3f: another artefact_type, and every variable_schema patch, return the same tuple" do
      {tenant, pack_id} = setup_pack!("s2ov-3f")

      for type <- ["entity_definition", "form_schema", nil, 5] do
        assert {:error, :property_not_overridable} =
                 Overrides.create(
                   tenant.schema_name,
                   tenant.tenant_id,
                   actor(),
                   input(pack_id, %{"nodes.n1.label" => "x"}, %{artefact_type: type})
                 )
      end

      for patch <- [%{"name" => "x"}, %{"type" => "string"}, %{"nodes.n1.label" => "x"}] do
        assert {:error, :property_not_overridable} =
                 Overrides.create(
                   tenant.schema_name,
                   tenant.tenant_id,
                   actor(),
                   input(pack_id, patch, %{artefact_type: "variable_schema"})
                 )
      end

      assert override_count(tenant.schema_name) == 0
    end
  end

  # -- S2-4: immutable history --------------------------------------------------------------

  describe "S2-4 immutable history" do
    test "S2-4a: versions 1 to 4 incl. retire keep earlier rows byte-identical" do
      {tenant, pack_id} = setup_pack!("s2ov-4a")
      schema = tenant.schema_name
      v1 = create!(tenant, pack_id)
      assert v1.override_version == 1
      assert v1.made_against == "1.0.0"
      assert v1.status == "active"

      Repo.update_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id),
        set: [installed_version: "2.0.0"]
      )

      {:ok, v2} =
        Overrides.new_version(schema, tenant.tenant_id, actor(), v1.override_id, %{
          patch: %{"nodes.n1.label" => "Two"},
          reason: "r2",
          base_version: 1
        })

      assert v2.override_version == 2
      assert v2.made_against == "2.0.0"
      assert is_binary(v2.made_against)

      {:ok, v3} =
        Overrides.new_version(schema, tenant.tenant_id, actor(), v1.override_id, %{
          patch: %{"nodes.n1.label" => "Three"},
          reason: "r3",
          base_version: 2
        })

      assert {:ok, v4} =
               Overrides.retire(schema, actor(), v1.override_id, %{reason: "r4", base_version: 3})

      assert {v3.override_version, v4.override_version, v4.status, v4.patch} ==
               {3, 4, "retired", %{}}

      assert v4.made_against == v3.made_against

      rows = Overrides.history(schema, v1.override_id)
      assert Enum.map(rows, &plain/1) == Enum.map([v1, v2, v3, v4], &plain/1)
      assert Enum.map(rows, & &1.override_version) == [1, 2, 3, 4]
      assert {:ok, ^v4} = Overrides.latest(schema, v1.override_id)
    end

    test "S2-4b: source scan finds no update or delete of the table" do
      for file <- [@lib_file, @schema_file] do
        source = File.read!(file)

        for token <- [
              "Repo.update",
              "Repo.delete",
              "update_all",
              "delete_all",
              "Repo.insert_or_update",
              "UPDATE ",
              "DELETE "
            ] do
          refute source =~ token, "#{file} contains #{token}"
        end
      end
    end

    test "S2-4c: two concurrent writers of version 2 leave one row; the loser is told" do
      {tenant, pack_id} = setup_pack!("s2ov-4c")
      schema = tenant.schema_name
      v1 = create!(tenant, pack_id)

      write = fn label ->
        Overrides.new_version(schema, tenant.tenant_id, actor(), v1.override_id, %{
          patch: %{"nodes.n1.label" => label},
          reason: "race",
          base_version: 1
        })
      end

      results =
        ["A", "B"]
        |> Enum.map(fn l -> Task.async(fn -> write.(l) end) end)
        |> Task.await_many(30_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :override_version_taken})) == 1
      assert [1, 2] = Overrides.history(schema, v1.override_id) |> Enum.map(& &1.override_version)

      # deterministic loser path: a stale base_version after the winner finished
      assert {:error, :override_version_taken} = write.("C")

      # and the unique key backstop for a duplicate (override_id, version)
      assert_raise Postgrex.Error, ~r/uq_solution_pack_override_version/, fn ->
        Repo.query!(
          ~s|INSERT INTO "#{schema}".solution_pack_overrides (id, override_id, override_version, pack_id, artefact_type, artefact_id, made_against, patch, patch_hash, status, reason, created_by, inserted_at) SELECT gen_random_uuid(), override_id, override_version, pack_id, artefact_type, artefact_id, made_against, patch, patch_hash, status, reason, created_by, inserted_at FROM "#{schema}".solution_pack_overrides WHERE override_version = 2|
        )
      end
    end

    test "S2-4d: one non-retired override per artefact; retire frees it; a retired one is closed" do
      {tenant, pack_id} = setup_pack!("s2ov-4d")
      schema = tenant.schema_name
      v1 = create!(tenant, pack_id)

      assert {:error, :override_exists} =
               Overrides.create(schema, tenant.tenant_id, actor(), input(pack_id))

      {:ok, _} = Overrides.retire(schema, actor(), v1.override_id, %{reason: "done"})

      assert {:error, :override_retired} =
               Overrides.new_version(schema, tenant.tenant_id, actor(), v1.override_id, %{
                 patch: %{"nodes.n1.label" => "x"},
                 reason: "r"
               })

      assert {:error, :override_retired} =
               Overrides.retire(schema, actor(), v1.override_id, %{reason: "again"})

      assert {:ok, again} = Overrides.create(schema, tenant.tenant_id, actor(), input(pack_id))
      assert again.override_id != v1.override_id
      assert again.override_version == 1
    end

    test "S2-4e: no install, no base, unknown override and bad ids return error tuples" do
      tenant = tenant!("s2ov-4e")
      schema = tenant.schema_name
      pack_id = unique("s2none")

      assert {:error, :not_found} =
               Overrides.create(schema, tenant.tenant_id, actor(), input(pack_id))

      install!(tenant, pack_id)

      assert {:error, :not_found} =
               Overrides.create(schema, tenant.tenant_id, actor(), input(pack_id))

      assert {:error, :not_found} =
               Overrides.new_version(
                 schema,
                 tenant.tenant_id,
                 actor(),
                 Ecto.UUID.generate(),
                 %{patch: %{"nodes.n1.label" => "x"}, reason: "r"}
               )

      assert {:error, :not_found} = Overrides.retire(schema, actor(), "nope", %{reason: "r"})

      assert {:error, :invalid_input} =
               Overrides.create(schema, tenant.tenant_id, "not-a-uuid", input(pack_id))

      assert override_count(schema) == 0
    end
  end

  # -- S2-5: audit without values -----------------------------------------------------------

  describe "S2-5 audit" do
    test "S2-5a: create, new version and retire each write exactly one audit entry" do
      {tenant, pack_id} = setup_pack!("s2ov-5a")
      schema = tenant.schema_name
      who = actor()

      {:ok, v1} = Overrides.create(schema, tenant.tenant_id, who, input(pack_id))
      assert audit_count(schema) == 1

      {:ok, _} =
        Overrides.new_version(schema, tenant.tenant_id, who, v1.override_id, %{
          patch: %{"nodes.n1.label" => "Two"},
          reason: "r2"
        })

      assert audit_count(schema) == 2
      {:ok, _} = Overrides.retire(schema, who, v1.override_id, %{reason: "r3"})
      assert audit_count(schema) == 3

      assert [
               ["solution_pack.override_created", ^who, nil, _],
               ["solution_pack.override_version_written", ^who, nil, _],
               ["solution_pack.override_retired", ^who, nil, last]
             ] = audit_rows(schema)

      state = Jason.decode!(last)

      assert state |> Map.keys() |> Enum.sort() ==
               ~w(artefact_id artefact_type override_id override_version pack_id patch_hash reason)

      assert state["override_version"] == 3
      assert state["reason"] == "r3"
      assert state["patch_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "S2-5b: a missing or blank reason returns :reason_required and writes nothing" do
      {tenant, pack_id} = setup_pack!("s2ov-5b")
      schema = tenant.schema_name
      v1 = create!(tenant, pack_id)
      rows = {override_count(schema), audit_count(schema)}

      for reason <- [nil, "", "   ", 5] do
        assert {:error, :reason_required} =
                 Overrides.create(
                   schema,
                   tenant.tenant_id,
                   actor(),
                   input(pack_id, %{"nodes.n1.label" => "x"}, %{reason: reason})
                 )

        assert {:error, :reason_required} =
                 Overrides.new_version(schema, tenant.tenant_id, actor(), v1.override_id, %{
                   patch: %{"nodes.n1.label" => "x"},
                   reason: reason
                 })

        assert {:error, :reason_required} =
                 Overrides.retire(schema, actor(), v1.override_id, %{reason: reason})
      end

      assert {:error, :reason_required} =
               Overrides.create(
                 schema,
                 tenant.tenant_id,
                 actor(),
                 Map.delete(input(pack_id), :reason)
               )

      assert rows == {override_count(schema), audit_count(schema)}
    end

    test "S2-5c: a patch value appears in no audit entry, log or global pack table" do
      tenant = tenant!("s2ov-5c")
      pack_id = "fixture-fk-pair"
      install!(tenant, pack_id)
      base!(tenant, pack_id, "a1")

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, row} =
                   Overrides.create(
                     tenant.schema_name,
                     tenant.tenant_id,
                     actor(),
                     input(pack_id, %{"settings.threshold" => 987_654.321}),
                     modules: [PackModule]
                   )

          # the value is stored in the tenant row, so the scan below is not vacuous
          assert row.patch == %{"settings.threshold" => 987_654.321}
        end)

      refute log =~ "987654.321"

      for [_, _, before, after_] <- audit_rows(tenant.schema_name) do
        refute inspect({before, after_}) =~ "987654"
      end

      assert audit_count(tenant.schema_name) == 1

      for table <- ~w(solution_pack_installs solution_pack_artefact_bases pack_update_resolutions) do
        %{rows: [[n]]} =
          Repo.query!(~s|SELECT count(*) FROM #{table} t WHERE t::text LIKE '%987654%'|)

        assert n == 0
      end
    end

    test "S2-5d: with audit_entries dropped the write returns an error tuple and leaves no row" do
      {tenant, pack_id} = setup_pack!("s2ov-5d")
      schema = tenant.schema_name
      Repo.query!(~s|DROP TABLE "#{schema}".audit_entries|)

      log =
        capture_log([level: :warning], fn ->
          assert {:error, :audit_failed} =
                   Overrides.create(schema, tenant.tenant_id, actor(), input(pack_id))
        end)

      refute log =~ "Approve"
      assert override_count(schema) == 0
    end
  end

  # -- S2-6: prefix ---------------------------------------------------------------------------

  describe "S2-6 prefix" do
    test "S2-6a: every Repo call in the module carries :prefix" do
      source =
        @lib_file
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
        |> Enum.join("\n")

      calls = Regex.scan(~r/\bRepo\.(\w+)/, source, return: :index)
      assert calls != []

      for [{start, len}, {name_start, name_len}] <- calls do
        name = binary_part(source, name_start, name_len)

        unless name == "rollback" do
          window = binary_part(source, start, min(900, byte_size(source) - start))
          assert window =~ "prefix:", "Repo.#{name} (#{len}) without :prefix"
        end
      end
    end

    test "S2-6b: a row of tenant A is invisible through tenant B's prefix" do
      {a, pack_id} = setup_pack!("s2ov-6a")
      b = tenant!("s2ov-6b")
      row = create!(a, pack_id)

      assert {:ok, _} = Overrides.latest(a.schema_name, row.override_id)
      assert {:error, :not_found} = Overrides.latest(b.schema_name, row.override_id)
      assert Overrides.history(b.schema_name, row.override_id) == []

      assert {:error, :not_found} =
               Overrides.retire(b.schema_name, actor(), row.override_id, %{reason: "x"})

      assert {:error, :not_found} =
               Overrides.new_version(b.schema_name, b.tenant_id, actor(), row.override_id, %{
                 patch: %{"nodes.n1.label" => "x"},
                 reason: "r"
               })

      assert %SolutionPackOverride{} =
               Repo.get!(SolutionPackOverride, row.id, prefix: a.schema_name)
    end
  end
end
