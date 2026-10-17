defmodule Letflow.Identity.MintServicePrincipalTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2a, AC 13 (design `lib/letflow/design/req517-scoped-grants-admin-plane.md`
  section 3.12; spec `test/specs/REQ-517-2a.md`, T-E1..T-E7): the admin-flagged service principal
  relaxes ONLY the target side of the token mint check (`Identity.mint_token/4`, step 7).

    * unflagged target: roles must be held by the issuer AND the target (unchanged);
    * flagged target: roles need only be held tenant-wide by the ISSUER;
    * the issuer side is never relaxed, unflagging restores the refusal, and the flag is not
      inferred from any mint;
    * a token exceeding its flagged owner stays in the blocking `roles_exceed_owner` category;
    * `Letflow.Api.Scope.allowed?/3` has no input from the flag;
    * the column is written in `lib/` only by `Letflow.Identity.ServicePrincipal`.

  Issuers are real TENANT_ADMIN group members (`TokenMintFixture.role_holder!/2`).

  `async: false`: dedicated provisioned tenants (sandbox `:auto`), a VM-global platform pin.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Scope
  alias Letflow.Identity
  alias Letflow.Identity.ServicePrincipal
  alias Letflow.Identity.TokenPreconditions
  alias Letflow.Identity.User
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TokenMintFixture

  @admin_role "TENANT_ADMIN"
  @reason "service account for the nightly integration"

  # --- helpers ---------------------------------------------------------------------------------

  defp mint(fx, issuer, target, roles),
    do:
      Identity.mint_token(issuer.id, target.id, %{roles: roles, expires_at: nil},
        prefix: fx.schema_name
      )

  defp set_flag!(fx, user, flagged) do
    actor = %{user_id: fx.admin.id, trace_id: S.trace(), credential: "oidc"}

    assert {:ok, %{changed: true}} =
             ServicePrincipal.set_flag(user.id, flagged, @reason, actor, fx.schema_name)
  end

  # ===========================================================================================
  describe "T-E1..T-E4 the mint check" do
    test "before the flag a mint beyond the target's tenant-wide roles is refused; after it the mint succeeds when the ISSUER holds the role; after unflagging it is refused again" do
      fx = S.tenant!("r517-e1")
      target = RSG.user!(fx.schema_name)

      assert {:error, :roles_not_held} = mint(fx, fx.admin, target, [@admin_role])

      set_flag!(fx, target, true)

      assert {:ok, %{token: token, plaintext: plaintext}} =
               mint(fx, fx.admin, target, [@admin_role])

      assert token.user_id == target.id
      assert token.issuer_user_id == fx.admin.id
      assert token.roles == [@admin_role]
      assert String.starts_with?(plaintext, "lf_tok_")

      set_flag!(fx, target, false)
      assert {:error, :roles_not_held} = mint(fx, fx.admin, target, [@admin_role])
    end

    test "T-E3 the flag never relaxes the issuer side: a role the issuer does not hold is refused for a flagged target, and succeeds for an issuer that holds it" do
      fx = S.tenant!("r517-e3")
      s = fx.schema_name
      target = RSG.user!(s)
      # fx.admin holds only TENANT_ADMIN; admin2 holds TENANT_ADMIN and PROCESS_DESIGNER.
      admin2 = TokenMintFixture.role_holder!(s, [@admin_role, "PROCESS_DESIGNER"])
      set_flag!(fx, target, true)

      assert {:error, :roles_not_held} = mint(fx, fx.admin, target, ["PROCESS_DESIGNER"])

      assert {:error, :roles_not_held} =
               mint(fx, fx.admin, target, [@admin_role, "PROCESS_DESIGNER"])

      assert {:ok, %{token: token}} = mint(fx, admin2, target, ["PROCESS_DESIGNER"])
      assert token.roles == ["PROCESS_DESIGNER"]
      assert token.issuer_user_id == admin2.id
    end

    test "T-E4 an unflagged owner never gets the exemption, whoever minted the token" do
      fx = S.tenant!("r517-e4")
      s = fx.schema_name
      flagged = RSG.user!(s)
      unflagged = RSG.user!(s)
      admin2 = TokenMintFixture.role_holder!(s, [@admin_role])
      set_flag!(fx, flagged, true)

      for issuer <- [fx.admin, admin2] do
        assert {:error, :roles_not_held} = mint(fx, issuer, unflagged, [@admin_role])
        assert {:ok, _} = mint(fx, issuer, flagged, [@admin_role])
      end
    end

    test "the flag is not inferred: neither a refused nor a successful mint sets it" do
      fx = S.tenant!("r517-e4b")
      target = RSG.user!(fx.schema_name)

      assert {:error, :roles_not_held} = mint(fx, fx.admin, target, [@admin_role])
      refute Repo.get!(User, target.id, prefix: fx.schema_name).admin_flagged_service_principal
    end
  end

  # ===========================================================================================
  describe "T-E5 the flip rule is untouched" do
    test "a token exceeding its flagged owner stays in the blocking roles_exceed_owner category and flip_blocked stays true" do
      fx = S.tenant!("r517-e5")
      s = fx.schema_name
      owner = RSG.user!(s)
      set_flag!(fx, owner, true)
      assert {:ok, %{token: token}} = mint(fx, fx.admin, owner, [@admin_role])

      findings = TokenPreconditions.findings(s)

      assert Enum.map(findings.roles_exceed_owner, & &1.token.id) == [token.id]
      assert findings.service_principal_owner == [%{user_id: owner.id, token_ids: [token.id]}]
      assert TokenPreconditions.exceeding_owner_count(s) == 1

      conn =
        S.as_admin(Letflow.Routers.TenantScopeEnforcement, :get, "/token-preconditions", fx, nil)

      assert conn.status == 200
      assert S.body(conn)["flip_blocked"] == true
    end
  end

  # ===========================================================================================
  describe "T-E6 Scope.allowed?/3 does not read the flag" do
    test "a flagged and an unflagged user with the same rows get the same decisions, tenant-wide and scoped" do
      fx = S.tenant!("r517-e6")
      s = fx.schema_name
      flagged = TokenMintFixture.role_holder!(s, ["TASK_WORKER"])
      plain = TokenMintFixture.role_holder!(s, ["TASK_WORKER"])
      node = RSG.node!(s)
      elsewhere = RSG.node!(s)
      set_flag!(fx, flagged, true)

      queries = [
        {:TasksRead, :tenant_wide},
        {:TasksRead, {:node, node}},
        {:TasksRead, {:node, elsewhere}},
        {:UsersGroupsRolesManage, :tenant_wide}
      ]

      decisions = fn user ->
        p = S.principal(fx, user.id)
        for {permission, resource} <- queries, do: Scope.allowed?(p, permission, resource)
      end

      assert decisions.(flagged) == decisions.(plain)

      # the same after the TASK_WORKER group is narrowed to one node
      _ = RSG.make_group_scoped_only!(s, RSG.group_of!(s, "TASK_WORKER"), "TASK_WORKER")
      assert decisions.(flagged) == decisions.(plain)
      assert {:deny, :no_grant_rows} not in decisions.(flagged)
    end
  end

  # ===========================================================================================
  describe "T-E7 the column has one writer" do
    @column "admin_flagged_service_principal"
    @write_pattern ~r/\b(cast|change|put_change|force_change|update_all|update!|insert_all|set:)\b|\bSET\b/

    defp lib_lines_with_column do
      for path <- Path.wildcard("lib/**/*.ex"),
          path = String.replace(path, "\\", "/"),
          {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          String.contains?(line, @column),
          not String.starts_with?(String.trim_leading(line), "#"),
          do: {path, number, line}
    end

    test "outside Letflow.Identity.ServicePrincipal no line of lib/ that names the column writes it" do
      lines = lib_lines_with_column()
      assert lines != []

      writers =
        for {path, number, line} <- lines,
            path != "lib/letflow/identity/service_principal.ex",
            Regex.match?(@write_pattern, line),
            do: "#{path}:#{number}: #{String.trim(line)}"

      assert writers == []
    end

    test "only the schema field, the single writer, the two list_tokens reads, the response key, the manifest name and docs mention the column" do
      files =
        for {path, _number, _line} <- lib_lines_with_column(), uniq: true, do: path

      assert Enum.sort(files) ==
               Enum.sort([
                 "lib/letflow/identity.ex",
                 "lib/letflow/identity/service_principal.ex",
                 "lib/letflow/identity/user.ex",
                 "lib/letflow/routers/identity.ex",
                 "lib/letflow/tenant_provisioning.ex"
               ])
    end

    test "no User changeset casts the column (string or atom key)" do
      for attrs <- [
            %{"admin_flagged_service_principal" => true},
            %{admin_flagged_service_principal: true}
          ] do
        base = %{
          "username" => "u-#{System.unique_integer([:positive])}",
          "display_name" => "U",
          "email" => "u#{System.unique_integer([:positive])}@example.com"
        }

        for changeset <- [
              User.create_changeset(%User{}, Map.merge(base, stringify(attrs))),
              User.profile_changeset(%User{}, stringify(attrs)),
              User.status_changeset(%User{}, stringify(attrs)),
              User.jit_changeset(%User{}, Map.merge(base, stringify(attrs)))
            ] do
          refute Map.has_key?(changeset.changes, :admin_flagged_service_principal)
        end
      end
    end

    defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end
end
