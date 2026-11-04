defmodule Letflow.Definitions.LedgerConsentActivatedByTest do
  @moduledoc """
  REQ-688 criteria 2 and 2a (decision 0073 D-L12): the signed `activated_by` document of a graph
  with a consented SERVICE_TASK posting node carries `ledger_consent_nodes` and the activating
  `credential`; every other document is unchanged; a tampered list fails the signature check.

  `async: false`: the per-tenant `activated-by-hmac` key lives in the shared `secrets` table.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Context
  alias Letflow.Definitions.ActivatedBy
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.LedgerPostFixture, as: PFx
  alias Letflow.Repo

  defp posting_line, do: PFx.post_line("post_alpha", PFx.posting("receipt", "a", "5"))

  defp stored(ctx), do: Repo.get!(ProcessDefinition, ctx.definition.id, prefix: ctx.schema)

  describe "criterion 2 (the signed document)" do
    test "A-1 a consented service posting node is recorded, sorted, with the credential" do
      ctx = PFx.service_case!("req688-a1", [posting_line()])
      doc = stored(ctx).activated_by

      assert doc["ledger_consent_nodes"] == ["svc"]
      assert doc["credential"] == "oidc"
      assert {:ok, :verified} = ActivatedBy.verify(doc, stored(ctx), ctx.schema)
    end

    test "A-1b an api_token activation records the api_token credential" do
      ctx = PFx.service_case!("req688-a1b", [posting_line()], credential: :api_token)
      assert stored(ctx).activated_by["credential"] == "api_token"
    end

    test "A-2 a HUMAN posting graph's document has neither key" do
      ctx = PFx.case!("req688-a2", [posting_line()])
      doc = stored(ctx).activated_by

      refute Map.has_key?(doc, "ledger_consent_nodes")
      refute Map.has_key?(doc, "credential")

      assert Enum.sort(Map.keys(doc)) ==
               ~w(activated_at authorized module_handlers permissions roles signature user_id)
    end

    test "A-3 a tampered ledger_consent_nodes fails verification" do
      ctx = PFx.service_case!("req688-a3", [posting_line()])
      row = stored(ctx)

      for tampered <- [["svc", "other"], [], ["other"]] do
        doc = Map.put(row.activated_by, "ledger_consent_nodes", tampered)
        assert {:error, :mismatch} = ActivatedBy.verify(doc, row, ctx.schema)
      end

      doc = Map.put(row.activated_by, "credential", "oidc2")
      assert {:error, :mismatch} = ActivatedBy.verify(doc, row, ctx.schema)

      doc = Map.delete(row.activated_by, "credential")
      assert {:error, :mismatch} = ActivatedBy.verify(doc, row, ctx.schema)
    end
  end

  describe "criterion 2a (the credential of the activating request)" do
    @user_id "00000000-0000-0000-0000-0000000000a1"

    test "C-1 the credential kind of the auth_context becomes the activator's" do
      for {kind, expected} <- [oidc: "oidc", api_token: "api_token", other: "none"] do
        activator =
          Activator.from_auth_context(
            %{user_id: @user_id, roles: ["TENANT_ADMIN"], credential: kind},
            false
          )

        assert activator.credential == expected
      end
    end

    test "C-2 the route helper hands the conn's auth_context credential to the activator" do
      for {kind, expected} <- [oidc: "oidc", api_token: "api_token"] do
        conn =
          Plug.Test.conn(:post, "/")
          |> Plug.Conn.assign(:auth_context, %{
            user_id: @user_id,
            tenant_id: Ecto.UUID.generate(),
            roles: ["TENANT_ADMIN"],
            credential: kind
          })

        assert Context.activator(conn).credential == expected
      end
    end

    test "C-3 a context with no credential key is none" do
      activator = Activator.from_auth_context(%{user_id: @user_id, roles: []}, false)
      assert activator.credential == "none"
    end
  end
end
