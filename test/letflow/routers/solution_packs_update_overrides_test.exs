defmodule Letflow.Routers.SolutionPacksUpdateOverridesTest do
  @moduledoc """
  REQ-617 / GH #3443 (decision 0069 D8 S4): update-review and update-apply read the tenant's
  solution-pack overrides. Test ids follow state/tasks/T-0893/design.md section 7: S4-no-override-unchanged,
  S4-keep, S4-conflict-resolved, S4-never-overwrites, S4-orphan, S4-permission, S4-reply-shape,
  C-update, V-first, F-1 and T-KEYS. Every request goes through the full `Letflow.Router` pipeline with
  a real API token.

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the platform-tenant pin is
  VM-global (same reasoning as `solution_pack_overrides_routes_test.exs`).

  The distinctive patch value is the node label `"Tier 987654.321"`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Definitions.SolutionPackOverride
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @admin "TENANT_ADMIN"
  @distinct "Tier 987654.321"
  @patch %{"nodes.n1.label" => @distinct}

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

  defp graph(label, n2 \\ "Two") do
    Jason.encode!(%{
      "nodes" => [
        %{"id" => "n1", "label" => label, "node_type" => "task"},
        %{"id" => "n2", "label" => n2, "node_type" => "task"}
      ]
    })
  end

  defp install!(fx, pack_id, bases) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    %SolutionPackInstall{}
    |> SolutionPackInstall.insert_changeset(%{
      tenant_id: fx.tenant_id,
      pack_id: pack_id,
      installed_version: "1.0.0",
      installed_at: now
    })
    |> Repo.insert!()

    for {artefact_id, content} <- bases do
      %SolutionPackArtefactBase{}
      |> SolutionPackArtefactBase.upsert_changeset(%{
        tenant_id: fx.tenant_id,
        pack_id: pack_id,
        artefact_type: "process_definition",
        artefact_id: artefact_id,
        base_version: "1.0.0",
        base_content: content,
        captured_at: now
      })
      |> Repo.insert!()
    end

    :ok
  end

  defp call(method, path, token, fx, body \\ nil) do
    method |> Fixture.api_conn(path, token, fx.tenant.slug, body) |> Fixture.dispatch_api()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp pack_path(pack_id, leaf), do: "/api/v1/solution-packs/#{pack_id}/#{leaf}"

  defp art(id, content),
    do: %{"artefact_type" => "process_definition", "artefact_id" => id, "content" => content}

  defp res(id, resolution, content \\ nil) do
    base = %{
      "artefact_type" => "process_definition",
      "artefact_id" => id,
      "resolution" => resolution
    }

    if content, do: Map.put(base, "resolved_content", content), else: base
  end

  defp review(token, fx, pack_id, theirs, incoming, target \\ "1.1.0") do
    call(:post, pack_path(pack_id, "update-review"), token, fx, %{
      "target_version" => target,
      "theirs_artefacts" => theirs,
      "incoming_artefacts" => incoming
    })
  end

  defp apply_update(token, fx, pack_id, theirs, incoming, resolutions \\ [], target \\ "1.1.0") do
    call(:post, pack_path(pack_id, "update-apply"), token, fx, %{
      "target_version" => target,
      "theirs_artefacts" => theirs,
      "incoming_artefacts" => incoming,
      "resolutions" => resolutions
    })
  end

  defp create_override!(fx, token, pack_id, artefact_id, patch \\ @patch) do
    conn =
      call(:post, pack_path(pack_id, "overrides"), token, fx, %{
        "artefact_type" => "process_definition",
        "artefact_id" => artefact_id,
        "patch" => patch,
        "reason" => "local wording"
      })

    assert conn.status == 201, conn.resp_body
    json(conn)
  end

  defp override_rows(fx) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT override_id::text, override_version, pack_id, artefact_type, artefact_id, made_against, patch::text, patch_hash, status, reason, created_by::text, inserted_at FROM "#{fx.schema_name}".solution_pack_overrides ORDER BY override_id, override_version|
      )

    rows
  end

  defp audit_entries(fx) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT action, actor_id::text, after_state::text FROM "#{fx.schema_name}".audit_entries WHERE resource_type = 'solution_pack_override' ORDER BY timestamp, id|
      )

    rows
  end

  defp base_row(fx, pack_id, artefact_id) do
    Repo.one(
      from(b in SolutionPackArtefactBase,
        where:
          b.tenant_id == ^fx.tenant_id and b.pack_id == ^pack_id and b.artefact_id == ^artefact_id
      )
    )
  end

  defp resolution_count(fx, pack_id) do
    Repo.aggregate(
      from(r in PackUpdateResolution,
        where: r.tenant_id == ^fx.tenant_id and r.pack_id == ^pack_id
      ),
      :count
    )
  end

  defp entry(body, artefact_id),
    do: Enum.find(body["entries"] || body["applied_entries"], &(&1["artefact_id"] == artefact_id))

  # -- S4-no-override-unchanged ---------------------------------------------------------------

  describe "S4-no-override-unchanged" do
    test "five cases answer exactly as before, with no override key", ctx do
      pack_id = unique("s4plain")
      base = graph("A")

      install!(ctx.a, pack_id, [{"u", base}, {"c", base}, {"l", base}, {"x", base}, {"r", base}])
      token = Fixture.mint_token!(ctx.a, [@admin])

      theirs = [
        art("u", base),
        art("c", base),
        art("l", graph("L")),
        art("x", graph("L")),
        art("r", graph("L"))
      ]

      incoming = [
        art("u", base),
        art("c", graph("B")),
        art("l", base),
        art("x", graph("B")),
        art("r", graph("B"))
      ]

      conn = review(token, ctx.a, pack_id, theirs, incoming)
      assert conn.status == 200

      assert json(conn) == %{
               "pack_id" => pack_id,
               "target_version" => "1.1.0",
               "has_unresolved_conflicts" => true,
               "entries" => [
                 entry_wire("u", "unchanged", false),
                 entry_wire("c", "safe_to_update", false),
                 entry_wire("l", "local_only", false),
                 entry_wire("x", "both_sides_conflict", false),
                 entry_wire("r", "both_sides_conflict", false)
               ]
             }

      {:ok, plan} =
        Definitions.compute_pack_update_plan(
          ctx.a.tenant_id,
          pack_id,
          "1.1.0",
          Enum.map(theirs, &atom_art/1),
          Enum.map(incoming, &atom_art/1)
        )

      assert Enum.all?(plan.entries, &(&1.override == nil))

      conn =
        apply_update(token, ctx.a, pack_id, theirs, incoming, [
          res("x", "keep_local"),
          res("r", "take_incoming")
        ])

      assert conn.status == 200

      assert json(conn) == %{
               "pack_id" => pack_id,
               "target_version" => "1.1.0",
               "resolutions_recorded" => 2,
               "applied_entries" => [
                 applied_wire("u", "unchanged", "left_unchanged"),
                 applied_wire("c", "safe_to_update", "advanced_to_incoming"),
                 applied_wire("l", "local_only", "left_unchanged"),
                 applied_wire("x", "both_sides_conflict", "left_unchanged"),
                 applied_wire("r", "both_sides_conflict", "advanced_to_incoming")
               ]
             }

      assert override_rows(ctx.a) == []
    end

    test "a retired or an orphaned latest override changes nothing", ctx do
      pack_id = unique("s4inactive")
      base = graph("A")
      install!(ctx.a, pack_id, [{"c", base}, {"o", base}])
      token = Fixture.mint_token!(ctx.a, [@admin])

      v1 = create_override!(ctx.a, token, pack_id, "c")

      conn =
        call(:post, pack_path(pack_id, "overrides/#{v1["override_id"]}/retire"), token, ctx.a, %{
          "reason" => "done"
        })

      assert conn.status == 200

      Repo.insert!(
        %SolutionPackOverride{
          override_id: Ecto.UUID.generate(),
          override_version: 1,
          pack_id: pack_id,
          artefact_type: "process_definition",
          artefact_id: "o",
          made_against: "1.0.0",
          patch: @patch,
          patch_hash: "h",
          status: "orphaned",
          reason: "raw",
          created_by: Ecto.UUID.generate(),
          inserted_at: DateTime.utc_now()
        },
        prefix: ctx.a.schema_name
      )

      theirs = [art("c", base), art("o", base)]
      incoming = [art("c", graph("B")), art("o", graph("B"))]
      before = override_rows(ctx.a)

      conn = review(token, ctx.a, pack_id, theirs, incoming)
      assert conn.status == 200

      assert json(conn)["entries"] == [
               entry_wire("c", "safe_to_update", false),
               entry_wire("o", "safe_to_update", false)
             ]

      conn = apply_update(token, ctx.a, pack_id, theirs, incoming)
      assert conn.status == 200
      refute conn.resp_body =~ "override"
      assert override_rows(ctx.a) == before
    end
  end

  defp entry_wire(id, classification, resolved) do
    %{
      "artefact_type" => "process_definition",
      "artefact_id" => id,
      "classification" => classification,
      "resolved" => resolved
    }
  end

  defp applied_wire(id, classification, action) do
    %{
      "artefact_type" => "process_definition",
      "artefact_id" => id,
      "classification" => classification,
      "action" => action
    }
  end

  defp atom_art(%{"artefact_type" => t, "artefact_id" => i, "content" => c}),
    do: %{artefact_type: t, artefact_id: i, content: c}

  # -- S4-keep -----------------------------------------------------------------------------------

  describe "S4-keep" do
    test "unchanged and local_only are kept and advanced once", ctx do
      pack_id = unique("s4keep")
      base = graph("A")
      install!(ctx.a, pack_id, [{"a1", base}, {"a2", base}])
      token = Fixture.mint_token!(ctx.a, [@admin])
      o1 = create_override!(ctx.a, token, pack_id, "a1")
      o2 = create_override!(ctx.a, token, pack_id, "a2")
      theirs = [art("a1", base), art("a2", graph("Local"))]
      incoming = [art("a1", base), art("a2", base)]

      body = review(token, ctx.a, pack_id, theirs, incoming) |> json()
      assert entry(body, "a1")["override"]["outcome"] == "kept"
      refute Map.has_key?(entry(body, "a1")["override"], "warning")
      assert entry(body, "a2")["classification"] == "local_only"
      assert entry(body, "a2")["override"]["outcome"] == "kept"
      assert entry(body, "a2")["override"]["override_id"] == o2["override_id"]

      before = override_rows(ctx.a)
      audits_before = length(audit_entries(ctx.a))

      conn = apply_update(token, ctx.a, pack_id, theirs, incoming)
      assert conn.status == 200, conn.resp_body
      applied = json(conn)
      assert entry(applied, "a1")["override_action"] == "advanced"
      assert entry(applied, "a2")["override_action"] == "advanced"

      after_rows = override_rows(ctx.a)
      assert length(after_rows) == length(before) + 2
      assert Enum.take(after_rows -- after_rows, 0) == []

      for {o, v1} <- [{o1, "a1"}, {o2, "a2"}] do
        [old] = Enum.filter(before, &(hd(&1) == o["override_id"]))
        assert old in after_rows
        [_, new] = Enum.filter(after_rows, &(hd(&1) == o["override_id"]))
        # version, made_against, status advance; the patch and its hash are the same
        assert Enum.at(new, 1) == 2
        assert Enum.at(new, 5) == "1.1.0"
        assert Enum.at(new, 6) == Enum.at(old, 6)
        assert Enum.at(new, 7) == Enum.at(old, 7)
        assert Enum.at(new, 8) == "active"
        assert Enum.at(new, 9) == "pack update to 1.1.0: advanced"
        assert v1 in ["a1", "a2"]
      end

      new_audits = Enum.drop(audit_entries(ctx.a), audits_before)
      assert length(new_audits) == 2

      assert Enum.all?(new_audits, fn [action, _actor, state] ->
               state = Jason.decode!(state)

               action == "solution_pack.override_update_advanced" and
                 state["action"] == "advanced" and
                 state["target_version"] == "1.1.0" and is_binary(state["patch_hash"])
             end)

      # a second identical apply writes nothing
      again = override_rows(ctx.a)
      audits = length(audit_entries(ctx.a))
      conn = apply_update(token, ctx.a, pack_id, theirs, incoming)
      assert conn.status == 200
      assert entry(json(conn), "a1")["override_action"] == "left_unchanged"
      assert override_rows(ctx.a) == again
      assert length(audit_entries(ctx.a)) == audits
    end

    test "a changed artefact whose patched paths are untouched is kept with a warning", ctx do
      pack_id = unique("s4warn")
      base = graph("A", "Two")
      install!(ctx.a, pack_id, [{"a1", base}])
      token = Fixture.mint_token!(ctx.a, [@admin])
      create_override!(ctx.a, token, pack_id, "a1")
      theirs = [art("a1", base)]
      incoming = [art("a1", graph("A", "Changed"))]

      body = review(token, ctx.a, pack_id, theirs, incoming) |> json()
      assert entry(body, "a1")["classification"] == "safe_to_update"
      assert entry(body, "a1")["override"]["outcome"] == "kept"
      assert entry(body, "a1")["override"]["warning"] == "override_kept_pack_changed"

      conn = apply_update(token, ctx.a, pack_id, theirs, incoming)
      assert conn.status == 200
      assert entry(json(conn), "a1")["override_action"] == "advanced"
      assert base_row(ctx.a, pack_id, "a1").base_content == hd(incoming)["content"]
    end
  end

  # -- S4-conflict-resolved ----------------------------------------------------------------------

  describe "S4-conflict-resolved" do
    defp conflict_world(ctx, kind) do
      pack_id = unique("s4conf")
      base = graph("A")
      install!(ctx.a, pack_id, [{"a1", base}])
      token = Fixture.mint_token!(ctx.a, [@admin])
      override = create_override!(ctx.a, token, pack_id, "a1")
      theirs = if kind == :clean_update, do: base, else: graph("Local")
      {pack_id, token, override, [art("a1", theirs)], [art("a1", graph("Incoming"))]}
    end

    for kind <- [:clean_update, :conflict] do
      test "#{kind}: review shows override_conflict; apply without a resolution writes nothing",
           ctx do
        {pack_id, token, _o, theirs, incoming} = conflict_world(ctx, unquote(kind))
        body = review(token, ctx.a, pack_id, theirs, incoming) |> json()
        assert entry(body, "a1")["override"]["outcome"] == "override_conflict"
        assert entry(body, "a1")["resolved"] == false
        assert body["has_unresolved_conflicts"] == true

        rows = override_rows(ctx.a)
        base_before = base_row(ctx.a, pack_id, "a1")
        conn = apply_update(token, ctx.a, pack_id, theirs, incoming)
        assert conn.status == 409
        assert conn.resp_body =~ "unresolved conflict on artefact_type=process_definition"
        assert override_rows(ctx.a) == rows
        assert base_row(ctx.a, pack_id, "a1").base_content == base_before.base_content
        assert resolution_count(ctx.a, pack_id) == 0
      end
    end

    test "keep_local advances the override; a repeated review shows resolved true", ctx do
      {pack_id, token, o, theirs, incoming} = conflict_world(ctx, :conflict)
      conn = apply_update(token, ctx.a, pack_id, theirs, incoming, [res("a1", "keep_local")])
      assert conn.status == 200, conn.resp_body
      assert entry(json(conn), "a1")["override_action"] == "advanced"

      [_, new] = Enum.filter(override_rows(ctx.a), &(hd(&1) == o["override_id"]))
      assert Enum.at(new, 8) == "active" and Enum.at(new, 5) == "1.1.0"

      body = review(token, ctx.a, pack_id, theirs, incoming) |> json()
      assert entry(body, "a1")["resolved"] == true
    end

    test "take_incoming retires the override with an empty patch", ctx do
      {pack_id, token, o, theirs, incoming} = conflict_world(ctx, :clean_update)
      conn = apply_update(token, ctx.a, pack_id, theirs, incoming, [res("a1", "take_incoming")])
      assert conn.status == 200, conn.resp_body
      assert entry(json(conn), "a1")["override_action"] == "retired"

      [_, new] = Enum.filter(override_rows(ctx.a), &(hd(&1) == o["override_id"]))
      assert Enum.at(new, 6) == "{}"
      assert Enum.at(new, 8) == "retired"
      assert Enum.at(new, 9) == "pack update to 1.1.0: retired"
      assert [_create, [action, _actor, _state]] = audit_entries(ctx.a)
      assert action == "solution_pack.override_update_retired"
    end

    test "merged is refused and nothing is written", ctx do
      {pack_id, token, _o, theirs, incoming} = conflict_world(ctx, :conflict)
      rows = override_rows(ctx.a)
      audits = audit_entries(ctx.a)

      conn =
        apply_update(token, ctx.a, pack_id, theirs, incoming, [
          res("a1", "merged", graph("Merged"))
        ])

      assert conn.status == 422
      assert conn.resp_body =~ "override_merge_unsupported"
      assert override_rows(ctx.a) == rows
      assert audit_entries(ctx.a) == audits
      assert resolution_count(ctx.a, pack_id) == 0
      assert base_row(ctx.a, pack_id, "a1").base_content == graph("A")
    end
  end

  # -- S4-never-overwrites -----------------------------------------------------------------------

  describe "S4-never-overwrites" do
    test "an unresolved conflict on another artefact rolls back the override writes", ctx do
      pack_id = unique("s4roll")
      base = graph("A")
      install!(ctx.a, pack_id, [{"a1", base}, {"a2", base}])
      token = Fixture.mint_token!(ctx.a, [@admin])
      create_override!(ctx.a, token, pack_id, "a1")
      theirs = [art("a1", base), art("a2", graph("Local"))]
      incoming = [art("a1", base), art("a2", graph("Incoming"))]
      rows = override_rows(ctx.a)
      audits = audit_entries(ctx.a)

      conn = apply_update(token, ctx.a, pack_id, theirs, incoming)
      assert conn.status == 409
      assert override_rows(ctx.a) == rows
      assert audit_entries(ctx.a) == audits
    end

    test "the changed files never update or delete override rows" do
      for file <- [
            "lib/letflow/definitions/pack_update_overrides.ex",
            "lib/letflow/definitions/solution_pack_overrides.ex",
            "lib/letflow/definitions/solution_pack.ex"
          ] do
        source = File.read!(file)

        for token <- [
              "Repo.update",
              "Repo.delete",
              "update_all",
              "delete_all",
              "UPDATE ",
              "DELETE "
            ] do
          refute source =~ token, "#{file} contains #{token}"
        end
      end
    end
  end

  # -- S4-orphan -----------------------------------------------------------------------------------

  describe "S4-orphan" do
    defp orphan_world(ctx, theirs_content, base_content) do
      pack_id = unique("s4orph")
      base = graph("A")
      install!(ctx.a, pack_id, [{"gone", base}, {"keep", base}])
      token = Fixture.mint_token!(ctx.a, [@admin])
      override = create_override!(ctx.a, token, pack_id, "gone")

      case base_content do
        :same ->
          :ok

        :nil_base ->
          Repo.delete_all(
            from(b in SolutionPackArtefactBase,
              where: b.tenant_id == ^ctx.a.tenant_id and b.artefact_id == "gone"
            )
          )
      end

      theirs = [art("gone", theirs_content || base), art("keep", base)]
      {pack_id, token, override, theirs, [art("keep", base)]}
    end

    for {name, theirs, base} <- [
          {"theirs equals base", nil, :same},
          {"theirs differs from base", "differs", :same},
          {"no base row", nil, :nil_base}
        ] do
      test "orphaned override, #{name}: apply answers 200 and writes the orphaned row", ctx do
        theirs_content = if unquote(theirs), do: graph("Local"), else: nil
        {pack_id, token, o, theirs, incoming} = orphan_world(ctx, theirs_content, unquote(base))
        base_before = base_row(ctx.a, pack_id, "gone")

        body = review(token, ctx.a, pack_id, theirs, incoming) |> json()
        assert entry(body, "gone")["override"]["outcome"] == "orphaned"
        assert body["has_unresolved_conflicts"] == false

        before = override_rows(ctx.a)
        conn = apply_update(token, ctx.a, pack_id, theirs, incoming)
        assert conn.status == 200, conn.resp_body
        applied = entry(json(conn), "gone")
        assert applied["action"] == "left_unchanged"
        assert applied["override_action"] == "orphaned"
        assert base_row(ctx.a, pack_id, "gone") == base_before

        [old] = Enum.filter(before, &(hd(&1) == o["override_id"]))
        [^old, new] = Enum.filter(override_rows(ctx.a), &(hd(&1) == o["override_id"]))
        assert Enum.at(new, 8) == "orphaned"
        assert Enum.at(new, 6) == Enum.at(old, 6)
        assert Enum.at(new, 7) == Enum.at(old, 7)
        assert Enum.at(new, 9) == "pack update to 1.1.0: orphaned"

        assert [_create, [action, _, _]] = audit_entries(ctx.a)
        assert action == "solution_pack.override_update_orphaned"
      end
    end

    test "property_gone: a patch path off the closed list is kept as an orphaned row", ctx do
      pack_id = unique("s4gone")
      base = graph("A")
      install!(ctx.a, pack_id, [{"a1", base}])
      token = Fixture.mint_token!(ctx.a, [@admin])
      override_id = Ecto.UUID.generate()

      Repo.insert!(
        %SolutionPackOverride{
          override_id: override_id,
          override_version: 1,
          pack_id: pack_id,
          artefact_type: "process_definition",
          artefact_id: "a1",
          made_against: "1.0.0",
          patch: %{"nodes.n1.node_type" => "manual"},
          patch_hash: "h",
          status: "active",
          reason: "raw",
          created_by: Ecto.UUID.generate(),
          inserted_at: DateTime.utc_now()
        },
        prefix: ctx.a.schema_name
      )

      theirs = [art("a1", base)]
      incoming = [art("a1", graph("B"))]
      body = review(token, ctx.a, pack_id, theirs, incoming) |> json()
      assert entry(body, "a1")["override"]["outcome"] == "property_gone"

      conn = apply_update(token, ctx.a, pack_id, theirs, incoming)
      assert conn.status == 200, conn.resp_body
      assert entry(json(conn), "a1")["override_action"] == "property_gone"
      assert entry(json(conn), "a1")["action"] == "advanced_to_incoming"

      [_old, new] = override_rows(ctx.a)
      assert Enum.at(new, 8) == "orphaned"
      assert Enum.at(new, 6) =~ "manual"
      assert [[action, _, _]] = audit_entries(ctx.a)
      assert action == "solution_pack.override_update_property_gone"
    end
  end

  # -- S4-permission -----------------------------------------------------------------------------

  describe "S4-permission" do
    defp perm_world(ctx) do
      {pack_id, admin, o, theirs, incoming} = conflict_world(ctx, :clean_update)
      designer = Fixture.mint_token!(ctx.a, ["PROCESS_DESIGNER"])
      {pack_id, admin, designer, o, theirs, incoming}
    end

    test "a PROCESS_DESIGNER gets the route 403 for an override_conflict plan, nothing written",
         ctx do
      {pack_id, _admin, designer, _o, theirs, incoming} = perm_world(ctx)
      rows = override_rows(ctx.a)
      audits = audit_entries(ctx.a)

      for resolutions <- [[], [res("a1", "keep_local")]] do
        conn = apply_update(designer, ctx.a, pack_id, theirs, incoming, resolutions)
        assert conn.status == 403
        assert conn.resp_body =~ "insufficient permissions"
        assert override_rows(ctx.a) == rows
        assert audit_entries(ctx.a) == audits
        assert resolution_count(ctx.a, pack_id) == 0
      end
    end

    test "the same caller succeeds without an override_conflict; a TENANT_ADMIN succeeds", ctx do
      {pack_id, admin, designer, _o, _theirs, _incoming} = perm_world(ctx)
      same = [art("a1", graph("A"))]
      conn = apply_update(designer, ctx.a, pack_id, same, same)
      assert conn.status == 200, conn.resp_body

      theirs = [art("a1", graph("A"))]
      incoming = [art("a1", graph("Incoming"))]

      conn =
        apply_update(admin, ctx.a, pack_id, theirs, incoming, [res("a1", "keep_local")], "1.2.0")

      assert conn.status == 200, conn.resp_body
    end

    test "the transaction checks the permission again", ctx do
      {pack_id, _admin, _designer, _o, theirs, incoming} = perm_world(ctx)
      rows = override_rows(ctx.a)
      to_atoms = fn list -> Enum.map(list, &atom_art/1) end

      assert {:error, :override_permission_required} =
               SolutionPack.apply_pack_update(
                 pack_id,
                 "1.1.0",
                 to_atoms.(theirs),
                 to_atoms.(incoming),
                 [
                   %{
                     artefact_type: "process_definition",
                     artefact_id: "a1",
                     resolution: :keep_local,
                     resolved_content: nil
                   }
                 ],
                 prefix: ctx.a.schema_name,
                 actor_id: Ecto.UUID.generate()
               )

      assert override_rows(ctx.a) == rows
      assert resolution_count(ctx.a, pack_id) == 0
    end
  end

  # -- S4-reply-shape --------------------------------------------------------------------------------

  describe "S4-reply-shape" do
    test "the override object has exactly the allowed keys; no patch value leaks", ctx do
      {pack_id, token, _o, theirs, incoming} = conflict_world(ctx, :conflict)

      log =
        capture_log([level: :info], fn ->
          review_conn = review(token, ctx.a, pack_id, theirs, incoming)

          apply_conn =
            apply_update(token, ctx.a, pack_id, theirs, incoming, [res("a1", "keep_local")])

          send(self(), {:replies, review_conn, apply_conn})
        end)

      assert_received {:replies, review_conn, apply_conn}
      assert apply_conn.status == 200

      override = entry(json(review_conn), "a1")["override"]

      assert override |> Map.keys() |> Enum.sort() ==
               ~w(made_against outcome override_id override_version)

      keep = unique("shape-keep")
      install!(ctx.a, keep, [{"k", graph("A")}])
      create_override!(ctx.a, token, keep, "k")
      k = [art("k", graph("A"))]
      kept = entry(json(review(token, ctx.a, keep, k, k)), "k")["override"]

      assert kept |> Map.keys() |> Enum.sort() ==
               ~w(made_against outcome override_id override_version)

      warn = unique("shape-warn")
      install!(ctx.a, warn, [{"w", graph("A")}])
      create_override!(ctx.a, token, warn, "w")

      w =
        entry(
          json(
            review(token, ctx.a, warn, [art("w", graph("A"))], [art("w", graph("A", "Two!"))])
          ),
          "w"
        )["override"]

      assert w |> Map.keys() |> Enum.sort() ==
               ~w(made_against outcome override_id override_version warning)

      refute review_conn.resp_body =~ "987654.321"
      refute apply_conn.resp_body =~ "987654.321"
      refute log =~ "987654.321"

      for [_action, _actor, state] <- audit_entries(ctx.a) do
        refute state =~ "987654.321"
      end

      for table <- [PackUpdateResolution, SolutionPackArtefactBase, SolutionPackInstall] do
        refute table |> Repo.all() |> inspect(limit: :infinity) =~ "987654.321"
      end
    end
  end

  # -- T-KEYS ----------------------------------------------------------------------------------------

  describe "T-KEYS" do
    test "plan entries carry the previous keys plus :override", ctx do
      pack_id = unique("s4keys")
      install!(ctx.a, pack_id, [{"a1", graph("A")}])
      token = Fixture.mint_token!(ctx.a, [@admin])
      t = [%{artefact_type: "process_definition", artefact_id: "a1", content: graph("A")}]

      {:ok, plan} = Definitions.compute_pack_update_plan(ctx.a.tenant_id, pack_id, "1.1.0", t, t)
      [plain] = plan.entries

      assert plain |> Map.keys() |> Enum.sort() ==
               ~w(artefact_id artefact_type base classification incoming override resolved theirs)a

      create_override!(ctx.a, token, pack_id, "a1")
      {:ok, plan} = Definitions.compute_pack_update_plan(ctx.a.tenant_id, pack_id, "1.1.0", t, t)
      [with_override] = plan.entries

      assert with_override.override |> Map.keys() |> Enum.sort() ==
               ~w(made_against outcome override_id override_version)a

      refute inspect(plan) =~ "987654.321"
    end
  end

  # -- C-update ----------------------------------------------------------------------------------------

  describe "C-update" do
    test "tenant B never sees tenant A's override; tenant ids in the request are ignored", ctx do
      pack_id = unique("s4cross")
      base = graph("A")
      install!(ctx.a, pack_id, [{"a1", base}])
      install!(ctx.b, pack_id, [{"a1", base}])
      token_a = Fixture.mint_token!(ctx.a, [@admin])
      token_b = Fixture.mint_token!(ctx.b, [@admin])
      o = create_override!(ctx.a, token_a, pack_id, "a1")

      theirs = [art("a1", base)]
      incoming = [art("a1", graph("Incoming"))]

      with_ids = fn body ->
        Map.merge(body, %{"tenant_id" => ctx.a.tenant_id, "tenant" => ctx.a.schema_name})
      end

      review_body = %{
        "target_version" => "1.1.0",
        "theirs_artefacts" => theirs,
        "incoming_artefacts" => incoming
      }

      path = pack_path(pack_id, "update-review") <> "?tenant_id=#{ctx.a.tenant_id}"
      conn = call(:post, path, token_b, ctx.b, with_ids.(review_body))
      assert conn.status == 200
      refute Map.has_key?(entry(json(conn), "a1"), "override")
      refute conn.resp_body =~ o["override_id"]
      refute conn.resp_body =~ "override_conflict"

      apply_body = Map.put(review_body, "resolutions", [])

      conn =
        call(:post, pack_path(pack_id, "update-apply"), token_b, ctx.b, with_ids.(apply_body))

      assert conn.status == 200
      refute conn.resp_body =~ o["override_id"]
      refute conn.resp_body =~ "override"
      assert override_rows(ctx.b) == []

      # A's own rows are untouched by B's apply
      assert length(override_rows(ctx.a)) == 1
    end

    test "a PLATFORM_ADMIN token gets its own tenant's plan only", ctx do
      pack_id = unique("s4plat")
      base = graph("A")
      install!(ctx.a, pack_id, [{"a1", base}])
      install!(ctx.p, pack_id, [{"a1", base}])
      token_a = Fixture.mint_token!(ctx.a, [@admin])
      o = create_override!(ctx.a, token_a, pack_id, "a1")
      token_p = Fixture.mint_token!(ctx.p, ["PLATFORM_ADMIN"])

      conn = review(token_p, ctx.p, pack_id, [art("a1", base)], [art("a1", graph("Incoming"))])
      assert conn.status == 200, conn.resp_body
      refute conn.resp_body =~ o["override_id"]
      refute Map.has_key?(entry(json(conn), "a1"), "override")
    end

    test "every Repo call of the new path carries a prefix, except three named ones" do
      new_module = File.read!("lib/letflow/definitions/pack_update_overrides.ex")
      overrides = File.read!("lib/letflow/definitions/solution_pack_overrides.ex")

      # unit: the whole new module, plus apply_update_outcomes/4 and the private helpers it calls
      # (apply_update_item, update_attrs, lock!, latest_row, write, audit)
      units =
        [new_module] ++
          for name <-
                ~w(apply_update_outcomes apply_update_item update_attrs lock! latest_row write audit) do
            function_source(overrides, name)
          end

      call_form =
        ~r/(Repo\.(?:one|all|get_by|get|insert!?|exists\?|aggregate)\(|SQL\.query!?\(Repo,|Audit\.insert_entry\()/

      allowed = [
        "SELECT to_regclass($1)",
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        "SET LOCAL lock_timeout = '2s'"
      ]

      matched = for unit <- units, [_, form] <- Regex.scan(call_form, unit), do: form
      assert length(matched) >= 6

      for unit <- units, call <- calls_in(unit, call_form) do
        cond do
          String.contains?(call, "Audit.insert_entry(Repo, entry, prefix)") -> :ok
          Enum.any?(allowed, &String.contains?(call, &1)) -> :ok
          call =~ "prefix:" -> :ok
          true -> flunk("a Repo call without a prefix: #{call}")
        end
      end
    end
  end

  # the source of one top-level function, up to the next top-level definition
  defp function_source(source, name) do
    [_before, rest] = Regex.split(~r/^  defp? #{Regex.escape(name)}\(/m, source, parts: 2)
    rest |> String.split(~r/\n  (?:def|defp|@doc|# --)/, parts: 2) |> hd()
  end

  # each matching call with the text up to its closing line, enough to see its options
  defp calls_in(unit, call_form) do
    lines = String.split(unit, "\n")

    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _} -> Regex.match?(call_form, line) end)
    |> Enum.map(fn {_line, i} -> lines |> Enum.slice(i, 14) |> Enum.join("\n") end)
  end

  # -- V-first and F-1 ---------------------------------------------------------------------------------

  describe "V-first" do
    test "version refusals come first, even when the override table is unreadable", ctx do
      {pack_id, token, _o, theirs, incoming} = conflict_world(ctx, :clean_update)
      rows = override_rows(ctx.a)
      audits = audit_entries(ctx.a)

      for {target, text} <- [{"1.0.0", "version_not_newer"}, {"0.9.0", "version_downgrade"}] do
        conn = apply_update(token, ctx.a, pack_id, theirs, incoming, [], target)
        assert conn.status == 422
        assert conn.resp_body =~ text
      end

      assert override_rows(ctx.a) == rows
      assert audit_entries(ctx.a) == audits

      assert review(token, ctx.a, pack_id, theirs, incoming, "0.9.0").status == 422
      equal = review(token, ctx.a, pack_id, theirs, incoming, "1.0.0")
      assert equal.status == 200
      assert entry(json(equal), "a1")["override"]["outcome"] == "override_conflict"

      Repo.query!(~s|DROP TABLE "#{ctx.a.schema_name}".solution_pack_overrides|)
      conn = apply_update(token, ctx.a, pack_id, theirs, incoming, [], "1.0.0")
      assert conn.status == 422
      assert conn.resp_body =~ "version_not_newer"
    end
  end

  describe "F-1" do
    test "an audit failure answers 503 and leaves no override row", ctx do
      pack_id = unique("s4audit")
      base = graph("A")
      install!(ctx.a, pack_id, [{"a1", base}])
      token = Fixture.mint_token!(ctx.a, [@admin])
      create_override!(ctx.a, token, pack_id, "a1")
      rows = override_rows(ctx.a)
      Repo.query!(~s|DROP TABLE "#{ctx.a.schema_name}".audit_entries CASCADE|)

      log =
        capture_log([level: :info], fn ->
          conn = apply_update(token, ctx.a, pack_id, [art("a1", base)], [art("a1", base)])
          send(self(), {:conn, conn})
        end)

      assert_received {:conn, conn}
      assert conn.status == 503, conn.resp_body
      assert override_rows(ctx.a) == rows
      refute log =~ "987654.321"
    end
  end
end
