defmodule Letflow.Routers.ScriptRulesTest do
  @moduledoc """
  GH 2534 PR 7b-1 (decision 0053 D1, D6, D9, D10), design
  `lib/letflow/design/gh2534-7b1-script-registry.md` section 10: the tenant-script registry.

    * AC8: published versions immutable at DB level; publisher in the contributor set refused
      (also via an earlier DISCARDED draft); stale sha256 refused; failing stored test blocks
      publish; cross-tenant key = the exact missing-key 404 (INV-5); source absent from lists.
    * Token rule (advisor + SECURITY-REVIEWER B1): every write via an API token is refused,
      including a token minted for a non-contributor; reads and dry-run are allowed.
    * Q3: a non-empty `reads` is refused. Permissions per D6. Dry-run (D10). Concurrency.

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @admin ["TENANT_ADMIN"]
  @designer ["PROCESS_DESIGNER"]

  @manifest %{
    "input_schema" => %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}},
    "output_schema" => %{"type" => "object", "properties" => %{"y" => %{"type" => "integer"}}},
    "fail_codes" => ["too_big"]
  }
  @source "if ctx.input.x > 10 then fail('too_big') end return {y = ctx.input.x * 2}"
  @test_cases [
    %{"name" => "doubles", "input" => %{"x" => 2}, "expect" => %{"output" => %{"y" => 4}}},
    %{"name" => "refuses", "input" => %{"x" => 11}, "expect" => %{"fail" => "too_big"}}
  ]

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp call(method, path, fixture, roles, body, opts \\ []) do
    credential = Keyword.get(opts, :credential, :oidc)
    user_id = Keyword.get(opts, :user_id, Ecto.UUID.generate())

    conn =
      Fixture.router_conn(method, path, fixture, roles, body)
      |> Plug.Conn.assign(:auth_context, %{
        user_id: user_id,
        tenant_id: fixture.tenant_id,
        roles: roles,
        credential: credential
      })

    Letflow.Routers.ScriptRules.call(conn, Letflow.Routers.ScriptRules.init([]))
  end

  defp body(overrides \\ %{}) do
    Map.merge(
      %{
        "hook_kind" => "service_task",
        "source" => @source,
        "manifest" => @manifest,
        "test_cases" => @test_cases
      },
      overrides
    )
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp detail(conn), do: json(conn)["detail"]

  defp key, do: "rule_#{System.unique_integer([:positive])}"

  defp create!(fixture, key, user_id) do
    conn = call(:post, "/#{key}/versions", fixture, @designer, body(), user_id: user_id)
    assert conn.status == 201, conn.resp_body
    json(conn)
  end

  defp publish(fixture, key, version, sha, user_id, opts \\ []) do
    call(
      :post,
      "/#{key}/versions/#{version}/publish",
      fixture,
      @admin,
      %{"sha256" => sha},
      Keyword.put(opts, :user_id, user_id)
    )
  end

  defp row(fixture, key, version),
    do: Repo.get_by!(ScriptRule, [key: key, version: version], prefix: fixture.schema_name)

  defp audit_actions(fixture, key, version) do
    rule_id = row(fixture, key, version).id

    Entry
    |> where([e], e.resource_type == "script_rule" and e.resource_id == ^rule_id)
    |> order_by([e], asc: e.timestamp)
    |> select([e], e.action)
    |> Repo.all(prefix: fixture.schema_name)
  end

  # ── drafts ─────────────────────────────────────────────────────────────────

  describe "drafts" do
    test "a designer creates version 1, then version 2; contributors and sha256 are recorded; audited",
         ctx do
      k = key()
      author = Ecto.UUID.generate()
      v1 = create!(ctx.a, k, author)

      assert v1["version"] == 1
      assert v1["status"] == "draft"
      assert v1["contributors"] == [author]
      assert v1["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert create!(ctx.a, k, author)["version"] == 2
      assert audit_actions(ctx.a, k, 1) == ["script_rule.draft_created"]
    end

    test "saving a draft adds the saver to the contributor set and changes the sha256", ctx do
      k = key()
      author = Ecto.UUID.generate()
      second = Ecto.UUID.generate()
      v1 = create!(ctx.a, k, author)

      conn =
        call(:put, "/#{k}/versions/1", ctx.a, @designer, body(%{"source" => @source <> " "}),
          user_id: second
        )

      assert conn.status == 200, conn.resp_body
      assert Enum.sort(json(conn)["contributors"]) == Enum.sort([author, second])
      assert json(conn)["sha256"] != v1["sha256"]
    end

    test "two concurrent saves keep both contributors", ctx do
      k = key()
      create!(ctx.a, k, Ecto.UUID.generate())
      users = for _ <- 1..2, do: Ecto.UUID.generate()

      users
      |> Enum.map(fn user ->
        Task.async(fn ->
          call(:put, "/#{k}/versions/1", ctx.a, @designer, body(), user_id: user)
        end)
      end)
      |> Enum.each(&assert(Task.await(&1, 15_000).status == 200))

      assert Enum.all?(users, &(&1 in row(ctx.a, k, 1).contributors))
    end

    test "discard keeps the row (no hard delete); version numbers are never reused", ctx do
      k = key()
      create!(ctx.a, k, Ecto.UUID.generate())

      assert call(:delete, "/#{k}/versions/1", ctx.a, @designer, nil).status == 204
      assert row(ctx.a, k, 1).status == "discarded"
      assert call(:get, "/#{k}/versions/1", ctx.a, @designer, nil).status == 404
      assert create!(ctx.a, k, Ecto.UUID.generate())["version"] == 2
    end

    test "manifest rules: unknown key, capabilities, non-empty reads (Q3), oversize limits, malformed schema",
         ctx do
      k = key()

      for {manifest, code} <- [
            {Map.put(@manifest, "extra", 1), "invalid_manifest"},
            {Map.put(@manifest, "capabilities", ["read_variable"]), "invalid_manifest"},
            {Map.put(@manifest, "reads", [%{"entity_type" => "customer"}]), "reads_not_allowed"},
            {Map.put(@manifest, "limits", %{"timeout_ms" => 60_000}), "invalid_manifest"},
            {Map.put(@manifest, "input_schema", %{"type" => "object", "$ref" => "#/x"}),
             "invalid_manifest"},
            {Map.delete(@manifest, "fail_codes"), "invalid_manifest"}
          ] do
        conn = call(:post, "/#{k}/versions", ctx.a, @designer, body(%{"manifest" => manifest}))
        assert conn.status == 422, inspect(manifest)
        assert detail(conn) == code
      end

      conn = call(:post, "/#{k}/versions", ctx.a, @designer, body(%{"test_cases" => []}))
      assert conn.status == 422
      assert detail(conn) == "invalid_test_case"
    end
  end

  # ── token rule (6.1) ───────────────────────────────────────────────────────

  describe "API-token callers" do
    test "every write is refused (create, save, discard, publish, retire, revoke); reads and dry-run are allowed",
         ctx do
      k = key()
      v1 = create!(ctx.a, k, Ecto.UUID.generate())
      token = [credential: :api_token]

      assert detail(call(:post, "/#{k}/versions", ctx.a, @designer, body(), token)) ==
               "api_token_not_allowed"

      assert detail(call(:put, "/#{k}/versions/1", ctx.a, @designer, body(), token)) ==
               "api_token_not_allowed"

      assert detail(call(:delete, "/#{k}/versions/1", ctx.a, @designer, nil, token)) ==
               "api_token_not_allowed"

      # a token minted for a user who is NOT a contributor still cannot publish
      conn = publish(ctx.a, k, 1, v1["sha256"], Ecto.UUID.generate(), token)
      assert conn.status == 403
      assert detail(conn) == "api_token_not_allowed"

      assert call(:get, "/", ctx.a, @designer, nil, token).status == 200
      assert call(:get, "/#{k}/versions/1", ctx.a, @designer, nil, token).status == 200

      assert call(
               :post,
               "/#{k}/dry-run",
               ctx.a,
               @designer,
               %{"version" => 1, "input" => %{"x" => 1}},
               token
             ).status ==
               200
    end

    test "a context without the credential field is refused too (fail closed)", ctx do
      k = key()

      conn =
        Fixture.router_conn(:post, "/#{k}/versions", ctx.a, @designer, body())
        |> Letflow.Routers.ScriptRules.call(Letflow.Routers.ScriptRules.init([]))

      assert conn.status == 403
      assert detail(conn) == "api_token_not_allowed"
    end
  end

  # ── publish (6.3), AC8 ─────────────────────────────────────────────────────

  describe "publish" do
    test "a non-contributor tenant admin publishes the reviewed content; the version becomes immutable",
         ctx do
      k = key()
      v1 = create!(ctx.a, k, Ecto.UUID.generate())
      publisher = Ecto.UUID.generate()

      conn = publish(ctx.a, k, 1, v1["sha256"], publisher)
      assert conn.status == 200, conn.resp_body
      assert json(conn)["status"] == "published"
      assert json(conn)["publisher_id"] == publisher
      assert "script_rule.published" in audit_actions(ctx.a, k, 1)

      conn = call(:put, "/#{k}/versions/1", ctx.a, @designer, body())
      assert conn.status == 409
      assert detail(conn) == "version_immutable"
    end

    test "a contributor cannot publish; nor can a contributor to an earlier DISCARDED draft since the last publish",
         ctx do
      k = key()
      author = Ecto.UUID.generate()
      v1 = create!(ctx.a, k, author)

      conn = publish(ctx.a, k, 1, v1["sha256"], author)
      assert conn.status == 403
      assert detail(conn) == "publisher_is_contributor"

      # author of discarded v1 publishes another designer's v2: still a contributor since the last publish
      assert call(:delete, "/#{k}/versions/1", ctx.a, @designer, nil, user_id: author).status ==
               204

      v2 = create!(ctx.a, k, Ecto.UUID.generate())

      conn = publish(ctx.a, k, 2, v2["sha256"], author)
      assert conn.status == 403
      assert detail(conn) == "publisher_is_contributor"
    end

    test "a stale sha256 is 409 content_changed; a failing stored test is 422 test_case_failed",
         ctx do
      k = key()
      v1 = create!(ctx.a, k, Ecto.UUID.generate())

      conn = publish(ctx.a, k, 1, String.duplicate("0", 64), Ecto.UUID.generate())
      assert conn.status == 409
      assert detail(conn) == "content_changed"

      broken = [
        %{"name" => "wrong", "input" => %{"x" => 2}, "expect" => %{"output" => %{"y" => 5}}}
      ]

      k2 = key()

      conn = call(:post, "/#{k2}/versions", ctx.a, @designer, body(%{"test_cases" => broken}))
      assert conn.status == 201

      conn = publish(ctx.a, k2, 1, json(conn)["sha256"], Ecto.UUID.generate())
      assert conn.status == 422
      assert json(conn)["case"] == "wrong"
      assert row(ctx.a, k2, 1).status == "draft"
      assert v1["status"] == "draft"
    end

    test "a process designer cannot publish (authorization)", ctx do
      k = key()
      v1 = create!(ctx.a, k, Ecto.UUID.generate())

      conn =
        call(:post, "/#{k}/versions/1/publish", ctx.a, @designer, %{"sha256" => v1["sha256"]})

      assert conn.status == 403
    end

    test "published, retired and revoked rows are immutable at the DB level (raw writes refused, LF001)",
         ctx do
      k = key()
      v1 = create!(ctx.a, k, Ecto.UUID.generate())
      assert publish(ctx.a, k, 1, v1["sha256"], Ecto.UUID.generate()).status == 200
      schema = ctx.a.schema_name

      for update <- [
            [source: "return {}"],
            [contributors: []],
            [status: "draft"],
            [published_at: nil]
          ] do
        error =
          assert_raise Postgrex.Error, fn ->
            Repo.update_all(from(r in ScriptRule, where: r.key == ^k), [set: update],
              prefix: schema
            )
          end

        assert error.postgres.pg_code == "LF001", inspect(update)
      end

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.delete_all(from(r in ScriptRule, where: r.key == ^k), prefix: schema)
        end

      assert error.postgres.pg_code == "LF001"
    end

    test "the trigger itself refuses draft -> published with the publisher among the contributors",
         ctx do
      k = key()
      author = Ecto.UUID.generate()
      create!(ctx.a, k, author)

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.update_all(
            from(r in ScriptRule, where: r.key == ^k),
            [set: [status: "published", publisher_id: author, published_at: DateTime.utc_now()]],
            prefix: ctx.a.schema_name
          )
        end

      assert error.postgres.pg_code == "LF001"
    end
  end

  # ── retire / revoke (6.4) ──────────────────────────────────────────────────

  describe "retire and revoke" do
    test "published -> retired -> revoked with a reason; an invalid reason is 422", ctx do
      k = key()
      v1 = create!(ctx.a, k, Ecto.UUID.generate())
      assert publish(ctx.a, k, 1, v1["sha256"], Ecto.UUID.generate()).status == 200

      conn =
        call(:post, "/#{k}/versions/1/retire", ctx.a, @admin, %{"reason" => "line\u2028break"})

      assert conn.status == 422
      assert detail(conn) == "invalid_reason"

      assert call(:post, "/#{k}/versions/1/retire", ctx.a, @admin, %{"reason" => "superseded"}).status ==
               200

      assert call(:post, "/#{k}/versions/1/revoke", ctx.a, @admin, %{"reason" => "vulnerable"}).status ==
               200

      assert row(ctx.a, k, 1).status == "revoked"

      assert call(:post, "/#{k}/versions/1/retire", ctx.a, @admin, %{"reason" => "again"}).status ==
               409

      actions = audit_actions(ctx.a, k, 1)
      assert "script_rule.retired" in actions and "script_rule.revoked" in actions
    end
  end

  # ── reads, INV-5, permissions ──────────────────────────────────────────────

  describe "reads and isolation" do
    test "the list carries no source, manifest, test cases or contributors; the version route does",
         ctx do
      k = key()
      create!(ctx.a, k, Ecto.UUID.generate())

      [summary] =
        call(:get, "/", ctx.a, @designer, nil)
        |> json()
        |> Map.fetch!("items")
        |> Enum.filter(&(&1["key"] == k))

      refute Map.has_key?(summary, "source")
      refute Map.has_key?(summary, "manifest")
      refute Map.has_key?(summary, "test_cases")
      refute Map.has_key?(summary, "contributors")

      full = json(call(:get, "/#{k}/versions/1", ctx.a, @designer, nil))
      assert full["source"] == @source
    end

    test "another tenant's key, an unknown version and a malformed version all give the same plain 404",
         ctx do
      k = key()
      create!(ctx.a, k, Ecto.UUID.generate())

      responses =
        for path <- ["/#{k}/versions/1", "/#{k}/versions/99", "/#{k}/versions/abc"] do
          fixture = if path == "/#{k}/versions/1", do: ctx.b, else: ctx.a
          conn = call(:get, path, fixture, @designer, nil)
          {conn.status, conn.resp_body}
        end

      assert [{404, same}, {404, same}, {404, same}] = responses

      conn = call(:post, "/#{k}/dry-run", ctx.a, @designer, %{"version" => "abc", "input" => %{}})
      assert {conn.status, conn.resp_body} == {404, same}
    end

    test "the auditor and the other non-script roles get 403 on every route", ctx do
      k = key()
      create!(ctx.a, k, Ecto.UUID.generate())

      for roles <- [["TENANT_AUDITOR"], ["PROCESS_OPERATOR"], ["TASK_WORKER"]],
          {method, path, payload} <- [
            {:get, "/", nil},
            {:get, "/#{k}/versions/1", nil},
            {:post, "/#{k}/versions", body()},
            {:post, "/#{k}/dry-run", %{"version" => 1, "input" => %{"x" => 1}}}
          ] do
        assert call(method, path, ctx.a, roles, payload).status == 403,
               "#{inspect(roles)} #{path}"
      end
    end
  end

  # ── dry-run (7) ────────────────────────────────────────────────────────────

  describe "dry-run" do
    test "returns output, stats and the print buffer; an error outcome carries the author detail; audited without values",
         ctx do
      k = key()
      source = "print('seen ' .. ctx.input.x) " <> @source
      conn = call(:post, "/#{k}/versions", ctx.a, @designer, body(%{"source" => source}))
      assert conn.status == 201
      id = row(ctx.a, k, 1).id

      ok =
        json(
          call(:post, "/#{k}/dry-run", ctx.a, @designer, %{"version" => 1, "input" => %{"x" => 3}})
        )

      assert ok["outcome"] == "ok"
      assert ok["output"] == %{"y" => 6}
      assert is_integer(ok["stats"]["instructions_used"])
      assert ok["author"]["prints"] == ["seen 3"]

      failed =
        json(
          call(:post, "/#{k}/dry-run", ctx.a, @designer, %{
            "version" => 1,
            "input" => %{"x" => 50}
          })
        )

      assert failed["outcome"] == "script_failed"
      assert failed["fail"]["code"] == "too_big"

      conn =
        call(:post, "/#{k}/dry-run", ctx.a, @designer, %{
          "version" => 1,
          "input" => %{"x" => "nope"}
        })

      assert conn.status == 422
      assert detail(conn) == "invalid_input"

      entries =
        Entry
        |> where([e], e.resource_id == ^id and e.action == "script_rule.dry_run")
        |> Repo.all(prefix: ctx.a.schema_name)

      assert length(entries) == 2
      refute Enum.any?(entries, &(inspect(&1.after_state) =~ "seen"))
      assert row(ctx.a, k, 1).status == "draft"
    end
  end
end
