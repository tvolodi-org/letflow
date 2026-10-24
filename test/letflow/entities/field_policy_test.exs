defmodule Letflow.Entities.FieldPolicyTest do
  @moduledoc """
  REQ-516 S2 (GH #2701): `FieldPolicy.redact_event_payload/3` and `redact_event_payload_with_sets/3`
  mask the `field_values` of a record event payload for the caller, by the same rule as every other
  response (P1). A payload without `field_values` (ENTITY_RECORD_DELETED) is returned unchanged.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.FieldPolicy
  alias Letflow.Identity.User
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    t = F.tenant!("req516-field-policy")

    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: "case_file",
          field_name: "secret",
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: t.schema_name
    )

    %{t: t, no_grant: user!(t), granted: granted_user!(t)}
  end

  defp user!(t) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req516-fp-#{Ecto.UUID.generate()}",
      display_name: "REQ-516 Field Policy Test User",
      email: "req516-fp-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: t.schema_name)
  end

  defp granted_user!(t) do
    user = user!(t)

    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user.id),
          entity_type: "case_file",
          field_name: "secret",
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: t.schema_name
    )

    user
  end

  defp principal(t, user), do: %{user_id: user.id, prefix: t.schema_name}

  defp created_payload do
    %{
      "entity_type" => "case_file",
      "entity_def_version" => "00ff",
      "record_id" => Ecto.UUID.generate(),
      "field_values" => %{"title" => "case", "secret" => "s3"}
    }
  end

  describe "redact_event_payload/3" do
    test "masks the restricted field for a caller with no grant and leaves the rest", %{
      t: t,
      no_grant: user
    } do
      payload = created_payload()

      assert {:ok, redacted} =
               FieldPolicy.redact_event_payload(principal(t, user), "case_file", payload)

      assert redacted["field_values"] == %{"title" => "case", "secret" => :__field_redacted__}
      assert Map.delete(redacted, "field_values") == Map.delete(payload, "field_values")
    end

    test "keeps the value for a caller holding the grant", %{t: t, granted: user} do
      payload = created_payload()

      assert {:ok, redacted} =
               FieldPolicy.redact_event_payload(principal(t, user), "case_file", payload)

      assert redacted == payload
    end

    test "a payload without field_values is returned unchanged and loads no set", %{
      no_grant: user
    } do
      deleted = %{
        "entity_type" => "case_file",
        "entity_def_version" => "00ff",
        "record_id" => Ecto.UUID.generate()
      }

      # The prefix is not a tenant: a loader call would fail, so an unchanged {:ok, _} shows that
      # no set was loaded.
      assert {:ok, ^deleted} =
               FieldPolicy.redact_event_payload(
                 %{user_id: user.id, prefix: "not_a_tenant"},
                 "case_file",
                 deleted
               )
    end

    test "a loader error propagates, never an unredacted payload", %{no_grant: user} do
      assert {:error, :invalid_schema_name} =
               FieldPolicy.redact_event_payload(
                 %{user_id: user.id, prefix: "not_a_tenant"},
                 "case_file",
                 created_payload()
               )
    end
  end

  describe "redact_event_payload_with_sets/3" do
    test "gives the same result as redact_event_payload/3 for the same loaded set", %{
      t: t,
      no_grant: user
    } do
      payload = created_payload()
      {:ok, sets} = FieldPolicy.load_sets(principal(t, user), ["case_file"])

      assert {:ok, via_loader} =
               FieldPolicy.redact_event_payload(principal(t, user), "case_file", payload)

      assert FieldPolicy.redact_event_payload_with_sets(sets, "case_file", payload) == via_loader
    end

    test "returns a deleted-record payload unchanged", %{t: t, no_grant: user} do
      deleted = %{"entity_type" => "case_file", "record_id" => Ecto.UUID.generate()}
      {:ok, sets} = FieldPolicy.load_sets(principal(t, user), ["case_file"])

      assert FieldPolicy.redact_event_payload_with_sets(sets, "case_file", deleted) == deleted
    end
  end
end
