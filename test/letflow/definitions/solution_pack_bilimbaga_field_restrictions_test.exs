defmodule Letflow.Definitions.SolutionPackBilimbagaFieldRestrictionsTest do
  @moduledoc """
  ISS-0647 rework (updated for REQ-411) -- proves that the answer-key
  `entity_field_restrictions` rows are seeded correctly via the REAL module-
  install path.

  REQ-411 moved the seeding logic from the deleted `Letflow.Packs.Bilimbaga`
  module (and from `SolutionPack.install/3`'s now-deleted
  `seed_pack_specific_field_restrictions/2` hook) into
  `Letflow.Modules.Exam.on_install/2`, called inside the
  `Letflow.Modules.Installs.install/3` transaction (D5).

  This test proves the gap is closed by exercising the real module-install
  path end-to-end, with NO test-only seeding call anywhere in it:

    1. A real `Letflow.Modules.Installs.install("exam", ...)` of the real
       registered exam module -- `on_install/2` is NEVER called directly here.
       If `install/3`'s transaction does not call `on_install/2`, or if
       `on_install/2`'s seeding logic is missing or broken, this test fails
       the same way `entities_answer_key_field_leak_test.exs`'s Part 1
       (fact-finding) tests failed before ISS-0647's first fix.
    2. Real activation of the FK chain the answer-key data sits on.
    3. Real records written through `Letflow.Entities.Records.create_record/2`.
    4. A real, unmocked `POST /entities/query` dispatched through the full
       `Letflow.Router`/`Letflow.Plugs.ApiPipeline` stack, with a real API
       token scoped to `TASK_WORKER` only.

  Mirrors `test/letflow/modules/exam/pack_install_test.exs`'s real-install
  fixture pattern and
  `test/letflow/routers/entities_answer_key_field_leak_test.exs`'s real-HTTP
  dispatch pattern, combined.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Test
  import Plug.Conn

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp query(ctx, body), do: request(:post, "/api/v1/entities/query", ctx, body)
  defp body_of(conn), do: Jason.decode!(conn.resp_body)
  defp wire_sentinel, do: Atom.to_string(FieldGrants.redacted_sentinel())

  defp insert_user!(schema_name) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "iss0647-e2e-#{Ecto.UUID.generate()}",
      display_name: "ISS-0647 E2E Test User",
      email: "iss0647-e2e-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp tenant_ctx do
    fixture =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "iss0647-e2e-modinst",
        display_name: "ISS-0647 Module-Install Test Tenant"
      )

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^fixture.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^fixture.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^fixture.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(fixture.schema_name)
    user = insert_user!(fixture.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: nil},
        prefix: fixture.schema_name
      )

    %{
      tenant_id: fixture.tenant_id,
      schema_name: fixture.schema_name,
      slug: fixture.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp create_record!(schema, entity_type, field_values, actor_id) do
    assert {:ok, %{record: record}} =
             Records.create_record(
               %{
                 entity_type: entity_type,
                 field_values: field_values,
                 actor_id: actor_id,
                 idempotency_key: Ecto.UUID.generate()
               },
               schema
             )

    record
  end

  describe "the REAL module-install path (no test-only seeding call anywhere)" do
    test "Installs.install/3 + activate + write, then TASK_WORKER POST /entities/query redacts the answer-key fields" do
      ctx = tenant_ctx()
      actor_id = ctx.user_id

      # ---- 1. THE REAL MODULE INSTALL ------------------------------------
      # `Letflow.Modules.Exam.on_install/2` is NOT called anywhere in this
      # test file. If it happens at all, it happens because
      # `Installs.install/3`'s own transaction calls it (D5).
      assert {:ok, tenant_module} =
               Installs.install("exam", actor_id,
                 prefix: ctx.schema_name,
                 rationale: "test: module install"
               )

      assert tenant_module.module_id == "exam"

      # ---- 2. ACTIVATE just the FK chain the answer-key data sits on ----
      for entity_type <- ~w(category question answer_option) do
        assert {:ok, %EntityDefinition{status: :active}} =
                 Definitions.activate_definition(
                   entity_type,
                   actor_id,
                   "iss0647 e2e go-live",
                   ctx.schema_name
                 )
      end

      # ---- 3. REAL RECORDS, through the real record-write path ----------
      category =
        create_record!(
          ctx.schema_name,
          "category",
          %{
            "name" => %{"kk" => "a", "ru" => "a", "en" => "a"},
            "sort_order" => 1
          },
          actor_id
        )

      question =
        create_record!(
          ctx.schema_name,
          "question",
          %{
            "category_id" => category.record_id,
            "difficulty" => "easy",
            "type" => "single",
            "default_locale" => "kk",
            "status" => "draft",
            "version" => 1,
            "stem" => %{"kk" => "2 + 2 = ?", "ru" => "2 + 2 = ?", "en" => "2 + 2 = ?"},
            "explanation" => %{
              "kk" => "Basic addition.",
              "ru" => "Basic addition.",
              "en" => "Basic addition."
            }
          },
          actor_id
        )

      create_record!(
        ctx.schema_name,
        "answer_option",
        %{
          "question_id" => question.record_id,
          "sort_order" => 1,
          "is_correct" => true,
          "likert_weight" => 3.5,
          "likert_polarity" => "positive",
          "text" => %{"kk" => "4", "ru" => "4", "en" => "4"}
        },
        actor_id
      )

      # ---- 4. THE PROOF -- a real, unmocked HTTP request, TASK_WORKER-only.
      answer_conn = query(ctx, %{"entity_type" => "answer_option"})
      assert answer_conn.status == 200
      assert [answer_item] = body_of(answer_conn)["items"]
      answer_fields = answer_item["field_values"]

      # THE ANSWER-KEY FIELDS ARE REDACTED -- seeded by on_install/2.
      assert answer_fields["is_correct"] == wire_sentinel()
      assert answer_fields["likert_weight"] == wire_sentinel()
      assert answer_fields["likert_polarity"] == wire_sentinel()

      # NOT over-redacted -- unrestricted fields on the same row stay real.
      assert answer_fields["question_id"] == question.record_id
      assert answer_fields["text"]["en"] == "4"

      question_conn = query(ctx, %{"entity_type" => "question"})
      assert question_conn.status == 200
      assert [question_item] = body_of(question_conn)["items"]
      question_fields = question_item["field_values"]

      assert question_fields["explanation"] == wire_sentinel()
      assert question_fields["stem"]["en"] == "2 + 2 = ?"
    end
  end
end
