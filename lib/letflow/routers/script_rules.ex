defmodule Letflow.Routers.ScriptRules do
  @moduledoc """
  GH 2534 PR 7b-1 (decision 0053 D1, D6, D9, D10): the tenant-script registry routes, mounted
  at `/script-rules` by `Letflow.Plugs.ApiPipeline`. Design:
  `lib/letflow/design/gh2534-7b1-script-registry.md` section 5.

  | Route | Permission |
  |---|---|
  | `GET /` (summaries, no source) | `:ScriptsWrite` |
  | `GET /:key/versions/:version` | `:ScriptsWrite` |
  | `POST /:key/versions` (new draft) | `:ScriptsWrite` |
  | `PUT /:key/versions/:version` (save draft) | `:ScriptsWrite` |
  | `DELETE /:key/versions/:version` (discard draft) | `:ScriptsWrite` |
  | `POST /:key/versions/:version/publish` | `:ScriptsPublish` |
  | `POST /:key/versions/:version/retire` | `:ScriptsPublish` |
  | `POST /:key/versions/:version/revoke` | `:ScriptsPublish` |
  | `POST /:key/versions/:version/confirm` (7b-2b) | `:ScriptRulesConfirm` -> `:ScriptsPublish` |
  | `POST /:key/dry-run` | `:ScriptsWrite` |

  The tenant comes only from `conn.assigns.scoped_opts` (INV-1); the actor and its credential
  only from `conn.assigns.auth_context`. Every write requires an OIDC credential (403
  `api_token_not_allowed` for API-token callers). An unknown key, an unknown or malformed
  version (path or body), another tenant's key and a discarded version on read routes all
  answer the same plain 404 (INV-5). Responses are built by the allowlist functions
  `summary_map/1` and `version_map/1` (INV-2); bodies never echo submitted values.
  Deferred: the auditor source read (`:AuditRead`, D9) is GH 2548.

  7b-2a (`lib/letflow/design/gh2534-7b2a-script-policy.md` sections 5, 10): dry-run takes an
  optional `reads` fixture; while the tenant's script kill switch is on, dry-run and publish
  answer 409 `scripts_disabled`.

  7b-2b (`lib/letflow/design/gh2534-7b2b-script-sod.md` sections 6.2, 6.4, 6.6): confirm
  (`{sha256}`, OIDC only) clears a self-published version: 403 `not_tenant_wide_admin` /
  `confirmer_is_contributor`, 409 `not_pending_review` / `content_changed`, the plain 404 for
  an unknown, foreign or discarded version. `summary_map/1` gains `confirmed_at`;
  `version_map/1` gains `confirmed_by`, `confirmed_sha256` and `sod_excluded`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Authorization
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.PlatformTenant
  alias Letflow.Scripts
  alias Letflow.Scripts.ScriptRule

  @cursor_prefix "script-rules:"

  authz_get "/", :ScriptRulesList do
    handle_list(conn)
  end

  authz_get "/:key/versions/:version", :ScriptRulesRead do
    reply(
      conn,
      Scripts.get(prefix(conn), conn.params["key"], conn.params["version"]),
      &version_map/1
    )
  end

  authz_post "/:key/versions", :ScriptsWrite do
    case Scripts.create_draft(prefix(conn), conn.params["key"], conn.body_params, actor(conn)) do
      {:ok, rule} -> Response.created(conn, version_map(rule))
      other -> reply(conn, other, &version_map/1)
    end
  end

  authz_put "/:key/versions/:version", :ScriptsWrite do
    reply(
      conn,
      Scripts.save_draft(
        prefix(conn),
        conn.params["key"],
        conn.params["version"],
        conn.body_params,
        actor(conn)
      ),
      &version_map/1
    )
  end

  authz_delete "/:key/versions/:version", :ScriptsWrite do
    case Scripts.discard(prefix(conn), conn.params["key"], conn.params["version"], actor(conn)) do
      {:ok, _rule} -> Response.no_content(conn)
      other -> reply(conn, other, &version_map/1)
    end
  end

  authz_post "/:key/versions/:version/publish", :ScriptsPublish do
    reply(
      conn,
      Scripts.publish(
        prefix(conn),
        conn.params["key"],
        conn.params["version"],
        conn.body_params["sha256"],
        actor(conn),
        holds?(conn, :EntitiesRestrictionsManage)
      ),
      &version_map/1
    )
  end

  authz_post "/:key/versions/:version/retire", :ScriptsPublish do
    reply(
      conn,
      Scripts.retire(
        prefix(conn),
        conn.params["key"],
        conn.params["version"],
        conn.body_params["reason"],
        actor(conn)
      ),
      &version_map/1
    )
  end

  authz_post "/:key/versions/:version/revoke", :ScriptsPublish do
    reply(
      conn,
      Scripts.revoke(
        prefix(conn),
        conn.params["key"],
        conn.params["version"],
        conn.body_params["reason"],
        actor(conn)
      ),
      &version_map/1
    )
  end

  authz_post "/:key/versions/:version/confirm", :ScriptRulesConfirm do
    reply(
      conn,
      Scripts.confirm(
        prefix(conn),
        conn.params["key"],
        conn.params["version"],
        conn.body_params["sha256"],
        actor(conn)
      ),
      &version_map/1
    )
  end

  authz_post "/:key/dry-run", :ScriptsWrite do
    reply(
      conn,
      Scripts.dry_run(
        prefix(conn),
        conn.params["key"],
        conn.body_params["version"],
        conn.body_params["input"],
        conn.body_params["reads"],
        actor(conn)
      ),
      &dry_run_map/1
    )
  end

  authz_unmatched(:ordinary)

  # ── list ───────────────────────────────────────────────────────────────────

  defp handle_list(conn) do
    query = Plug.Conn.fetch_query_params(conn).query_params

    with {:ok, raw_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_size),
         {:ok, after_cursor} <- decode_cursor(Map.get(query, "cursor")) do
      {rows, next} = Scripts.list(prefix(conn), page_size, after_cursor)
      page = Pagination.page_response(Enum.map(rows, &summary_map/1), encode_cursor(next))
      Response.ok(conn, page)
    else
      _ -> Response.unprocessable(conn, "invalid pagination parameters")
    end
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         @cursor_prefix <> rest <- raw,
         [key, version] <- String.split(rest, "\n", parts: 2),
         {version, ""} when version > 0 and version <= 2_147_483_647 <- Integer.parse(version) do
      {:ok, {key, version}}
    else
      _ -> :error
    end
  end

  defp encode_cursor(nil), do: nil

  defp encode_cursor({key, version}),
    do: Pagination.encode_cursor(@cursor_prefix <> key <> "\n" <> Integer.to_string(version))

  # ── replies ────────────────────────────────────────────────────────────────

  defp reply(conn, {:ok, value}, builder), do: Response.ok(conn, builder.(value))

  defp reply(conn, {:error, :test_case_failed, failure}, _builder),
    do:
      Response.send_json(conn, 422, %{
        "error" => "test_case_failed",
        "detail" => "test_case_failed",
        "case" => failure.name,
        "outcome" => failure.outcome
      })

  defp reply(conn, {:error, :not_found}, _builder), do: Response.not_found(conn)

  defp reply(conn, {:error, :api_token_not_allowed}, _builder),
    do: Response.forbidden(conn, "api_token_not_allowed")

  defp reply(conn, {:error, :publisher_is_contributor}, _builder),
    do: Response.forbidden(conn, "publisher_is_contributor")

  defp reply(conn, {:error, :restricted_inputs_not_allowed}, _builder),
    do: Response.forbidden(conn, "restricted_inputs_not_allowed")

  # 7b-2b (design 6.6): confirm's caller refusals.
  defp reply(conn, {:error, code}, _builder)
       when code in [:not_tenant_wide_admin, :confirmer_is_contributor],
       do: Response.forbidden(conn, Atom.to_string(code))

  # 7b-2a: :scripts_disabled (the effective kill switch is on) is a 409 beside these; 7b-2b
  # adds :not_pending_review.
  # 7c-1 (D3, C19): :version_in_use, a retire of a version an ACTIVE definition binds.
  defp reply(conn, {:error, code}, _builder)
       when code in [
              :version_immutable,
              :content_changed,
              :scripts_disabled,
              :not_pending_review,
              :version_in_use
            ],
       do: Response.conflict(conn, Atom.to_string(code))

  defp reply(conn, {:error, :script_busy}, _builder),
    do: Response.send_json(conn, 503, %{"error" => "script_busy", "detail" => "script_busy"})

  defp reply(conn, {:error, :audit_failed}, _builder), do: Response.internal_error(conn)
  # A missing policy row is a provisioning defect (7b-2a P7): 500, as on the policy routes.
  defp reply(conn, {:error, :policy_missing}, _builder), do: Response.internal_error(conn)
  defp reply(conn, {:error, {:audit_failed, _}}, _builder), do: Response.internal_error(conn)

  defp reply(conn, {:error, code}, _builder) when is_atom(code),
    do: Response.unprocessable(conn, Atom.to_string(code))

  # ── allowlist builders (INV-2) ─────────────────────────────────────────────

  @doc """
  The summary allowlist (INV-2): no source, manifest, test cases or contributors (D9). Public
  only so `Letflow.Routers.ScriptPolicy`'s pending-review list (7b-2b) answers the same shape.
  """
  @spec summary_map(ScriptRule.t()) :: map()
  def summary_map(%ScriptRule{} = rule) do
    %{
      "key" => rule.key,
      "version" => rule.version,
      "status" => rule.status,
      "hook_kind" => rule.hook_kind,
      "sha256" => rule.sha256,
      "publisher_id" => rule.publisher_id,
      "published_at" => rule.published_at,
      "retired_at" => rule.retired_at,
      "revoked_at" => rule.revoked_at,
      "discarded_at" => rule.discarded_at,
      "self_published" => rule.self_published,
      "confirmed_at" => rule.confirmed_at
    }
  end

  defp version_map(%ScriptRule{} = rule) do
    Map.merge(summary_map(rule), %{
      "source" => rule.source,
      "manifest" => rule.manifest,
      "test_cases" => rule.test_cases,
      "contributors" => rule.contributors,
      "sod_excluded" => rule.sod_excluded,
      "confirmed_by" => rule.confirmed_by,
      "confirmed_sha256" => rule.confirmed_sha256,
      "created_at" => rule.inserted_at,
      "updated_at" => rule.updated_at
    })
  end

  defp dry_run_map(result) do
    author =
      case result.author do
        nil ->
          nil

        a ->
          %{
            "message" => a.message,
            "line" => a.line,
            "prints" => a.prints,
            "prints_dropped" => a.prints_dropped
          }
      end

    stats =
      case Map.get(result, :stats) do
        nil ->
          nil

        s ->
          %{
            "duration_us" => s.duration_us,
            "instructions_used" => s.instructions_used,
            "heap_words_at_end" => s.heap_words_at_end
          }
      end

    %{
      "outcome" => result.outcome,
      "output" => Map.get(result, :output),
      "fail" => Map.get(result, :fail),
      "stats" => stats,
      "author" => author
    }
  end

  # ── context ────────────────────────────────────────────────────────────────

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

  defp actor(conn) do
    context = conn.assigns.auth_context
    %{user_id: context.user_id, credential: Map.get(context, :credential)}
  end

  # Recomputed from the DB-resolved auth context (never a request value).
  defp holds?(conn, permission) do
    context = conn.assigns.auth_context
    platform_tenant? = PlatformTenant.platform_tenant?(Map.get(context, :tenant_id))

    Authorization.has_permission_in_scope?(
      Authorization.effective_roles(Map.get(context, :roles, []), platform_tenant?),
      permission,
      platform_tenant?
    )
  end
end
