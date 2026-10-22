defmodule Letflow.WebhooksRedactionTest do
  @moduledoc """
  REQ-516 S1 (GH #2701): `Letflow.Webhooks.deliver/3` masks entity-event `field_values`
  for the external recipient. Tests W1 (body + signature), W2 (DLQ row), the
  fail-closed case, P1 (recipient part of FieldPolicy) and the C7/C8 guard.
  Design: `lib/letflow/design/req516-record-history-field-policy.md` sections 5.1-5.3.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Dlq.Entry, as: DlqEntry
  alias Letflow.Entities.FieldPolicy
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Secrets
  alias Letflow.TenantProvisioning
  alias Letflow.Webhooks
  alias Letflow.Webhooks.Delivery
  alias Letflow.Webhooks.Subscription
  alias Letflow.WebhookTestServer

  @entity_type "req516_order"

  setup do
    Application.put_env(:letflow, :webhook_ssrf_validation_enabled, false)
    on_exit(fn -> Application.delete_env(:letflow, :webhook_ssrf_validation_enabled) end)
    :ok
  end

  defp tenant(slug) do
    Letflow.TenantFixture.provisioned_tenant!(
      slug_prefix: slug,
      display_name: "REQ-516 S1 Webhook Redaction Tenant"
    )
  end

  defp create_subscription!(schema_name, target_url) do
    {:ok, tenant_id} = TenantProvisioning.tenant_id_for_schema_name(schema_name)
    subscription_id = Ecto.UUID.generate()

    {:ok, secret} =
      Secrets.put(%{
        tenant_id: tenant_id,
        namespace: "webhook",
        name: subscription_id,
        purpose: :webhook_hmac,
        plaintext: "lf_whsec_" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)),
        created_by: "system:test_helper"
      })

    {:ok, subscription} =
      %Subscription{}
      |> Subscription.insert_changeset(%{
        id: subscription_id,
        tenant_id: tenant_id,
        target_url: target_url,
        secret_ref: secret.reference,
        secret_key_id: secret.key_id,
        description: nil,
        event_types: [],
        created_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert(prefix: schema_name)

    subscription
  end

  defp insert_restriction!(schema, entity_type, field_name) do
    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  defp delete_restrictions!(schema),
    do: Repo.delete_all("entity_field_restrictions", prefix: schema)

  defp event_payload do
    %{
      "entity_type" => @entity_type,
      "record_id" => Ecto.UUID.generate(),
      "field_values" => %{"secret" => "s3-top-secret", "title" => "visible"}
    }
  end

  defp event_type,
    do: "req516.test." <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

  describe "W1: delivered body and signature" do
    test "restricted value is masked in the body; signature covers the masked bytes" do
      %{schema_name: schema, tenant_id: tenant_id} = tenant("req516-w1")
      insert_restriction!(schema, @entity_type, "secret")
      server = WebhookTestServer.start(200, "ok")
      subscription = create_subscription!(schema, server.url)

      assert {:ok, %Delivery{status: :SUCCESS}} =
               Webhooks.deliver(subscription, event_type(), event_payload())

      assert_receive {:webhook_test_server_request, received}, 2_000
      refute received.body =~ "s3-top-secret"
      decoded = Jason.decode!(received.body)
      assert decoded["field_values"]["secret"] == "__field_redacted__"
      assert decoded["field_values"]["title"] == "visible"

      {:ok, %{plaintext: key}} =
        Secrets.resolve(subscription.secret_ref,
          tenant_id: tenant_id,
          consumer: :webhook_dispatcher
        )

      "sha256=" <> hex = Map.fetch!(received.headers, "x-letflow-signature")
      assert hex == Base.encode16(:crypto.mac(:hmac, :sha256, key, received.body), case: :lower)
    end

    test "value is present when no restriction row exists" do
      %{schema_name: schema} = tenant("req516-w1b")
      server = WebhookTestServer.start(200, "ok")
      subscription = create_subscription!(schema, server.url)

      assert {:ok, _} = Webhooks.deliver(subscription, event_type(), event_payload())

      assert_receive {:webhook_test_server_request, received}, 2_000
      assert Jason.decode!(received.body)["field_values"]["secret"] == "s3-top-secret"
    end

    test "restriction on another entity type does not mask; non-entity payload unchanged" do
      %{schema_name: schema} = tenant("req516-w1c")
      insert_restriction!(schema, "other_type", "secret")
      server = WebhookTestServer.start(200, "ok")
      subscription = create_subscription!(schema, server.url)

      assert {:ok, _} = Webhooks.deliver(subscription, event_type(), event_payload())
      assert_receive {:webhook_test_server_request, first}, 2_000
      assert Jason.decode!(first.body)["field_values"]["secret"] == "s3-top-secret"

      plain = %{"secret" => "x", "n" => 1}
      assert {:ok, _} = Webhooks.deliver(subscription, event_type(), plain)
      assert_receive {:webhook_test_server_request, second}, 2_000
      assert Jason.decode!(second.body) == plain
    end

    test "atom-keyed payload is masked too" do
      %{schema_name: schema} = tenant("req516-w1d")
      insert_restriction!(schema, @entity_type, "secret")
      server = WebhookTestServer.start(200, "ok")
      subscription = create_subscription!(schema, server.url)

      payload = %{entity_type: @entity_type, field_values: %{secret: "s3-top-secret"}}
      assert {:ok, _} = Webhooks.deliver(subscription, event_type(), payload)

      assert_receive {:webhook_test_server_request, received}, 2_000
      refute received.body =~ "s3-top-secret"
    end
  end

  describe "fail closed" do
    test "a payload that cannot be redacted sends no request and returns an error" do
      %{schema_name: schema} = tenant("req516-fc")
      server = WebhookTestServer.start(200, "ok")
      subscription = create_subscription!(schema, server.url)

      payload = %{"entity_type" => @entity_type, "field_values" => "s3-top-secret"}

      assert {:error, {:redaction_failed, _}} =
               Webhooks.deliver(subscription, event_type(), payload)

      refute_receive {:webhook_test_server_request, _}, 200
      assert Repo.all(Delivery, prefix: schema) == []
    end
  end

  describe "W2: DLQ row of an exhausted delivery" do
    test "source_payload holds the masked value, also after the restriction is removed" do
      %{schema_name: schema} = tenant("req516-w2")
      insert_restriction!(schema, @entity_type, "secret")
      server = WebhookTestServer.start(503, "down")
      subscription = create_subscription!(schema, server.url)

      assert {:ok, %Delivery{status: :FAILED} = delivery} =
               Webhooks.deliver(subscription, event_type(), event_payload())

      delete_restrictions!(schema)

      [entry] =
        DlqEntry
        |> where([e], e.reference_id == ^delivery.delivery_id)
        |> Repo.all(prefix: schema)

      refute inspect(entry.source_payload) =~ "s3-top-secret"
      assert entry.source_payload["field_values"]["secret"] == "__field_redacted__"
      assert entry.source_payload["field_values"]["title"] == "visible"
    end
  end

  describe "P1 (recipient part): FieldPolicy.restricted_anywhere/2, redact_for_recipient/3" do
    test "ignores grants and masks every restricted field" do
      %{schema_name: schema} = tenant("req516-p1")

      user =
        %Letflow.Identity.User{}
        |> Ecto.Changeset.change(%{
          username: "p1-#{Ecto.UUID.generate()}",
          display_name: "P1",
          email: "p1-#{Ecto.UUID.generate()}@example.com",
          password_hash: "__NO_PASSWORD_SET__",
          status: :active,
          auth_source: :internal
        })
        |> Repo.insert!(prefix: schema)

      insert_restriction!(schema, @entity_type, "secret")

      Repo.insert_all(
        "user_entity_grants",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            user_id: Ecto.UUID.dump!(user.id),
            entity_type: @entity_type,
            field_name: "secret",
            inserted_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: schema
      )

      assert {:ok, set} = FieldPolicy.restricted_anywhere(schema, @entity_type)
      assert MapSet.to_list(set) == ["secret"]
      assert {:ok, set} = FieldGrants.load_all_restricted(@entity_type, schema)
      assert MapSet.to_list(set) == ["secret"]

      assert {:ok, %{"secret" => :__field_redacted__, "title" => "t"}} =
               FieldPolicy.redact_for_recipient(schema, @entity_type, %{
                 "secret" => "v",
                 "title" => "t"
               })
    end

    test "loader error propagates, never unrestricted" do
      assert {:error, :invalid_schema_name} =
               FieldPolicy.restricted_anywhere("not_a_tenant_schema", @entity_type)

      assert {:error, :invalid_schema_name} =
               FieldPolicy.redact_for_recipient("not_a_tenant_schema", @entity_type, %{"a" => 1})
    end
  end

  describe "G1 (C7/C8): outbound service-task paths do not touch entity field_values" do
    test "service_task_dispatcher.ex and engine.ex do not reference field_values" do
      for path <- ["lib/letflow/engine/service_task_dispatcher.ex", "lib/letflow/engine.ex"] do
        source = File.read!(Path.join(File.cwd!(), path))

        refute source =~ "field_values",
               "#{path} now references field_values: route it through " <>
                 "FieldPolicy.redact_for_recipient/3 (REQ-516 design 5.3, C7/C8) and update this guard"
      end
    end
  end
end
