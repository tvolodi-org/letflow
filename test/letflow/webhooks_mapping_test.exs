defmodule Letflow.WebhooksMappingTest do
  @moduledoc """
  REQ-565 slice 2 (GH #3201): `Letflow.Webhooks.deliver/3` applies the linked outbound
  integration mapping between redaction and encoding. Test ids follow the T-0511 design:
  M1 (migration column), D1-D3 (criterion 5), D4 (criterion 6), D5-D8 (criterion 7), D9
  (criterion 8).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Letflow.Dlq.Entry, as: DlqEntry
  alias Letflow.IntegrationMappings
  alias Letflow.Secrets
  alias Letflow.TenantProvisioning
  alias Letflow.Webhooks
  alias Letflow.Webhooks.Delivery
  alias Letflow.Webhooks.Subscription
  alias Letflow.WebhookTestServer

  @entity_type "req565_order"
  @marker "PAYLOAD-MARKER-9f3a"

  setup do
    Application.put_env(:letflow, :webhook_ssrf_validation_enabled, false)
    on_exit(fn -> Application.delete_env(:letflow, :webhook_ssrf_validation_enabled) end)
    :ok
  end

  defp tenant(slug), do: Letflow.TenantFixture.provisioned_tenant!(slug_prefix: slug)

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

  defp create_mapping!(schema, rules, direction \\ "outbound") do
    {:ok, mapping} =
      IntegrationMappings.create(
        %{
          "name" => "m-" <> Ecto.UUID.generate(),
          "direction" => direction,
          "rules" => rules
        },
        nil,
        schema
      )

    mapping
  end

  defp link!(subscription, mapping_id, schema) do
    subscription
    |> Subscription.link_changeset(%{outbound_mapping_id: mapping_id})
    |> Repo.update!(prefix: schema)
  end

  defp payload,
    do: %{"order" => %{"id" => @marker, "total" => 5}, "note" => "dropped-" <> @marker}

  defp rules,
    do: [
      %{"to" => "id", "from" => "order.id", "required" => true},
      %{"to" => "kind", "const" => "order"}
    ]

  defp signing_key(subscription) do
    {:ok, %{plaintext: key}} =
      Secrets.resolve(subscription.secret_ref,
        tenant_id: subscription.tenant_id,
        consumer: :webhook_dispatcher
      )

    key
  end

  defp hmac(key, body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, key, body), case: :lower)

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

  defp reload(subscription, schema), do: Repo.get!(Subscription, subscription.id, prefix: schema)

  # criterion 7: nothing left the system, nothing was counted, nothing leaked
  defp assert_refused(subscription, schema, fun, expected) do
    log = capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    assert result == expected
    refute_receive {:webhook_test_server_request, _}, 200
    assert Repo.all(Delivery, prefix: schema) == []
    assert reload(subscription, schema).consecutive_failures == 0
    refute inspect(result) =~ @marker
    refute log =~ @marker
  end

  describe "M1: migration column (criterion 4)" do
    test "outbound_mapping_id exists, is a nullable uuid and reads nil on a fresh row" do
      %{schema_name: schema} = tenant("r565-m1")

      %{rows: [[type, nullable]]} =
        Repo.query!(
          "SELECT data_type, is_nullable FROM information_schema.columns " <>
            "WHERE table_schema = $1 AND table_name = 'webhook_subscriptions' " <>
            "AND column_name = 'outbound_mapping_id'",
          [schema]
        )

      assert {type, nullable} == {"uuid", "YES"}

      subscription = create_subscription!(schema, "https://example.com/hook")
      assert reload(subscription, schema).outbound_mapping_id == nil

      assert Enum.any?(
               TenantProvisioning.tenant_scoped_migrations(),
               &match?({20_261_025_600_001, _module}, &1)
             )
    end
  end

  describe "D1: mapped body and signature (criterion 5)" do
    test "the body is the mapped map and the signature covers exactly its bytes" do
      %{schema_name: schema} = tenant("r565-d1")
      server = WebhookTestServer.start(200, "ok")
      subscription = create_subscription!(schema, server.url)
      mapping = create_mapping!(schema, rules())
      subscription = link!(subscription, mapping.id, schema)

      assert {:ok, %Delivery{status: :SUCCESS}} =
               Webhooks.deliver(subscription, "r565.d1", payload())

      assert_receive {:webhook_test_server_request, received}, 2_000
      assert Jason.decode!(received.body) == %{"id" => @marker, "kind" => "order"}
      refute received.body =~ "dropped-"

      "sha256=" <> hex = Map.fetch!(received.headers, "x-letflow-signature")
      assert "sha256=" <> hex == hmac(signing_key(subscription), received.body)
    end
  end

  describe "D2: DLQ copy (criterion 5)" do
    test "the DLQ source_payload is the mapped body" do
      %{schema_name: schema} = tenant("r565-d2")
      server = WebhookTestServer.start(500, "boom")
      subscription = create_subscription!(schema, server.url)
      mapping = create_mapping!(schema, rules())
      subscription = link!(subscription, mapping.id, schema)

      assert {:ok, %Delivery{status: :FAILED}} =
               Webhooks.deliver(subscription, "r565.d2", payload())

      [entry] = Repo.all(from(e in DlqEntry, where: e.entry_type == "webhook"), prefix: schema)
      assert entry.source_payload == %{"id" => @marker, "kind" => "order"}
    end
  end

  describe "D3: redaction runs first (criterion 5)" do
    test "a rule copying a masked field sends the masked value, never the original" do
      %{schema_name: schema} = tenant("r565-d3")
      insert_restriction!(schema, @entity_type, "secret")
      server = WebhookTestServer.start(200, "ok")
      subscription = create_subscription!(schema, server.url)

      mapping =
        create_mapping!(schema, [%{"to" => "out", "from" => "field_values.secret"}])

      subscription = link!(subscription, mapping.id, schema)

      entity_payload = %{
        "entity_type" => @entity_type,
        "record_id" => Ecto.UUID.generate(),
        "field_values" => %{"secret" => "s3-top-secret", "title" => "visible"}
      }

      assert {:ok, _} = Webhooks.deliver(subscription, "r565.d3", entity_payload)

      assert_receive {:webhook_test_server_request, received}, 2_000
      refute received.body =~ "s3-top-secret"
      assert Jason.decode!(received.body) == %{"out" => "__field_redacted__"}
    end
  end

  describe "D4: null link (criterion 6)" do
    test "body and signature are the unmapped payload's bytes" do
      %{schema_name: schema} = tenant("r565-d4")
      server = WebhookTestServer.start(200, "ok")
      subscription = create_subscription!(schema, server.url)
      assert subscription.outbound_mapping_id == nil

      assert {:ok, _} = Webhooks.deliver(subscription, "r565.d4", payload())

      assert_receive {:webhook_test_server_request, received}, 2_000
      assert received.body == Jason.encode!(payload())

      assert Map.fetch!(received.headers, "x-letflow-signature") ==
               hmac(signing_key(subscription), Jason.encode!(payload()))
    end
  end

  describe "D5-D8: mapping failures (criterion 7)" do
    test "D5 a missing required source" do
      %{schema_name: schema} = tenant("r565-d5")
      server = WebhookTestServer.start(200, "ok")
      subscription = create_subscription!(schema, server.url)

      mapping =
        create_mapping!(schema, [
          %{"to" => "a", "from" => "order.id"},
          %{"to" => "b", "from" => "order.absent", "required" => true}
        ])

      subscription = link!(subscription, mapping.id, schema)

      assert_refused(
        subscription,
        schema,
        fn -> Webhooks.deliver(subscription, "r565.d5", payload()) end,
        {:error, {:mapping_failed, {:required_missing, 1}}}
      )
    end

    test "D6 a mapped body over 256 KB" do
      %{schema_name: schema} = tenant("r565-d6")
      server = WebhookTestServer.start(200, "ok")
      subscription = create_subscription!(schema, server.url)

      mapping =
        create_mapping!(schema, [%{"to" => "big", "const" => String.duplicate("x", 270_000)}])

      subscription = link!(subscription, mapping.id, schema)

      assert_refused(
        subscription,
        schema,
        fn -> Webhooks.deliver(subscription, "r565.d6", payload()) end,
        {:error, {:mapping_failed, :body_too_large}}
      )
    end

    test "D7 a linked mapping that no longer exists" do
      %{schema_name: schema} = tenant("r565-d7")
      server = WebhookTestServer.start(200, "ok")
      subscription = create_subscription!(schema, server.url)
      subscription = link!(subscription, Ecto.UUID.generate(), schema)

      assert_refused(
        subscription,
        schema,
        fn -> Webhooks.deliver(subscription, "r565.d7", payload()) end,
        {:error, {:mapping_failed, :mapping_not_found}}
      )
    end

    test "D8 a linked mapping later turned inbound fails closed" do
      %{schema_name: schema} = tenant("r565-d8")
      server = WebhookTestServer.start(200, "ok")
      subscription = create_subscription!(schema, server.url)
      mapping = create_mapping!(schema, rules())
      subscription = link!(subscription, mapping.id, schema)

      {:ok, _} =
        IntegrationMappings.update(
          mapping.id,
          %{"name" => mapping.name, "direction" => "inbound", "rules" => rules()},
          nil,
          schema
        )

      assert_refused(
        subscription,
        schema,
        fn -> Webhooks.deliver(subscription, "r565.d8", payload()) end,
        {:error, {:mapping_failed, :mapping_not_found}}
      )
    end
  end

  describe "D9: the target URL stays with the subscription (criterion 8)" do
    test "rules writing to url, target_url and host only change body keys" do
      %{schema_name: schema} = tenant("r565-d9a")
      server = WebhookTestServer.start(200, "ok")
      subscription = create_subscription!(schema, server.url)

      mapping =
        create_mapping!(schema, [
          %{"to" => "url", "const" => "http://127.0.0.1:1/evil"},
          %{"to" => "target_url", "const" => "http://169.254.169.254/"},
          %{"to" => "host", "const" => "evil.example"}
        ])

      subscription = link!(subscription, mapping.id, schema)

      assert {:ok, %Delivery{status: :SUCCESS}} =
               Webhooks.deliver(subscription, "r565.d9", payload())

      assert_receive {:webhook_test_server_request, received}, 2_000

      assert Jason.decode!(received.body) == %{
               "url" => "http://127.0.0.1:1/evil",
               "target_url" => "http://169.254.169.254/",
               "host" => "evil.example"
             }
    end

    test "with SSRF validation on, a private target_url is still refused by UrlValidator" do
      %{schema_name: schema} = tenant("r565-d9b")
      subscription = create_subscription!(schema, "http://127.0.0.1:9/hook")
      mapping = create_mapping!(schema, [%{"to" => "url", "const" => "https://example.com/ok"}])
      subscription = link!(subscription, mapping.id, schema)
      Application.put_env(:letflow, :webhook_ssrf_validation_enabled, true)

      assert {:ok, %Delivery{status: :FAILED, last_error: error}} =
               Webhooks.deliver(subscription, "r565.d9b", payload())

      assert error =~ "target_url not allowed"
    end
  end
end
