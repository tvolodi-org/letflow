defmodule Letflow.KeycloakTenantRealmTemplateV2Test do
  @moduledoc """
  Drift test for the tenant realm template `priv/keycloak/provisioner/v2/tenant-realm.json`
  (REQ-593, decision 0072 D2). File-only: no Keycloak, no database. The v1 template and its
  drift test are not touched; v2 is pinned as v1 plus six named keys.

  `violations/1` returns an atom per broken rule. The shipped template must give `[]`, and
  each rule is shown to bite by a mutated copy.
  """
  use ExUnit.Case, async: true

  @dir Path.expand("../../priv/keycloak/provisioner/v2", __DIR__)
  @template Path.join(@dir, "tenant-realm.json")
  @readme Path.join(@dir, "README.md")
  @v1_template Path.expand("../../priv/keycloak/provisioner/v1/tenant-realm.json", __DIR__)

  @added_keys ~w(resetPasswordAllowed actionTokenGeneratedByUserLifespan internationalizationEnabled supportedLocales defaultLocale)

  defp load(path), do: path |> File.read!() |> Jason.decode!()
  defp template, do: load(@template)
  defp mutate(fun), do: fun.(template())

  # ---- the rules -----------------------------------------------------------------------

  def violations(realm) do
    checks = [&version/1, &reset/1, &locale/1, &text_keys/1, &secrets/1, &users/1]
    checks |> Enum.flat_map(& &1.(realm)) |> Enum.uniq()
  end

  defp version(realm) do
    if get_in(realm, ["attributes", "templateVersion"]) == "2", do: [], else: [:version_wrong]
  end

  defp reset(realm) do
    flags =
      if realm["resetPasswordAllowed"] === true, do: [], else: [:reset_not_allowed]

    if realm["actionTokenGeneratedByUserLifespan"] === 3600,
      do: flags,
      else: [:reset_lifespan_wrong | flags]
  end

  defp locale(realm) do
    locales = realm["supportedLocales"]

    flags = if realm["internationalizationEnabled"] === true, do: [], else: [:i18n_off]

    flags =
      if is_list(locales) and length(locales) == 3 and Enum.sort(locales) == ["en", "kk", "ru"],
        do: flags,
        else: [:locales_wrong | flags]

    if realm["defaultLocale"] == "en", do: flags, else: [:default_locale_wrong | flags]
  end

  defp text_keys(realm) do
    if Enum.any?(~w(emailTheme loginTheme localizationTexts), &Map.has_key?(realm, &1)),
      do: [:text_carried],
      else: []
  end

  defp secrets(realm), do: if(secret_key?(realm), do: [:secret_in_file], else: [])

  defp users(realm), do: if(Map.has_key?(realm, "users"), do: [:users_present], else: [])

  defp secret_key?(m) when is_map(m) do
    Enum.any?(m, fn {k, v} ->
      k in ["credentials", "secret", "smtpServer", "password"] or secret_key?(v)
    end)
  end

  defp secret_key?(l) when is_list(l), do: Enum.any?(l, &secret_key?/1)
  defp secret_key?(_), do: false

  # ---- tests ---------------------------------------------------------------------------

  describe "shipped template" do
    test "V2-dir files exist, parse, version is 2" do
      assert File.regular?(@template)
      assert File.regular?(@readme)
      assert Path.basename(@dir) == "v2"
      realm = template()
      assert get_in(realm, ["attributes", "templateVersion"]) == "2"
      assert violations(realm) == []
    end

    test "V2-reset reset switch and 3600 s lifetime" do
      realm = template()
      assert realm["resetPasswordAllowed"] === true
      assert realm["actionTokenGeneratedByUserLifespan"] === 3600

      assert :reset_not_allowed in violations(mutate(&Map.delete(&1, "resetPasswordAllowed")))

      assert :reset_lifespan_wrong in violations(
               mutate(&Map.put(&1, "actionTokenGeneratedByUserLifespan", 300))
             )
    end

    test "V2-locale en ru kk and no texts" do
      realm = template()
      assert realm["internationalizationEnabled"] === true
      assert length(realm["supportedLocales"]) == 3
      assert Enum.sort(realm["supportedLocales"]) == ["en", "kk", "ru"]
      for key <- ~w(emailTheme loginTheme localizationTexts), do: refute(Map.has_key?(realm, key))

      assert :locales_wrong in violations(mutate(&Map.put(&1, "supportedLocales", ["en", "ru"])))

      assert :i18n_off in violations(mutate(&Map.put(&1, "internationalizationEnabled", false)))
      assert :text_carried in violations(mutate(&Map.put(&1, "emailTheme", "x")))
    end

    test "V2-same v2 is v1 plus the named keys" do
      v1 = load(@v1_template)
      v2 = template()

      stripped =
        v2
        |> Map.drop(@added_keys)
        |> Map.update!("attributes", &Map.delete(&1, "templateVersion"))

      assert stripped == Map.update!(v1, "attributes", &Map.delete(&1, "templateVersion"))

      placeholders =
        ~r/__[A-Z_]+__/ |> Regex.scan(File.read!(@template)) |> List.flatten() |> Enum.uniq()

      assert Enum.sort(placeholders) == ["__REALM_ID__", "__TENANT_HOST__"]
    end

    test "V2-smtp no smtp, secrets or users" do
      refute secret_key?(template())
      refute Map.has_key?(template(), "users")
      refute File.read!(@template) =~ ~r/smtp/i

      smtp = %{"host" => "mail.example.com"}
      assert :secret_in_file in violations(mutate(&Map.put(&1, "smtpServer", smtp)))

      assert :secret_in_file in violations(mutate(&put_in(&1, ["attributes", "password"], "x")))

      assert :users_present in violations(mutate(&Map.put(&1, "users", [])))
    end

    test "V2-readme names fields and states the rules" do
      readme = File.read!(@readme)

      for s <-
            ~w(__REALM_ID__ __TENANT_HOST__ templateVersion resetPasswordAllowed supportedLocales smtpServer emailTheme) do
        assert readme =~ s
      end

      assert readme =~ ~r/smtpServer. is mandatory for a v2 realm/
      assert readme =~ ~r/provisioner must refuse to create a v2 realm without it/
      assert readme =~ ~r/`v1` is frozen/
      assert readme =~ ~r/Outside the template/
      assert readme =~ ~r/(texts|localizationTexts)/
    end
  end
end
