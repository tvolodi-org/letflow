defmodule Letflow.GH2635TrailingNewlineTest do
  @moduledoc """
  GH #2635 -- format validators must be end-anchored with `\\z`, not `$` (PCRE `$`
  also matches just before ONE final newline, so `"name\\n"` passed). Each describe
  block drives one validator through its nearest public entry point. See
  `test/specs/GH-2635.md` for the test-case rationale and which cases are
  main-discriminating versus guards.

  Pure changeset / predicate calls only (no tenant provisioning), so `async: true`.
  The pg_type / generated_as DDL-boundary cases live in
  `test/letflow/tenant_provisioning/column_promotion_test.exs`.
  """

  use Letflow.DataCase, async: true

  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definition.Validator
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantMembership
  alias Letflow.Modules.Solutions
  alias Letflow.SandboxPool.FixtureLoader
  alias Letflow.SandboxPool.FixtureLoader.FixtureRow
  alias Letflow.Secrets
  alias Letflow.Secrets.Secret
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @hex32 String.duplicate("a1", 16)

  defp rules(definition) do
    case Validator.validate(definition) do
      :ok -> []
      {:error, violations} -> Enum.map(violations, & &1.rule)
    end
  end

  defp field_errors(changeset, field),
    do: changeset |> Map.fetch!(:errors) |> Keyword.get_values(field)

  defp def_named(name), do: %{name: name, display_name: "Named", fields: []}

  defp localized(locales) do
    %{
      name: "question",
      display_name: "Question",
      fields: [%{name: "stem", type: :localized_text, locales: locales}]
    }
  end

  defp color_cs(value),
    do:
      Tenant.settings_changeset(%Tenant{}, %{
        settings: %{"brand_colors" => %{"primary" => value}}
      })

  defp settings_cs(settings), do: Tenant.settings_changeset(%Tenant{}, %{settings: settings})

  defp reg_cs(schema_name),
    do:
      Registration.changeset(%Registration{}, %{
        tenant_id: Ecto.UUID.generate(),
        schema_name: schema_name
      })

  defp fixtures,
    do: [%FixtureRow{table_name: "process_definitions", row_json: Jason.encode!(%{})}]

  defp put_attrs(overrides) do
    Map.merge(
      %{
        tenant_id: Ecto.UUID.generate(),
        namespace: "ns",
        name: "key",
        purpose: :generic,
        plaintext: "s3cret",
        created_by: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp resolve(ref), do: Secrets.resolve(ref, tenant_id: Ecto.UUID.generate())

  defp secret_cs(attrs), do: Secret.insert_changeset(%Secret{}, attrs)

  # ---------------------------------------------------------------------------
  describe "GH #2635 Validator.validate/1 -- entity/definition name (:name_format)" do
    test "a trailing newline is refused" do
      assert :name_format in rules(def_named("customer\n"))
    end

    test "a leading newline is refused" do
      assert :name_format in rules(def_named("\ncustomer"))
    end

    test "an embedded newline is refused" do
      assert :name_format in rules(def_named("cust\nomer"))
    end

    test "a valid name is still accepted" do
      assert rules(def_named("customer")) == []
    end

    test "writable_by_process definitions reuse the same name check (trailing newline refused)" do
      assert :name_format in rules(Map.put(def_named("customer\n"), :writable_by_process, true))
      assert rules(Map.put(def_named("customer"), :writable_by_process, true)) == []
    end
  end

  describe "GH #2635 Validator.validate/1 -- localized_text locale (:invalid_localized_text)" do
    test "a locale with a trailing newline is refused" do
      assert :invalid_localized_text in rules(localized(["kk\n"]))
    end

    test "a leading / embedded newline locale is refused" do
      assert :invalid_localized_text in rules(localized(["\nkk"]))
      assert :invalid_localized_text in rules(localized(["k\nk"]))
    end

    test "valid locales are still accepted" do
      assert rules(localized(["kk", "ru"])) == []
    end
  end

  # ---------------------------------------------------------------------------
  describe "GH #2635 DDL.valid_identifier?/1" do
    test "trailing newline refused" do
      refute DDL.valid_identifier?("customer\n")
    end

    test "leading / embedded newline refused" do
      refute DDL.valid_identifier?("\ncustomer")
      refute DDL.valid_identifier?("cust\nomer")
    end

    test "valid identifier accepted" do
      assert DDL.valid_identifier?("customer")
    end
  end

  describe "GH #2635 DDL.valid_generated_as_expression?/1" do
    @plain "field_values->'stem'->>'kk'"
    @tsv "to_tsvector('simple', coalesce(field_values->'stem'->>'kk', ''))"

    test "a trailing newline is refused for both accepted shapes" do
      refute DDL.valid_generated_as_expression?(@plain <> "\n")
      refute DDL.valid_generated_as_expression?(@tsv <> "\n")
    end

    test "a leading / embedded newline is refused" do
      refute DDL.valid_generated_as_expression?("\n" <> @plain)
      refute DDL.valid_generated_as_expression?("field_values->'stem'\n->>'kk'")
    end

    test "both valid shapes are still accepted" do
      assert DDL.valid_generated_as_expression?(@plain)
      assert DDL.valid_generated_as_expression?(@tsv)
    end
  end

  # ---------------------------------------------------------------------------
  describe "GH #2635 ManagedTypes.managed_name?/1" do
    test "trailing newline refused" do
      refute ManagedTypes.managed_name?("invoice\n")
    end

    test "leading / embedded newline refused" do
      refute ManagedTypes.managed_name?("\ninvoice")
      refute ManagedTypes.managed_name?("inv\noice")
    end

    test "valid name accepted" do
      assert ManagedTypes.managed_name?("invoice")
    end
  end

  # ---------------------------------------------------------------------------
  describe "GH #2635 Tenant.settings_changeset/2 -- brand colour" do
    test "trailing newline refused" do
      refute color_cs("#000000\n").valid?
    end

    test "leading / embedded newline refused" do
      refute color_cs("\n#000000").valid?
      refute color_cs("#000\n000").valid?
    end

    test "valid colour accepted" do
      assert color_cs("#000000").valid?
    end
  end

  describe "GH #2635 Tenant.settings_changeset/2 -- locales and default_locale" do
    test "a locales entry with a trailing newline is refused" do
      refute settings_cs(%{"locales" => ["en\n"]}).valid?
    end

    test "a default_locale with a trailing newline is refused" do
      refute settings_cs(%{"default_locale" => "en\n"}).valid?
    end

    test "leading / embedded newline refused" do
      refute settings_cs(%{"locales" => ["\nen"]}).valid?
      refute settings_cs(%{"default_locale" => "e\nn"}).valid?
    end

    test "valid locales and default_locale accepted" do
      assert settings_cs(%{"locales" => ["en", "pt-BR"], "default_locale" => "en"}).valid?
    end
  end

  # ---------------------------------------------------------------------------
  describe "GH #2635 TenantMembership.email_shape?/1" do
    test "trailing newline refused" do
      refute TenantMembership.email_shape?("a@b.com\n")
    end

    test "leading / embedded newline refused" do
      refute TenantMembership.email_shape?("\na@b.com")
      refute TenantMembership.email_shape?("a@b\n.com")
    end

    test "valid email accepted" do
      assert TenantMembership.email_shape?("a@b.com")
    end
  end

  # ---------------------------------------------------------------------------
  describe "GH #2635 TenantProvisioning.tenant_id_for_schema_name/1" do
    # Guard, not main-discriminating: the later fixed-size binary pattern already
    # rejected a 33-byte hex part on main. Kept so the \z anchor is pinned here too.
    test "trailing newline refused" do
      assert {:error, :invalid_schema_name} =
               TenantProvisioning.tenant_id_for_schema_name("tenant_" <> @hex32 <> "\n")
    end

    test "leading / embedded newline refused" do
      assert {:error, :invalid_schema_name} =
               TenantProvisioning.tenant_id_for_schema_name("tenant_\n" <> @hex32)

      assert {:error, :invalid_schema_name} =
               TenantProvisioning.tenant_id_for_schema_name("tenant_" <> @hex32 <> "\nx")
    end

    test "valid schema name accepted" do
      assert {:ok, _} = TenantProvisioning.tenant_id_for_schema_name("tenant_" <> @hex32)
    end
  end

  describe "GH #2635 Registration.changeset/2 -- schema_name" do
    test "trailing newline refused" do
      assert field_errors(reg_cs("tenant_" <> @hex32 <> "\n"), :schema_name) != []
    end

    test "leading / embedded newline refused" do
      assert field_errors(reg_cs("\ntenant_" <> @hex32), :schema_name) != []
      assert field_errors(reg_cs("tenant_\n" <> @hex32), :schema_name) != []
    end

    test "valid schema name accepted" do
      assert field_errors(reg_cs("tenant_" <> @hex32), :schema_name) == []
    end
  end

  # ---------------------------------------------------------------------------
  describe "GH #2635 Solutions.load/1 -- solution id" do
    # Guard, not main-discriminating: on main "id\n" reached File.read/1 of a
    # nonexistent "id\n.json" and returned the same {:error, :not_found}.
    test "an id with a trailing newline is refused as :not_found" do
      assert {:error, :not_found} = Solutions.load("bilimbaga\n")
    end

    test "leading / embedded newline ids are refused" do
      assert {:error, :not_found} = Solutions.load("\nbilimbaga")
      assert {:error, :not_found} = Solutions.load("bili\nmbaga")
    end

    test "a valid shipped id is still accepted" do
      assert {:ok, %{id: "bilimbaga"}} = Solutions.load("bilimbaga")
    end
  end

  # ---------------------------------------------------------------------------
  describe "GH #2635 FixtureLoader.load_fixtures_only/3 -- sandbox schema name" do
    # Valid-name acceptance is covered by the existing REQ-039 tests in
    # fixture_loader_test.exs (they claim a real sandbox schema).
    test "trailing newline refused before any SQL" do
      assert {:error, :invalid_schema_name} =
               FixtureLoader.load_fixtures_only("sandbox_" <> @hex32 <> "\n", fixtures())
    end

    test "leading / embedded newline refused" do
      assert {:error, :invalid_schema_name} =
               FixtureLoader.load_fixtures_only("\nsandbox_" <> @hex32, fixtures())

      assert {:error, :invalid_schema_name} =
               FixtureLoader.load_fixtures_only("sandbox_\n" <> @hex32, fixtures())
    end
  end

  # ---------------------------------------------------------------------------
  # Valid-segment acceptance for put/2 (a real insert) is covered by REQ-190 in
  # secrets_test.exs.
  describe "GH #2635 Secrets.put/2 -- namespace and name segments" do
    test "a name with a trailing newline is refused" do
      assert {:error, :invalid_name} = Secrets.put(put_attrs(%{name: "key\n"}))
    end

    test "a namespace with a trailing newline is refused" do
      assert {:error, :invalid_namespace} = Secrets.put(put_attrs(%{namespace: "ns\n"}))
    end

    test "leading / embedded newline refused" do
      assert {:error, :invalid_name} = Secrets.put(put_attrs(%{name: "\nkey"}))
      assert {:error, :invalid_name} = Secrets.put(put_attrs(%{name: "ke\ny"}))
      assert {:error, :invalid_namespace} = Secrets.put(put_attrs(%{namespace: "n\ns"}))
    end
  end

  describe "GH #2635 Secrets.resolve/2 -- sec:// reference" do
    test "unpinned reference with a trailing newline is refused" do
      assert {:error, :invalid_reference} = resolve("sec://tenant/acme/ns/key\n")
    end

    test "pinned reference with a trailing newline is refused" do
      assert {:error, :invalid_reference} = resolve("sec://tenant/acme/ns/key#3\n")
    end

    test "leading / embedded newline refused" do
      assert {:error, :invalid_reference} = resolve("\nsec://tenant/acme/ns/key")
      assert {:error, :invalid_reference} = resolve("sec://tenant/acme/n\ns/key")
    end

    test "a well-formed reference passes the parser (fails later, on the unknown tenant)" do
      assert {:error, :tenant_mismatch} = resolve("sec://tenant/acme-gh2635-nope/ns/key")
      assert {:error, :tenant_mismatch} = resolve("sec://tenant/acme-gh2635-nope/ns/key#3")
    end
  end

  describe "GH #2635 Secret.insert_changeset/2 -- namespace and name format" do
    test "name with a trailing newline refused" do
      assert field_errors(secret_cs(%{name: "key\n"}), :name) != []
    end

    test "namespace with a trailing newline refused" do
      assert field_errors(secret_cs(%{namespace: "ns\n"}), :namespace) != []
    end

    test "leading / embedded newline refused" do
      assert field_errors(secret_cs(%{name: "\nkey"}), :name) != []
      assert field_errors(secret_cs(%{namespace: "n\ns"}), :namespace) != []
    end

    test "valid namespace and name accepted" do
      cs = secret_cs(%{name: "key", namespace: "ns"})
      assert field_errors(cs, :name) == []
      assert field_errors(cs, :namespace) == []
    end
  end
end
