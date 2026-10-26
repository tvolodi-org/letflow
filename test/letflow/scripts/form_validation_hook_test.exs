defmodule Letflow.Scripts.FormValidationHookTest do
  @moduledoc """
  REQ-569 / GH #3246 AC1, AC2 (decision 0067 D9, slice F-1): the `form_validation` hook kind of
  `Letflow.Scripts` and its `:form_validation_hook_enabled` flag (default off). `async: false`
  (tenant provisioning, application env).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Scripts
  alias Letflow.Support.ScriptTaskFixture, as: F
  alias Letflow.TenantFixture

  # The first sandbox call in a fresh VM is slow; warm it so the publish test case of S2 does not
  # time out on a cold runner.
  setup_all do
    opts = [
      tenant: "tenant_warmup",
      timeout_ms: 5_000,
      ctx: %{instance_id: "i", node_id: "n", token_id: "t", now: ~U[2026-01-01 00:00:00Z]}
    ]

    {:ok, _} = Letflow.Engine.Lua.ScriptRunner.run("return { ok = true }", %{}, opts)
    :ok
  end

  defp actor, do: %{user_id: Ecto.UUID.generate(), credential: :oidc, trace_id: "req569-trace"}

  defp body("form_validation" = kind) do
    manifest = %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"amount" => %{"type" => "integer"}}
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{
          "ok" => %{"type" => "boolean"},
          "code" => %{"type" => "string"},
          "fields" => %{"type" => "array"}
        },
        "additionalProperties" => false
      },
      "fail_codes" => [],
      "refusal_codes" => ["too_small"],
      "fields" => ["amount"]
    }

    %{
      "hook_kind" => kind,
      "source" => "return { ok = true }",
      "manifest" => manifest,
      "test_cases" => [
        %{"name" => "c1", "input" => %{"amount" => 2}, "expect" => %{"output" => %{"ok" => true}}}
      ]
    }
  end

  defp body(kind) do
    %{
      "hook_kind" => kind,
      "source" => F.doubling_source(),
      "manifest" => F.closed_manifest(),
      "test_cases" => [
        %{
          "name" => "c1",
          "input" => %{"amount" => 2},
          "expect" => %{"output" => %{"total" => 4}}
        }
      ]
    }
  end

  defp set_flag(value) do
    previous = Application.fetch_env(:letflow, :form_validation_hook_enabled)
    Application.put_env(:letflow, :form_validation_hook_enabled, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :form_validation_hook_enabled, old)
        :error -> Application.delete_env(:letflow, :form_validation_hook_enabled)
      end
    end)
  end

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r569")
    :ok = Letflow.Scripts.HmacSecret.ensure(%{id: tenant.tenant_id})

    on_exit(fn ->
      Repo.delete_all(from(s in Letflow.Secrets.Secret, where: s.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, schema: tenant.schema_name}
  end

  describe "flag on" do
    setup do
      set_flag(true)
    end

    test "S1 a form_validation version is created and stored with its kind", %{schema: schema} do
      assert Scripts.form_validation_enabled?()

      assert {:ok, draft} =
               Scripts.create_draft(schema, "fv_key", body("form_validation"), actor())

      assert draft.hook_kind == "form_validation"
      assert {:ok, %{hook_kind: "form_validation"}} = Scripts.get(schema, "fv_key", draft.version)
    end

    test "S2 it publishes", %{schema: schema} do
      {:ok, draft} = Scripts.create_draft(schema, "fv_pub", body("form_validation"), actor())

      assert {:ok, published} =
               Scripts.publish(schema, "fv_pub", draft.version, draft.sha256, actor(), false)

      assert published.status == :published
      assert published.hook_kind == "form_validation"
    end

    test "M15 the F-2 manifest keys are stored; a service_task with them is refused",
         %{schema: schema} do
      assert {:ok, draft} =
               Scripts.create_draft(schema, "fv_keys", body("form_validation"), actor())

      assert {:ok, stored} = Scripts.get(schema, "fv_keys", draft.version)
      assert stored.manifest["refusal_codes"] == ["too_small"]
      assert stored.manifest["fields"] == ["amount"]

      mixed = put_in(body("service_task"), ["manifest", "fields"], ["amount"])

      assert Scripts.create_draft(schema, "svc_fields", mixed, actor()) ==
               {:error, :invalid_manifest}

      no_keys = put_in(body("form_validation"), ["manifest"], F.closed_manifest())

      assert Scripts.create_draft(schema, "fv_no_keys", no_keys, actor()) ==
               {:error, :invalid_manifest}
    end

    test "S3 any other kind is still invalid_hook_kind", %{schema: schema} do
      for kind <- ["bogus", "http", "FORM_VALIDATION", "", nil] do
        assert Scripts.create_draft(schema, "fv_bad", body(kind), actor()) ==
                 {:error, :invalid_hook_kind}
      end
    end
  end

  describe "flag default and off" do
    test "S4 the default is false in config and in the reader" do
      config = Config.Reader.read!("config/config.exs", env: :test)
      assert config[:letflow][:form_validation_hook_enabled] == false
      refute Scripts.form_validation_enabled?()
    end

    test "S5 off: creating a form_validation version is invalid_hook_kind; service_task works",
         %{schema: schema} do
      set_flag(false)

      assert Scripts.create_draft(schema, "fv_off", body("form_validation"), actor()) ==
               {:error, :invalid_hook_kind}

      assert {:ok, %{hook_kind: "service_task"}} =
               Scripts.create_draft(schema, "svc_off", body("service_task"), actor())
    end

    test "S5b a non-true value is off", %{schema: schema} do
      set_flag("true")
      refute Scripts.form_validation_enabled?()

      assert Scripts.create_draft(schema, "fv_str", body("form_validation"), actor()) ==
               {:error, :invalid_hook_kind}
    end

    test "S6 a body without hook_kind is still invalid_hook_kind", %{schema: schema} do
      assert Scripts.create_draft(schema, "fv_none", Map.delete(body("x"), "hook_kind"), actor()) ==
               {:error, :invalid_hook_kind}
    end
  end
end
