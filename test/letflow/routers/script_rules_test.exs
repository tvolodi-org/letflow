defmodule Letflow.Routers.ScriptRulesTest do
  @moduledoc """
  GH 2534 PR 7b-1 (decision 0053 D1, D6, D9, D10), design
  `lib/letflow/design/gh2534-7b1-script-registry.md` section 10: the tenant-script registry.

    * AC8: published versions immutable at DB level; publisher in the contributor set refused
      (also via an earlier DISCARDED draft); stale sha256 refused; failing stored test blocks
      publish; cross-tenant key = the exact missing-key 404 (INV-5); source absent from lists.
    * Token rule (advisor + SECURITY-REVIEWER B1): every write via an API token is refused,
      including a token minted for a non-contributor; reads and dry-run are allowed.
    * Q3 (as relaxed by 7b-2a): a read of an unflagged type is refused (`reads_not_allowed`),
      a malformed read is `invalid_manifest`. Permissions per D6. Dry-run (D10). Concurrency.

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Admission
  alias Letflow.Audit.Entry
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @admin ["TENANT_ADMIN"]
  @designer ["PROCESS_DESIGNER"]
  @script_admission Letflow.Engine.Lua.ScriptAdmission

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

    test "manifest rules: unknown key, capabilities, reads (malformed; unflagged type), oversize limits, malformed schema",
         ctx do
      k = key()

      for {manifest, code} <- [
            {Map.put(@manifest, "extra", 1), "invalid_manifest"},
            {Map.put(@manifest, "capabilities", ["read_variable"]), "invalid_manifest"},
            # 7b-2a: a malformed read is a shape error; a well-formed read of an unflagged type
            # is refused by the tenant check (reads_not_allowed)
            {Map.put(@manifest, "reads", [%{"entity_type" => "customer"}]), "invalid_manifest"},
            {Map.put(@manifest, "reads", [
               %{
                 "name" => "c",
                 "entity_type" => "customer",
                 "match" => %{"field" => "tier", "value_from" => "x"},
                 "fields" => ["name"],
                 "limit" => 1
               }
             ]), "reads_not_allowed"},
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

      # a missing field answers the code of that field
      for {field, code} <- [
            {"source", "invalid_source"},
            {"hook_kind", "invalid_hook_kind"},
            {"test_cases", "invalid_test_case"},
            {"manifest", "invalid_manifest"}
          ] do
        conn = call(:post, "/#{k}/versions", ctx.a, @designer, Map.delete(body(), field))
        assert {conn.status, detail(conn)} == {422, code}, field
      end
    end

    test "two concurrent creates of one key get versions 1 and 2", ctx do
      k = key()

      versions =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn -> call(:post, "/#{k}/versions", ctx.a, @designer, body()) end)
        end)
        |> Enum.map(&Task.await(&1, 15_000))
        |> Enum.map(fn conn ->
          assert conn.status == 201, conn.resp_body
          json(conn)["version"]
        end)

      assert Enum.sort(versions) == [1, 2]
    end
  end

  # ── token rule (6.1) ───────────────────────────────────────────────────────

  describe "API-token callers" do
    test "every write is refused (create, save, discard, publish, retire, revoke); reads and dry-run are allowed",
         ctx do
      k = key()
      v1 = create!(ctx.a, k, Ecto.UUID.generate())
      token = [credential: :api_token]

      # retire / revoke need a published version to be meaningful
      k2 = key()
      v2 = create!(ctx.a, k2, Ecto.UUID.generate())
      assert publish(ctx.a, k2, 1, v2["sha256"], Ecto.UUID.generate()).status == 200

      for {method, path, roles, payload} <- [
            {:post, "/#{k}/versions", @designer, body()},
            {:put, "/#{k}/versions/1", @designer, body()},
            {:delete, "/#{k}/versions/1", @designer, nil},
            {:post, "/#{k2}/versions/1/retire", @admin, %{"reason" => "r"}},
            {:post, "/#{k2}/versions/1/revoke", @admin, %{"reason" => "r"}}
          ] do
        conn = call(method, path, ctx.a, roles, payload, token)
        assert {conn.status, detail(conn)} == {403, "api_token_not_allowed"}, path
      end

      assert row(ctx.a, k, 1).status == "draft"
      assert row(ctx.a, k2, 1).status == "published"

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
      create!(ctx.a, k, Ecto.UUID.generate())

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
      assert detail(conn) == "test_case_failed"
      assert json(conn)["case"] == "wrong"
      assert row(ctx.a, k2, 1).status == "draft"
      assert row(ctx.a, k, 1).status == "draft"
    end

    test "no free script slot while the stored tests run is 503 script_busy, not a test failure",
         ctx do
      k = key()
      v1 = create!(ctx.a, k, Ecto.UUID.generate())
      holder = hold_all_script_slots!(ctx.a.schema_name)

      try do
        conn = publish(ctx.a, k, 1, v1["sha256"], Ecto.UUID.generate())
        assert {conn.status, detail(conn)} == {503, "script_busy"}
        assert row(ctx.a, k, 1).status == "draft"
      after
        release_script_slots!(holder, ctx.a.schema_name)
      end
    end

    test "a process designer cannot publish (authorization)", ctx do
      k = key()
      v1 = create!(ctx.a, k, Ecto.UUID.generate())

      conn =
        call(:post, "/#{k}/versions/1/publish", ctx.a, @designer, %{"sha256" => v1["sha256"]})

      assert conn.status == 403
    end

    test "published, retired, revoked and discarded rows are immutable at the DB level (raw writes refused, LF001)",
         ctx do
      published = key()
      retired = key()
      revoked = key()
      discarded = key()

      for k <- [published, retired, revoked] do
        v1 = create!(ctx.a, k, Ecto.UUID.generate())
        assert publish(ctx.a, k, 1, v1["sha256"], Ecto.UUID.generate()).status == 200
      end

      assert call(:post, "/#{retired}/versions/1/retire", ctx.a, @admin, %{"reason" => "r"}).status ==
               200

      assert call(:post, "/#{revoked}/versions/1/revoke", ctx.a, @admin, %{"reason" => "r"}).status ==
               200

      create!(ctx.a, discarded, Ecto.UUID.generate())
      assert call(:delete, "/#{discarded}/versions/1", ctx.a, @designer, nil).status == 204

      for {k, status} <- [
            {published, "published"},
            {retired, "retired"},
            {revoked, "revoked"},
            {discarded, "discarded"}
          ],
          update <- [
            [source: "return {}"],
            [contributors: []],
            [status: "draft"],
            [published_at: nil],
            [discarded_at: nil]
          ] do
        assert_lf001(fn ->
          Repo.update_all(from(r in ScriptRule, where: r.key == ^k), [set: update],
            prefix: ctx.a.schema_name
          )
        end)

        assert row(ctx.a, k, 1).status == status, "#{status} #{inspect(update)}"
      end

      for k <- [published, retired, revoked, discarded] do
        assert_lf001(fn ->
          Repo.delete_all(from(r in ScriptRule, where: r.key == ^k), prefix: ctx.a.schema_name)
        end)
      end
    end

    test "the trigger refuses draft -> published with the publisher among the contributors, or without a publisher or timestamp",
         ctx do
      k = key()
      author = Ecto.UUID.generate()
      other = Ecto.UUID.generate()
      create!(ctx.a, k, author)
      now = DateTime.utc_now()

      # GH 2534 7b-2b (TDV 1): every case carries a valid sod_excluded and self_published false,
      # so each is refused for its stated reason only (not for a missing sod_excluded).
      for set <- [
            # the contributor-publish rule (non-self-published publish by a contributor)
            [
              status: "published",
              publisher_id: author,
              published_at: now,
              self_published: false,
              sod_excluded: [author]
            ],
            [
              status: "published",
              publisher_id: nil,
              published_at: now,
              self_published: false,
              sod_excluded: [author, other]
            ],
            [
              status: "published",
              publisher_id: other,
              published_at: nil,
              self_published: false,
              sod_excluded: [author, other]
            ]
          ] do
        assert_lf001(fn ->
          Repo.update_all(from(r in ScriptRule, where: r.key == ^k), [set: set],
            prefix: ctx.a.schema_name
          )
        end)
      end

      assert row(ctx.a, k, 1).status == "draft"

      # control: the same shape with a non-contributor publisher passes the trigger
      assert {1, _} =
               Repo.update_all(
                 from(r in ScriptRule, where: r.key == ^k),
                 [
                   set: [
                     status: "published",
                     publisher_id: other,
                     published_at: now,
                     self_published: false,
                     sod_excluded: [author, other]
                   ]
                 ],
                 prefix: ctx.a.schema_name
               )
    end

    test "a NULL contributor is refused by the table constraint", ctx do
      k = key()
      create!(ctx.a, k, Ecto.UUID.generate())

      assert_raise Postgrex.Error, ~r/script_rules_contributors_no_null/, fn ->
        Repo.query!(
          ~s(UPDATE "#{ctx.a.schema_name}".script_rules SET contributors = contributors || NULL::uuid WHERE key = $1),
          [k]
        )
      end
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

    test "the list pages by (key, version) and follows the cursor; a bad cursor is 422", ctx do
      [k1, k2] = Enum.sort([key(), key()])
      create!(ctx.a, k1, Ecto.UUID.generate())
      create!(ctx.a, k1, Ecto.UUID.generate())
      create!(ctx.a, k2, Ecto.UUID.generate())

      first = json(call(:get, "/?page_size=2", ctx.a, @designer, nil))
      assert Enum.map(first["items"], &{&1["key"], &1["version"]}) == [{k1, 1}, {k1, 2}]
      assert is_binary(first["next_cursor"])

      second =
        json(call(:get, "/?page_size=2&cursor=#{first["next_cursor"]}", ctx.a, @designer, nil))

      assert Enum.map(second["items"], &{&1["key"], &1["version"]}) == [{k2, 1}]
      assert second["next_cursor"] == nil

      huge = Base.url_encode64("script-rules:#{k1}\n3000000000", padding: false)

      for cursor <- ["not-a-cursor", huge] do
        assert call(:get, "/?cursor=#{cursor}", ctx.a, @designer, nil).status == 422, cursor
      end
    end

    test "another tenant's key, an unknown key or version, a malformed or out-of-range version and a discarded version all give the same plain 404",
         ctx do
      k = key()
      create!(ctx.a, k, Ecto.UUID.generate())
      gone = key()
      create!(ctx.a, gone, Ecto.UUID.generate())
      assert call(:delete, "/#{gone}/versions/1", ctx.a, @designer, nil).status == 204

      responses =
        for {fixture, path} <- [
              {ctx.b, "/#{k}/versions/1"},
              {ctx.a, "/#{k}/versions/99"},
              {ctx.a, "/#{k}/versions/abc"},
              {ctx.a, "/#{k}/versions/3000000000"},
              {ctx.a, "/#{key()}/versions/1"},
              {ctx.a, "/#{gone}/versions/1"}
            ] do
          conn = call(:get, path, fixture, @designer, nil)
          {conn.status, conn.resp_body}
        end

      [{404, same} | _] = responses
      assert Enum.all?(responses, &(&1 == {404, same})), inspect(responses)

      # the same body on the write and dry-run routes (body version too)
      for {method, path, roles, payload} <- [
            {:post, "/#{k}/dry-run", @designer, %{"version" => "abc", "input" => %{}}},
            {:post, "/#{k}/dry-run", @designer, %{"version" => 3_000_000_000, "input" => %{}}},
            {:post, "/#{gone}/dry-run", @designer, %{"version" => 1, "input" => %{"x" => 1}}},
            {:put, "/#{gone}/versions/1", @designer, body()},
            {:delete, "/#{gone}/versions/1", @designer, nil},
            {:post, "/#{gone}/versions/1/retire", @admin, %{"reason" => "r"}},
            {:post, "/#{gone}/versions/1/revoke", @admin, %{"reason" => "r"}}
          ] do
        conn = call(method, path, ctx.a, roles, payload)
        assert {conn.status, conn.resp_body} == {404, same}, "#{method} #{path}"
      end
    end

    test "the auditor and the other non-script roles get 403 on every route", ctx do
      k = key()
      v1 = create!(ctx.a, k, Ecto.UUID.generate())

      for roles <- [["TENANT_AUDITOR"], ["PROCESS_OPERATOR"], ["TASK_WORKER"]],
          {method, path, payload} <- [
            {:get, "/", nil},
            {:get, "/#{k}/versions/1", nil},
            {:post, "/#{k}/versions", body()},
            {:put, "/#{k}/versions/1", body()},
            {:delete, "/#{k}/versions/1", nil},
            {:post, "/#{k}/versions/1/publish", %{"sha256" => v1["sha256"]}},
            {:post, "/#{k}/versions/1/retire", %{"reason" => "r"}},
            {:post, "/#{k}/versions/1/revoke", %{"reason" => "r"}},
            {:post, "/#{k}/dry-run", %{"version" => 1, "input" => %{"x" => 1}}}
          ] do
        assert call(method, path, ctx.a, roles, payload).status == 403,
               "#{inspect(roles)} #{method} #{path}"
      end

      assert row(ctx.a, k, 1).status == "draft"
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
      assert failed["author"]["prints"] == ["seen 50"]

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

    test "writes no event or entity record; a revoked version can still be dry-run", ctx do
      k = key()
      v1 = create!(ctx.a, k, Ecto.UUID.generate())
      assert publish(ctx.a, k, 1, v1["sha256"], Ecto.UUID.generate()).status == 200

      assert call(:post, "/#{k}/versions/1/revoke", ctx.a, @admin, %{"reason" => "r"}).status ==
               200

      before = data_row_counts(ctx.a.schema_name)

      conn =
        call(:post, "/#{k}/dry-run", ctx.a, @designer, %{"version" => 1, "input" => %{"x" => 4}})

      assert conn.status == 200, conn.resp_body
      assert json(conn)["output"] == %{"y" => 8}

      assert data_row_counts(ctx.a.schema_name) == before
      assert row(ctx.a, k, 1).status == "revoked"
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp assert_lf001(fun) do
    error = assert_raise Postgrex.Error, fun
    assert error.postgres.pg_code == "LF001"
  end

  defp data_row_counts(schema) do
    for table <- ["events", "entity_record_latest", "instance_projections"] do
      %{rows: [[count]]} = Repo.query!(~s[SELECT count(*) FROM "#{schema}"."#{table}"])
      {table, count}
    end
  end

  # Takes every script-admission slot this tenant can get (per-tenant or global cap,
  # whichever is hit first) from a holder process; `release_script_slots!/2` kills it and
  # waits until ScriptAdmission's caller monitor has freed the slots.
  defp hold_all_script_slots!(schema) do
    test_pid = self()

    holder =
      spawn(fn ->
        held =
          Enum.reduce_while(1..1_000, 0, fn _, n ->
            case Admission.try_acquire({:tenant, schema}, @script_admission) do
              {:ok, _ref} -> {:cont, n + 1}
              _ -> {:halt, n}
            end
          end)

        send(test_pid, {:holding, held})
        Process.sleep(:infinity)
      end)

    assert_receive {:holding, held}, 5_000
    assert held > 0
    holder
  end

  defp release_script_slots!(holder, schema) do
    Process.exit(holder, :kill)

    freed =
      Enum.reduce_while(1..100, false, fn _, _ ->
        case Admission.try_acquire({:tenant, schema}, @script_admission) do
          {:ok, ref} ->
            Admission.release(ref, @script_admission)
            {:halt, true}

          _ ->
            Process.sleep(20)
            {:cont, false}
        end
      end)

    assert freed
  end
end
