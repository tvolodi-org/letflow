defmodule Letflow.KeycloakTenantRealmTemplateTest do
  @moduledoc """
  Drift test for the tenant realm template `priv/keycloak/provisioner/v1/tenant-realm.json`
  (REQ-572 criterion 15, decision 0072 D2). File-only: no Keycloak, no database.

  `violations/1` returns an atom per broken rule. The shipped template must give `[]`, and
  each rule is shown to bite by a mutated copy. The runbook's Realm checklist is read too, so
  a new row forces a decision: map it to a check or declare it not checkable from the file.
  """
  use ExUnit.Case, async: true

  @dir Path.expand("../../priv/keycloak/provisioner/v1", __DIR__)
  @template Path.join(@dir, "tenant-realm.json")
  @readme Path.join(@dir, "README.md")
  @dev_seed Path.expand("../../priv/keycloak/realms/bpm-default.json", __DIR__)
  @runbook Path.expand("../../docs/runbooks/onboarding-new-tenant-realm.md", __DIR__)

  @roles ~w(TENANT_ADMIN PROCESS_DESIGNER PROCESS_OPERATOR TASK_WORKER AGENT_RUNNER CANDIDATE TENANT_AUDITOR)

  # Runbook checklist row (prefix of its first column) => checks that cover it.
  @checkable %{
    "`TENANT_ADMIN` exists as a plain" => [
      :tenant_admin_missing,
      :role_set_wrong,
      :tenant_admin_not_plain,
      :tenant_admin_in_default,
      :groups_present
    ],
    "\"Duplicate emails\"" => [:duplicate_emails_on],
    "Self-registration" => [:registration_on],
    "No brokered identity provider" => [
      :identity_provider_present,
      :identity_provider_trust_email
    ],
    "\"Verify email\"" => [:verify_email_off],
    "Users cannot edit their own e-mail" => [:email_not_user_editable],
    "The `email` and `email_verified` mappers" => [:email_scope_missing],
    "The realm never issues `PLATFORM_ADMIN`" => [:platform_admin]
  }

  # Rows about a live user, onboarding response, deployment env or a person: not in the file.
  @not_checkable [
    "The first user's e-mail is verified",
    "Pending administrator",
    "`LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS`",
    "Realm ownership confirmed by"
  ]

  defp template, do: @template |> File.read!() |> Jason.decode!()

  defp mutate(fun), do: fun.(template())

  # ---- the rules -----------------------------------------------------------------------

  def violations(realm) do
    checks = [
      &version/1,
      &users/1,
      &platform_admin/1,
      &roles/1,
      &tenant_admin_default/1,
      &settings/1,
      &identity_providers/1,
      &email_editable/1,
      &client/1,
      &mappers/1,
      &email_scope/1,
      &wildcards/1,
      &placeholders/1,
      &secrets/1
    ]

    checks |> Enum.flat_map(& &1.(realm)) |> Enum.uniq()
  end

  defp version(realm) do
    case get_in(realm, ["attributes", "templateVersion"]) do
      v when is_binary(v) -> if v =~ ~r/^\d+$/, do: [], else: [:version_missing]
      _ -> [:version_missing]
    end
  end

  defp users(realm) do
    case Map.get(realm, "users") do
      nil -> []
      [] -> []
      _ -> [:users_present]
    end
  end

  defp platform_admin(realm) do
    if Jason.encode!(realm) =~ "PLATFORM_ADMIN", do: [:platform_admin], else: []
  end

  defp realm_roles(realm), do: get_in(realm, ["roles", "realm"]) || []

  defp roles(realm) do
    rs = realm_roles(realm)
    names = Enum.map(rs, & &1["name"])

    missing = if "TENANT_ADMIN" in names, do: [], else: [:tenant_admin_missing]
    wrong = if Enum.sort(names) == Enum.sort(@roles), do: [], else: [:role_set_wrong]

    composite? =
      Enum.any?(rs, &(&1["composite"] == true or Map.has_key?(&1, "composites"))) or
        Map.has_key?(realm["roles"] || %{}, "composites") or
        Map.has_key?(realm["roles"] || %{}, "client")

    missing ++ wrong ++ if(composite?, do: [:tenant_admin_not_plain], else: [])
  end

  defp tenant_admin_default(realm) do
    named = Enum.filter(realm_roles(realm), &String.starts_with?(&1["name"], "default-roles-"))
    in_default_role = Enum.any?(named, &(Jason.encode!(&1) =~ "TENANT_ADMIN"))

    others =
      (Map.get(realm, "defaultGroups") || []) != [] or
        Enum.any?(
          ["defaultRole", "scopeMappings", "clientScopeMappings"],
          fn k -> realm |> Map.get(k) |> present_with_admin?() end
        ) or
        Enum.any?(realm["clients"] || [], &present_with_admin?(Map.get(&1, "scopeMappings"))) or
        Enum.any?(realm["clientScopes"] || [], &(Jason.encode!(&1) =~ "TENANT_ADMIN")) or
        (Map.get(realm, "groups") || []) |> Enum.any?(&(Jason.encode!(&1) =~ "TENANT_ADMIN"))

    groups = if (Map.get(realm, "groups") || []) == [], do: [], else: [:groups_present]

    if in_default_role or others, do: [:tenant_admin_in_default | groups], else: groups
  end

  defp present_with_admin?(nil), do: false
  defp present_with_admin?(v), do: Jason.encode!(v) =~ "TENANT_ADMIN"

  defp settings(realm) do
    [
      {realm["verifyEmail"] == true, :verify_email_off},
      {realm["duplicateEmailsAllowed"] == false, :duplicate_emails_on},
      {realm["registrationAllowed"] == false, :registration_on},
      {realm["bruteForceProtected"] == true, :brute_force_off},
      {is_binary(realm["passwordPolicy"]) and String.trim(realm["passwordPolicy"]) != "",
       :password_policy_empty}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp identity_providers(realm) do
    case Map.get(realm, "identityProviders") || [] do
      [] ->
        []

      idps ->
        [:identity_provider_present] ++
          if Enum.any?(idps, &(&1["trustEmail"] == true)),
            do: [:identity_provider_trust_email],
            else: []
    end
  end

  defp profile(realm) do
    comps = get_in(realm, ["components", "org.keycloak.userprofile.UserProfileProvider"]) || []

    comps
    |> Enum.flat_map(&(get_in(&1, ["config", "kc.user.profile.config"]) || []))
    |> List.wrap()
    |> Enum.map(&Jason.decode!/1)
  end

  # The template uses the declarative-profile option of the runbook row (email edit is admin-only).
  defp email_editable(realm) do
    email_attr =
      for p <- profile(realm), a <- p["attributes"] || [], a["name"] == "email", do: a

    ok =
      realm["editUsernameAllowed"] == false and email_attr != [] and
        Enum.all?(email_attr, &("user" not in (get_in(&1, ["permissions", "edit"]) || [])))

    if ok, do: [], else: [:email_not_user_editable]
  end

  defp web_clients(realm),
    do: Enum.filter(realm["clients"] || [], &(&1["clientId"] == "letflow-web"))

  defp client(realm) do
    ok =
      match?([_], realm["clients"] || []) and
        match?(
          [%{"publicClient" => true, "directAccessGrantsEnabled" => false}],
          web_clients(realm)
        ) and
        Enum.all?(web_clients(realm), fn c ->
          c["serviceAccountsEnabled"] != true and c["implicitFlowEnabled"] != true
        end)

    if ok, do: [], else: [:client_wrong]
  end

  defp mapper(realm, name) do
    web_clients(realm)
    |> Enum.flat_map(&(&1["protocolMappers"] || []))
    |> Enum.find(&(&1["name"] == name))
  end

  defp mappers(realm) do
    roles = mapper(realm, "realm-roles")
    aud = mapper(realm, "letflow-web-audience")

    ok =
      match?(
        %{
          "protocolMapper" => "oidc-usermodel-realm-role-mapper",
          "config" => %{"claim.name" => "roles", "access.token.claim" => "true"}
        },
        roles
      ) and
        match?(
          %{
            "protocolMapper" => "oidc-audience-mapper",
            "config" => %{
              "included.client.audience" => "letflow-web",
              "access.token.claim" => "true"
            }
          },
          aud
        )

    if ok, do: [], else: [:mappers_missing]
  end

  # The client sets no defaultClientScopes: the realm's built-in defaults apply (email, basic
  # with `sub`, ...). An explicit list replaces them, so it must keep both `email` and `basic`.
  # A realm-level clientScopes list, if ever added, must define the email mappers itself.
  defp email_scope(realm) do
    client_ok =
      Enum.all?(web_clients(realm), fn c ->
        case Map.get(c, "defaultClientScopes") do
          nil -> true
          l when is_list(l) -> "email" in l and "basic" in l
          _ -> false
        end
      end)

    realm_ok =
      case Map.get(realm, "clientScopes") do
        nil -> true
        scopes -> email_scope_defined?(scopes)
      end

    if client_ok and realm_ok, do: [], else: [:email_scope_missing]
  end

  defp email_scope_defined?(scopes) do
    Enum.any?(scopes, fn s ->
      s["name"] == "email" and
        Enum.any?(s["protocolMappers"] || [], &(&1["name"] == "email")) and
        Enum.any?(s["protocolMappers"] || [], fn m ->
          m["name"] == "email verified" and
            get_in(m, ["config", "claim.name"]) == "email_verified" and
            get_in(m, ["config", "jsonType.label"]) == "boolean"
        end)
    end)
  end

  defp wildcards(realm) do
    clients = realm["clients"] || []
    bad = fn v -> v == "*" or String.starts_with?(v, "*") or String.contains?(v, "://*") end

    redirects = Enum.flat_map(clients, &(&1["redirectUris"] || []))
    origins = Enum.flat_map(clients, &(&1["webOrigins"] || []))

    if(Enum.any?(redirects, bad), do: [:wildcard_redirect], else: []) ++
      if Enum.any?(origins, bad), do: [:wildcard_origin], else: []
  end

  defp placeholders(realm) do
    clients = realm["clients"] || []

    hosts =
      Enum.flat_map(clients, &((&1["redirectUris"] || []) ++ (&1["webOrigins"] || [])))

    tokens =
      Regex.scan(~r/__[A-Z_]+__/, Jason.encode!(realm)) |> List.flatten() |> Enum.uniq()

    missing =
      if realm["realm"] == "__REALM_ID__" and hosts != [] and
           Enum.all?(hosts, &String.contains?(&1, "__TENANT_HOST__")),
         do: [],
         else: [:placeholder_missing]

    missing ++
      if Enum.all?(tokens, &(&1 in ["__REALM_ID__", "__TENANT_HOST__"])),
        do: [],
        else: [:unknown_placeholder]
  end

  # INV-4: no secrets, SMTP settings or password values in git.
  defp secrets(realm) do
    if secret_key?(realm), do: [:secret_in_file], else: []
  end

  defp secret_key?(m) when is_map(m) do
    Enum.any?(m, fn {k, v} ->
      k in ["credentials", "secret", "smtpServer", "password"] or secret_key?(v)
    end)
  end

  defp secret_key?(l) when is_list(l), do: Enum.any?(l, &secret_key?/1)
  defp secret_key?(_), do: false

  # ---- the shipped files ---------------------------------------------------------------

  describe "shipped template" do
    test "D1 template is clean and versioned" do
      realm = template()
      assert violations(realm) == []
      assert get_in(realm, ["attributes", "templateVersion"]) == "1"
      assert Path.basename(@dir) == "v1"
    end

    test "D2 README names the placeholders and what the provisioner adds" do
      readme = File.read!(@readme)

      for s <- [
            "__REALM_ID__",
            "__TENANT_HOST__",
            "templateVersion",
            "smtpServer",
            "initial_password",
            "default-roles-",
            "first administrator",
            "defaultClientScopes"
          ] do
        assert readme =~ s, "README misses #{s}"
      end
    end

    test "D3 dev seed bpm-default.json is still the dev seed" do
      seed = @dev_seed |> File.read!() |> Jason.decode!()
      assert Enum.any?(seed["users"], &(&1["username"] == "admin-user"))
    end

    test "R3 runbook points at the template" do
      assert normalize(File.read!(@runbook)) =~ "priv/keycloak/provisioner/v1/tenant-realm.json"
    end
  end

  # ---- every rule bites ----------------------------------------------------------------

  defp add_role(realm, role), do: update_in(realm, ["roles", "realm"], &(&1 ++ [role]))

  defp web(realm, fun), do: update_in(realm, ["clients"], fn [c] -> [fun.(c)] end)

  defp edit_profile(realm, fun) do
    update_in(realm, ["components", "org.keycloak.userprofile.UserProfileProvider"], fn [c] ->
      [
        update_in(c, ["config", "kc.user.profile.config"], fn [s] ->
          [s |> Jason.decode!() |> fun.() |> Jason.encode!()]
        end)
      ]
    end)
  end

  defp flagged(realm, atom), do: assert(atom in violations(realm), "expected #{atom}")

  describe "mutations are caught" do
    test "M1 TENANT_ADMIN in default-roles composites" do
      mutate(fn r ->
        add_role(r, %{
          "name" => "default-roles-x",
          "composite" => true,
          "composites" => %{"realm" => ["TENANT_ADMIN"]}
        })
      end)
      |> flagged(:tenant_admin_in_default)
    end

    test "M2 defaultGroups / groups" do
      r = mutate(&Map.put(&1, "defaultGroups", ["/g"]))
      flagged(r, :tenant_admin_in_default)
      g = mutate(&Map.put(&1, "groups", [%{"name" => "g", "realmRoles" => ["TENANT_ADMIN"]}]))
      flagged(g, :groups_present)
      flagged(g, :tenant_admin_in_default)
    end

    test "M3 client scope role mapping" do
      mutate(
        &Map.put(&1, "scopeMappings", [%{"clientScope" => "roles", "roles" => ["TENANT_ADMIN"]}])
      )
      |> flagged(:tenant_admin_in_default)
    end

    test "M4 composite TENANT_ADMIN" do
      mutate(fn r ->
        update_in(r, ["roles", "realm"], fn [a | rest] ->
          [Map.put(a, "composite", true) | rest]
        end)
      end)
      |> flagged(:tenant_admin_not_plain)
    end

    test "M4b TENANT_ADMIN removed" do
      mutate(fn r -> update_in(r, ["roles", "realm"], &tl/1) end)
      |> flagged(:tenant_admin_missing)
    end

    test "M5 duplicate e-mails on" do
      mutate(&Map.put(&1, "duplicateEmailsAllowed", true)) |> flagged(:duplicate_emails_on)
    end

    test "M6 self-registration on" do
      mutate(&Map.put(&1, "registrationAllowed", true)) |> flagged(:registration_on)
    end

    test "M7 identity provider with trust email" do
      r = mutate(&Map.put(&1, "identityProviders", [%{"alias" => "x", "trustEmail" => true}]))
      flagged(r, :identity_provider_trust_email)
      flagged(r, :identity_provider_present)
    end

    test "M8 verify email off" do
      mutate(&Map.put(&1, "verifyEmail", false)) |> flagged(:verify_email_off)
    end

    test "M9 user may edit own e-mail" do
      mutate(fn r ->
        edit_profile(r, fn p ->
          update_in(p, ["attributes"], fn attrs ->
            Enum.map(attrs, fn
              %{"name" => "email"} = a -> put_in(a, ["permissions", "edit"], ["admin", "user"])
              a -> a
            end)
          end)
        end)
      end)
      |> flagged(:email_not_user_editable)

      mutate(&Map.put(&1, "editUsernameAllowed", true)) |> flagged(:email_not_user_editable)
    end

    test "M10 explicit scope list without basic or email, absent list passes" do
      mutate(&web(&1, fn c -> Map.put(c, "defaultClientScopes", ["email", "profile"]) end))
      |> flagged(:email_scope_missing)

      mutate(&web(&1, fn c -> Map.put(c, "defaultClientScopes", ["basic", "profile"]) end))
      |> flagged(:email_scope_missing)

      ok = mutate(&web(&1, fn c -> Map.put(c, "defaultClientScopes", ["basic", "email"]) end))
      assert violations(ok) == []
      refute Map.has_key?(hd(template()["clients"]), "defaultClientScopes")
    end

    test "M10d realm clientScopes list without the email mappers" do
      mutate(&Map.put(&1, "clientScopes", [%{"name" => "email", "protocolMappers" => []}]))
      |> flagged(:email_scope_missing)
    end

    test "M11 brute force off, empty password policy" do
      mutate(&Map.put(&1, "bruteForceProtected", false)) |> flagged(:brute_force_off)
      mutate(&Map.put(&1, "passwordPolicy", " ")) |> flagged(:password_policy_empty)
    end

    test "M12 direct access grants on" do
      mutate(&web(&1, fn c -> Map.put(c, "directAccessGrantsEnabled", true) end))
      |> flagged(:client_wrong)
    end

    test "M13 mappers removed" do
      mutate(&web(&1, fn c -> Map.put(c, "protocolMappers", []) end)) |> flagged(:mappers_missing)

      mutate(&web(&1, fn c -> update_in(c, ["protocolMappers"], fn [a, _] -> [a] end) end))
      |> flagged(:mappers_missing)
    end

    test "M14 a user" do
      mutate(&Map.put(&1, "users", [%{"username" => "u"}])) |> flagged(:users_present)
    end

    test "M15 PLATFORM_ADMIN" do
      mutate(&add_role(&1, %{"name" => "PLATFORM_ADMIN"})) |> flagged(:platform_admin)
    end

    test "M16 wildcard redirect" do
      mutate(&web(&1, fn c -> Map.put(c, "redirectUris", ["*"]) end))
      |> flagged(:wildcard_redirect)

      mutate(&web(&1, fn c -> Map.put(c, "redirectUris", ["https://*/x"]) end))
      |> flagged(:wildcard_redirect)
    end

    test "M17 wildcard origin" do
      mutate(&web(&1, fn c -> Map.put(c, "webOrigins", ["*"]) end)) |> flagged(:wildcard_origin)
    end

    test "M18 version missing" do
      mutate(&Map.delete(&1, "attributes")) |> flagged(:version_missing)
      mutate(&put_in(&1, ["attributes", "templateVersion"], "")) |> flagged(:version_missing)
    end

    test "M19 unknown placeholder, fixed redirect" do
      mutate(&web(&1, fn c -> Map.put(c, "redirectUris", ["https://__TENANT_HOST__/__X__"]) end))
      |> flagged(:unknown_placeholder)

      mutate(&web(&1, fn c -> Map.put(c, "redirectUris", ["https://a.example/*"]) end))
      |> flagged(:placeholder_missing)
    end

    test "M20 secret key" do
      mutate(&Map.put(&1, "smtpServer", %{"host" => "h"})) |> flagged(:secret_in_file)
    end
  end

  # ---- coupling to the runbook checklist -----------------------------------------------

  defp normalize(s), do: String.replace(s, "\r\n", "\n")

  defp checklist_rows do
    @runbook
    |> File.read!()
    |> normalize()
    |> String.split("## Realm checklist", parts: 2)
    |> List.last()
    |> String.split("\n## ", parts: 2)
    |> hd()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "| "))
    |> Enum.map(fn line -> line |> String.split("|") |> Enum.at(1) |> String.trim() end)
    |> Enum.reject(&(&1 in ["Item"] or String.starts_with?(&1, "---")))
  end

  describe "runbook Realm checklist" do
    test "R1 every row is checked or declared not checkable" do
      rows = checklist_rows()
      assert length(rows) >= 12

      for row <- rows do
        covered = Enum.any?(Map.keys(@checkable), &String.starts_with?(row, &1))
        declared = Enum.any?(@not_checkable, &String.starts_with?(row, &1))
        assert covered or declared, "checklist row has no check: #{row}"
      end
    end

    test "R2 the not-checkable rows are exactly the four declared" do
      rows = checklist_rows()

      declared =
        Enum.filter(rows, fn row -> Enum.any?(@not_checkable, &String.starts_with?(row, &1)) end)

      assert length(declared) == 4
      assert length(rows) - length(declared) == map_size(@checkable)
    end
  end
end
