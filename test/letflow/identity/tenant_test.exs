defmodule Letflow.Identity.TenantTest do
  use Letflow.DataCase, async: true

  alias Letflow.Identity.Tenant

  # No changeset function exists yet on `Tenant` (deferred to REQ-019, see
  # lib/letflow/design/identity-schema.md §3.1) — inserts here build the
  # struct directly and call Repo.insert/1, matching this project's existing
  # pattern for changeset-less schemas (Letflow.RowApproval.Approval).
  defp unique_slug, do: "tenant-#{Ecto.UUID.generate()}"

  test "two tenants with idp_realm_id: nil can both be inserted (partial index does not collide NULLs)" do
    assert {:ok, _} =
             Repo.insert(%Tenant{
               slug: unique_slug(),
               display_name: "Tenant A",
               idp_realm_id: nil
             })

    assert {:ok, _} =
             Repo.insert(%Tenant{
               slug: unique_slug(),
               display_name: "Tenant B",
               idp_realm_id: nil
             })
  end

  test "two tenants with the same non-null idp_realm_id: the second raises a constraint error" do
    realm_id = "realm-#{Ecto.UUID.generate()}"

    assert {:ok, _} =
             Repo.insert(%Tenant{
               slug: unique_slug(),
               display_name: "Tenant A",
               idp_realm_id: realm_id
             })

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(%Tenant{
        slug: unique_slug(),
        display_name: "Tenant B",
        idp_realm_id: realm_id
      })
    end
  end

  test "two tenants with the same slug: the second raises a constraint error" do
    slug = unique_slug()

    assert {:ok, _} =
             Repo.insert(%Tenant{slug: slug, display_name: "Tenant A"})

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(%Tenant{slug: slug, display_name: "Tenant B"})
    end
  end

  test "casting an invalid status value is rejected by the Ecto.Enum declaration" do
    changeset =
      Ecto.Changeset.cast(
        %Tenant{},
        %{slug: unique_slug(), display_name: "Tenant A", status: "bogus"},
        [:slug, :display_name, :status]
      )

    refute changeset.valid?
    assert %{status: _} = errors_on(changeset)
  end

  test "casting :inactive is accepted by the extended Ecto.Enum declaration (REQ-075)" do
    changeset =
      Ecto.Changeset.cast(
        %Tenant{},
        %{slug: unique_slug(), display_name: "Tenant A", status: "inactive"},
        [:slug, :display_name, :status]
      )

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :status) == :inactive
  end

  describe "admin_patch_changeset/2 (REQ-075)" do
    test "casts display_name but structurally cannot write status" do
      tenant = %Tenant{slug: unique_slug(), display_name: "Original", status: :active}

      changeset =
        Tenant.admin_patch_changeset(tenant, %{
          "display_name" => "Renamed",
          "status" => "inactive"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :display_name) == "Renamed"
      # :status was never cast -- no change key for it at all, not merely unchanged.
      refute Map.has_key?(changeset.changes, :status)
    end

    test "an attrs map with only display_name is a valid changeset" do
      tenant = %Tenant{slug: unique_slug(), display_name: "Original"}

      changeset = Tenant.admin_patch_changeset(tenant, %{"display_name" => "New Name"})

      assert changeset.valid?
    end
  end

  describe "status_changeset/2 (REQ-075)" do
    test "casts status but structurally cannot write display_name" do
      tenant = %Tenant{slug: unique_slug(), display_name: "Original", status: :active}

      changeset =
        Tenant.status_changeset(tenant, %{"status" => "inactive", "display_name" => "Renamed"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == :inactive
      refute Map.has_key?(changeset.changes, :display_name)
    end

    test "status is required (an explicit nil in attrs is rejected)" do
      tenant = %Tenant{slug: unique_slug(), display_name: "Original", status: :active}

      changeset = Tenant.status_changeset(tenant, %{"status" => nil})

      refute changeset.valid?
      assert %{status: _} = errors_on(changeset)
    end
  end

  describe "settings_changeset/2 (REQ-280)" do
    test "casts settings but is structurally incapable of touching status/slug/idp_realm_id/display_name" do
      tenant = %Tenant{
        slug: unique_slug(),
        display_name: "Original",
        status: :active,
        idp_realm_id: "realm-x"
      }

      changeset =
        Tenant.settings_changeset(tenant, %{
          "settings" => %{"app_name" => "Acme"},
          "status" => "inactive",
          "slug" => "hijacked-slug",
          "idp_realm_id" => "hijacked-realm",
          "display_name" => "Hijacked"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :settings) == %{"app_name" => "Acme"}
      # None of these were ever cast -- no change key at all, not merely unchanged.
      refute Map.has_key?(changeset.changes, :status)
      refute Map.has_key?(changeset.changes, :slug)
      refute Map.has_key?(changeset.changes, :idp_realm_id)
      refute Map.has_key?(changeset.changes, :display_name)
    end

    test "an absent/nil settings value is a valid changeset (tenant configured nothing yet)" do
      tenant = %Tenant{slug: unique_slug(), display_name: "Original"}

      changeset = Tenant.settings_changeset(tenant, %{})

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :settings)
    end

    test "an unrecognized top-level key is rejected at write time with a typed error naming the key" do
      tenant = %Tenant{slug: unique_slug(), display_name: "Original"}

      changeset =
        Tenant.settings_changeset(tenant, %{"settings" => %{"unknown_key" => "value"}})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert %{settings: [message]} = errors
      assert message =~ "unrecognized tenant setting key"
      assert message =~ "unknown_key"
    end

    test "app_name: a valid value round-trips through the database" do
      tenant = insert_tenant!()

      {:ok, updated} =
        tenant
        |> Tenant.settings_changeset(%{"settings" => %{"app_name" => "Acme Corp"}})
        |> Repo.update()

      reloaded = Repo.get!(Tenant, updated.id)
      assert reloaded.settings == %{"app_name" => "Acme Corp"}
    end

    test "app_name: a non-string value is rejected" do
      tenant = insert_tenant!()

      changeset =
        Tenant.settings_changeset(tenant, %{"settings" => %{"app_name" => 12345}})

      refute changeset.valid?
      assert %{settings: [_]} = errors_on(changeset)
    end

    test "app_name: exceeding the 100-character bound is rejected" do
      tenant = insert_tenant!()
      too_long = String.duplicate("a", 101)

      changeset =
        Tenant.settings_changeset(tenant, %{"settings" => %{"app_name" => too_long}})

      refute changeset.valid?
      assert %{settings: [_]} = errors_on(changeset)
    end

    test "logo_url: a valid absolute https URL round-trips through the database" do
      tenant = insert_tenant!()

      {:ok, updated} =
        tenant
        |> Tenant.settings_changeset(%{
          "settings" => %{"logo_url" => "https://example.com/logo.png"}
        })
        |> Repo.update()

      reloaded = Repo.get!(Tenant, updated.id)
      assert reloaded.settings == %{"logo_url" => "https://example.com/logo.png"}
    end

    test "logo_url: a relative path (not an absolute http(s) URL) is rejected" do
      tenant = insert_tenant!()

      changeset =
        Tenant.settings_changeset(tenant, %{"settings" => %{"logo_url" => "/relative/path.png"}})

      refute changeset.valid?
      assert %{settings: [_]} = errors_on(changeset)
    end

    test "logo_url: a non-http(s) scheme is rejected" do
      tenant = insert_tenant!()

      changeset =
        Tenant.settings_changeset(tenant, %{
          "settings" => %{"logo_url" => "ftp://example.com/logo.png"}
        })

      refute changeset.valid?
      assert %{settings: [_]} = errors_on(changeset)
    end

    test "brand_colors: a valid #RRGGBB primary color round-trips through the database" do
      tenant = insert_tenant!()

      # #1864AB (a dark blue) meets the WCAG AA 4.5:1 contrast minimum
      # (REQ-382) against both tokens.css reference backgrounds; #228be6
      # (this test's fixture before REQ-382) does not (~3.4:1/~3.6:1) and is
      # covered by the WCAG-rejection tests below instead.
      {:ok, updated} =
        tenant
        |> Tenant.settings_changeset(%{
          "settings" => %{"brand_colors" => %{"primary" => "#1864AB"}}
        })
        |> Repo.update()

      reloaded = Repo.get!(Tenant, updated.id)
      assert reloaded.settings == %{"brand_colors" => %{"primary" => "#1864AB"}}
    end

    test "brand_colors: a non-hex-format value is rejected" do
      tenant = insert_tenant!()

      changeset =
        Tenant.settings_changeset(tenant, %{
          "settings" => %{"brand_colors" => %{"primary" => "blue"}}
        })

      refute changeset.valid?
      assert %{settings: [_]} = errors_on(changeset)
    end

    test "brand_colors: an unrecognized inner key is rejected, naming the key" do
      tenant = insert_tenant!()

      changeset =
        Tenant.settings_changeset(tenant, %{
          "settings" => %{"brand_colors" => %{"tertiary" => "#228be6"}}
        })

      refute changeset.valid?
      assert %{settings: [message]} = errors_on(changeset)
      assert message =~ "tertiary"
    end

    test "brand_colors: allowed keys are exactly primary and secondary (REQ-585)" do
      assert Tenant.brand_colors_allowed_keys() == ["primary", "secondary"]
    end

    test "brand_colors: a valid secondary, alone or with primary, is accepted (REQ-585)" do
      tenant = insert_tenant!()

      for bc <- [
            %{"secondary" => "#1971C2"},
            %{"primary" => "#1864AB", "secondary" => "#1971C2"}
          ] do
        changeset = Tenant.settings_changeset(tenant, %{"settings" => %{"brand_colors" => bc}})
        assert changeset.valid?, inspect(errors_on(changeset))
      end
    end

    test "brand_colors: non-hex secondary values are refused, naming the key (REQ-585)" do
      tenant = insert_tenant!()

      for bad <- ["red", "#FFF", "#GG0000", 123] do
        changeset =
          Tenant.settings_changeset(tenant, %{
            "settings" => %{"brand_colors" => %{"secondary" => bad}}
          })

        refute changeset.valid?
        assert %{settings: [message]} = errors_on(changeset)
        assert message =~ "brand_colors.secondary"
        assert message =~ "hex"
      end
    end

    test "brand_colors: secondary gets the same contrast verdict as primary (REQ-585)" do
      tenant = insert_tenant!()

      verdict = fn key ->
        changeset =
          Tenant.settings_changeset(tenant, %{
            "settings" => %{"brand_colors" => %{key => "#FFFF00"}}
          })

        refute changeset.valid?
        assert %{settings: [message]} = errors_on(changeset)
        message
      end

      primary = verdict.("primary")
      secondary = verdict.("secondary")
      assert secondary =~ "brand_colors.secondary"

      assert String.replace(secondary, "brand_colors.secondary", "brand_colors.primary") ==
               primary
    end

    test "locales: a valid non-empty list of locale codes round-trips through the database" do
      tenant = insert_tenant!()

      {:ok, updated} =
        tenant
        |> Tenant.settings_changeset(%{"settings" => %{"locales" => ["en", "en-US"]}})
        |> Repo.update()

      reloaded = Repo.get!(Tenant, updated.id)
      assert reloaded.settings == %{"locales" => ["en", "en-US"]}
    end

    test "locales: a non-list value is rejected" do
      tenant = insert_tenant!()

      changeset =
        Tenant.settings_changeset(tenant, %{"settings" => %{"locales" => "en"}})

      refute changeset.valid?
      assert %{settings: [_]} = errors_on(changeset)
    end

    test "locales: an empty list is rejected" do
      tenant = insert_tenant!()

      changeset = Tenant.settings_changeset(tenant, %{"settings" => %{"locales" => []}})

      refute changeset.valid?
      assert %{settings: [_]} = errors_on(changeset)
    end

    test "default_locale: a valid value that is a member of locales round-trips through the database" do
      tenant = insert_tenant!()

      {:ok, updated} =
        tenant
        |> Tenant.settings_changeset(%{
          "settings" => %{"locales" => ["en", "fr"], "default_locale" => "fr"}
        })
        |> Repo.update()

      reloaded = Repo.get!(Tenant, updated.id)
      assert reloaded.settings == %{"locales" => ["en", "fr"], "default_locale" => "fr"}
    end

    test "default_locale: a value not present in locales is rejected" do
      tenant = insert_tenant!()

      changeset =
        Tenant.settings_changeset(tenant, %{
          "settings" => %{"locales" => ["en"], "default_locale" => "fr"}
        })

      refute changeset.valid?
      assert %{settings: [_]} = errors_on(changeset)
    end

    test "default_locale: a wrong-type value is rejected" do
      tenant = insert_tenant!()

      changeset =
        Tenant.settings_changeset(tenant, %{"settings" => %{"default_locale" => 42}})

      refute changeset.valid?
      assert %{settings: [_]} = errors_on(changeset)
    end

    test "REQ-595 A1: the closed vocabulary is exactly the seven keys" do
      assert Enum.sort(Letflow.Identity.TenantSettings.allowed_keys()) ==
               Enum.sort(
                 ~w(app_name logo_url brand_colors locales default_locale signatory_name signatory_title)
               )
    end

    test "REQ-595 V1: valid signatory values are accepted, nil clears" do
      tenant = insert_tenant!()
      max = String.duplicate("я", 100)

      for settings <- [
            %{"signatory_name" => "Aigerim Sadykova"},
            %{"signatory_title" => "Director"},
            %{"signatory_name" => "A", "signatory_title" => "B"},
            %{"signatory_name" => max, "signatory_title" => max},
            %{"signatory_name" => nil},
            %{"signatory_title" => nil}
          ] do
        changeset = Tenant.settings_changeset(tenant, %{"settings" => settings})
        assert changeset.valid?, "expected valid: #{inspect(settings)}"
      end
    end

    test "REQ-595 V2: invalid signatory values are refused naming the key" do
      tenant = insert_tenant!()

      for key <- ["signatory_name", "signatory_title"],
          value <- ["", "   ", String.duplicate("a", 101), "a\nb", "a\tb", "a\x7Fb", 42, <<255>>] do
        changeset = Tenant.settings_changeset(tenant, %{"settings" => %{key => value}})
        refute changeset.valid?, "expected invalid: #{key}=#{inspect(value)}"
        assert %{settings: [msg]} = errors_on(changeset)
        assert msg =~ key
      end
    end

    defp insert_tenant! do
      {:ok, tenant} =
        Repo.insert(%Tenant{slug: unique_slug(), display_name: "Original"})

      tenant
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
