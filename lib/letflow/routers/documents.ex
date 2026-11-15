defmodule Letflow.Routers.Documents do
  @moduledoc """
  The document retention, legal-hold and print-template override routes, mounted at `/documents` by
  `Letflow.Plugs.ApiPipeline` (REQ-536, GH #3106, decision 0063 S4, S5, S7; REQ-579, GH #3289).

  | Route | Policy key -> permission | Scope class |
  |---|---|---|
  | `PUT /types/:key/retention` | `:DocumentsRetentionManage` | `:tenant_wide` |
  | `POST /:document_id/hold` | `:DocumentHold` | resolver `Letflow.Documents.ScopeResolver.document_scope/1` |
  | `POST /:document_id/hold/release` | `:DocumentHold` | same resolver |
  | `GET /print-overrides` | `:DocumentPrintTemplatesManage` | `:tenant_wide` |
  | `GET /print-overrides/:id` | `:DocumentPrintTemplatesManage` | `:tenant_wide` |
  | `POST /print-overrides` | `:DocumentPrintTemplatesManage` | `:tenant_wide` |
  | `POST /print-overrides/:id/activate` | `:DocumentPrintTemplatesManage` | `:tenant_wide` |
  | `POST /print-overrides/:id/retire` | `:DocumentPrintTemplatesManage` | `:tenant_wide` |
  | `GET /official-form-templates` | `:OfficialFormTemplatesManage` | `:tenant_wide` |
  | `GET /official-form-templates/:id` | `:OfficialFormTemplatesManage` | `:tenant_wide` |
  | `GET /official-form-templates/:id/download` | `:OfficialFormTemplatesManage` | `:tenant_wide` |
  | `GET /official-form-templates/:id/preview` | `:OfficialFormTemplatesManage` | `:tenant_wide` |
  | `POST /official-form-templates` | `:OfficialFormTemplatesManage` | `:tenant_wide` |
  | `POST /official-form-templates/:id/activate` | `:OfficialFormTemplatesManage` | `:tenant_wide` |
  | `POST /official-form-templates/:id/retire` | `:OfficialFormTemplatesManage` | `:tenant_wide` |
  | `POST /official-form-templates/:id/rollback` | `:OfficialFormTemplatesManage` | `:tenant_wide` |

  The print-override routes wrap `Letflow.Documents.PrintOverrides`: a save is 201, a 409 carries
  the context's fixed text (`PrintOverrides.conflict_reason/1`), a layout failure is a 422 whose
  `errors` hold only a rule and a layout path (never a value), and no route takes a tenant
  parameter. Server-owned body fields (`tenant_id`, `version_no`, `status`, `created_by`) are ignored.

  The official-form template routes (T-2003, decision 0089 S4b) wrap
  `Letflow.Documents.OfficialFormTemplates`: upload is multipart (`form`, `locale`, `file`), a
  refusal is a 422 whose `refusals` hold only code, rule, place, name and category (never template
  text), rollback answers 201 with the new row, download sends the stored bytes as an attachment,
  and a database failure of the audit write is a detail-free 500. Same order of checks and the same
  not-found rule as below.

  Preview (T-2004, S4c) fills the template with `FormTemplate.Sample` in ru or kk;
  it reads no tenant data besides the template and writes nothing.

  Order of checks (0063 S7): the permission at `Letflow.Plugs.Authorize` first (the same 403 for
  an existing and an absent id, since the plug does not look at the id), then body validation
  (422), then one scoped query on id and tenant prefix applying the caller's 0051 scope, then
  the state check (409) and the action with its audit event. The scope is applied inside
  `Letflow.Documents.Hold`'s locked query through `Letflow.Api.ScopeGate.scope_set/2`; the policy
  route is `:tenant_wide`, so `Letflow.Api.Scope.Enforce` refuses a partly-scoped grant with the
  unchanged 403 before the handler runs.

  The tenant comes only from `conn.assigns.scoped_opts` (INV-1) and the actor only from the
  DB-resolved `auth_context` (INV-2); no route takes a tenant identifier (INV-10). Every not-found
  case (absent, malformed, out-of-scope or other-tenant id, unknown key) goes through the one
  `Response.not_found/1`, so the bodies are byte-identical (INV-5). Responses are allowlists and
  never echo the note. Refusals (403, 404, 409, 422) write no audit event.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Api.ScopeGate
  alias Letflow.Documents.FormTemplate
  alias Letflow.Documents.Hold
  alias Letflow.Documents.OfficialFormTemplates, as: OFT
  alias Letflow.Documents.PrintOverrides
  alias Letflow.Documents.Retention
  alias Letflow.Documents.ScopeResolver

  authz_put "/types/:key/retention", :DocumentsRetentionManage, scope: :tenant_wide do
    handle_policy(conn, conn.params["key"])
  end

  authz_post "/:document_id/hold", :DocumentHold,
    scope: {:resolver, {ScopeResolver, :document_scope}} do
    handle_hold(conn, :set, conn.params["document_id"])
  end

  authz_post "/:document_id/hold/release", :DocumentHold,
    scope: {:resolver, {ScopeResolver, :document_scope}} do
    handle_hold(conn, :release, conn.params["document_id"])
  end

  authz_get "/print-overrides", :DocumentPrintTemplatesManage, scope: :tenant_wide do
    handle_override_list(conn)
  end

  authz_get "/print-overrides/:id", :DocumentPrintTemplatesManage, scope: :tenant_wide do
    handle_override_get(conn, conn.params["id"])
  end

  authz_post "/print-overrides", :DocumentPrintTemplatesManage, scope: :tenant_wide do
    handle_override_save(conn)
  end

  authz_post "/print-overrides/:id/activate", :DocumentPrintTemplatesManage,
    scope: :tenant_wide do
    handle_override_transition(conn, :activate, conn.params["id"])
  end

  authz_post "/print-overrides/:id/retire", :DocumentPrintTemplatesManage, scope: :tenant_wide do
    handle_override_transition(conn, :retire, conn.params["id"])
  end

  authz_get "/official-form-templates", :OfficialFormTemplatesManage, scope: :tenant_wide do
    handle_template_list(conn)
  end

  authz_get "/official-form-templates/:id", :OfficialFormTemplatesManage, scope: :tenant_wide do
    handle_template_get(conn, conn.params["id"])
  end

  authz_get "/official-form-templates/:id/download", :OfficialFormTemplatesManage,
    scope: :tenant_wide do
    handle_template_download(conn, conn.params["id"])
  end

  authz_get "/official-form-templates/:id/preview", :OfficialFormTemplatesManage,
    scope: :tenant_wide do
    handle_template_preview(conn, conn.params["id"])
  end

  authz_post "/official-form-templates", :OfficialFormTemplatesManage, scope: :tenant_wide do
    handle_template_upload(conn)
  end

  authz_post "/official-form-templates/:id/activate", :OfficialFormTemplatesManage,
    scope: :tenant_wide do
    handle_template_transition(conn, :activate, conn.params["id"])
  end

  authz_post "/official-form-templates/:id/retire", :OfficialFormTemplatesManage,
    scope: :tenant_wide do
    handle_template_transition(conn, :retire, conn.params["id"])
  end

  authz_post "/official-form-templates/:id/rollback", :OfficialFormTemplatesManage,
    scope: :tenant_wide do
    handle_template_transition(conn, :rollback, conn.params["id"])
  end

  authz_unmatched(:ordinary)

  # ── PUT /types/:key/retention ───────────────────────────────────────────────

  defp handle_policy(conn, key) do
    body = body(conn)

    policy = %{
      retention_period_days: Map.get(body, "retention_period_days", :missing),
      retention_from: Map.get(body, "retention_from"),
      retention_action: Map.get(body, "retention_action")
    }

    result =
      Retention.change_policy(
        prefix(conn),
        key,
        policy,
        actor_id(conn),
        Map.get(body, "reason_code")
      )

    case result do
      {:ok, %{type_key: type_key, after: after_policy, changed: changed}} ->
        Response.ok(conn, %{
          "type_key" => type_key,
          "retention_period_days" => after_policy.retention_period_days,
          "retention_from" => after_policy.retention_from,
          "retention_action" => after_policy.retention_action,
          "changed" => changed
        })

      other ->
        reply_error(conn, other)
    end
  end

  # ── POST /:document_id/hold[/release] ───────────────────────────────────────

  defp handle_hold(conn, kind, document_id) do
    body = body(conn)

    attrs = %{
      reason_code: Map.get(body, "reason_code"),
      reason_note: Map.get(body, "reason_note")
    }

    {conn, scope} = ScopeGate.scope_set(conn, :DocumentHold)

    result =
      case kind do
        :set -> Hold.set(prefix(conn), document_id, scope, attrs, actor_id(conn))
        :release -> Hold.release(prefix(conn), document_id, scope, attrs, actor_id(conn))
      end

    case result do
      {:ok, %{document_id: id, on_hold: on_hold, reason_code: reason_code}} ->
        Response.ok(conn, %{
          "document_id" => id,
          "on_hold" => on_hold,
          "reason_code" => reason_code
        })

      other ->
        reply_error(conn, other)
    end
  end

  # ── /print-overrides (REQ-579, GH #3289) ────────────────────────────────────

  @override_meta_keys ~w(id type_key locale version_no status layout_hash layout_schema_version
                         created_by activated_by activated_at retired_at reason_code inserted_at
                         updated_at)a

  defp handle_override_list(conn) do
    conn = fetch_query_params(conn)
    filters = %{type_key: conn.query_params["type_key"], locale: conn.query_params["locale"]}

    case PrintOverrides.list(prefix(conn), filters) do
      {:ok, rows} -> Response.ok(conn, %{"overrides" => Enum.map(rows, &render_meta/1)})
      other -> reply_error(conn, other)
    end
  end

  defp handle_override_get(conn, id) do
    case PrintOverrides.get(prefix(conn), id) do
      {:ok, row} -> Response.ok(conn, render_full(row))
      other -> reply_error(conn, other)
    end
  end

  # Only `type_key`, `locale` and `layout` are read from the body, by name: any server-owned
  # field a caller sends (tenant_id, version_no, status, created_by) is ignored by construction.
  defp handle_override_save(conn) do
    body = body(conn)

    result =
      case Map.get(body, "layout") do
        %{} = layout ->
          PrintOverrides.save_draft(
            prefix(conn),
            %{
              type_key: Map.get(body, "type_key"),
              locale: Map.get(body, "locale"),
              layout: layout
            },
            actor_id(conn)
          )

        _ ->
          {:error, {:unprocessable, :invalid_layout}}
      end

    case result do
      {:ok, row} -> Response.created(conn, render_full(row))
      other -> reply_error(conn, other)
    end
  end

  defp handle_override_transition(conn, action, id) do
    attrs = %{reason_code: Map.get(body(conn), "reason_code")}

    result =
      case action do
        :activate -> PrintOverrides.activate(prefix(conn), id, attrs, actor_id(conn))
        :retire -> PrintOverrides.retire(prefix(conn), id, attrs, actor_id(conn))
      end

    case result do
      {:ok, row} -> Response.ok(conn, render_full(row))
      other -> reply_error(conn, other)
    end
  end

  # Allowlist render: no tenant_id, no layout (INV-2).
  defp render_meta(row), do: Map.new(@override_meta_keys, &{Atom.to_string(&1), Map.get(row, &1)})

  defp render_full(row), do: row |> render_meta() |> Map.put("layout", row.layout)

  # Only the rule and the layout path are emitted, never a value. A caller-chosen unknown key name
  # has no stable index, so an :unknown_key violation replaces a trailing key name by "_key".
  defp violation_map(%{rule: :unknown_key, path: path}) do
    path =
      if match?([_ | _], path) and is_binary(List.last(path)),
        do: Enum.drop(path, -1) ++ ["_key"],
        else: path

    %{"rule" => "unknown_key", "path" => path}
  end

  defp violation_map(%{rule: rule, path: path}), do: %{"rule" => to_string(rule), "path" => path}

  # ── /official-form-templates (T-2003, decision 0089 S4b) ───────────────────

  @template_meta_keys ~w(id form_id locale version_no status byte_size sha256 rollback_of
                         created_by activated_by activated_at retired_at reason_code inserted_at
                         updated_at)a
  @docx_type "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  defp handle_template_list(conn) do
    conn = fetch_query_params(conn)
    filters = %{form: conn.query_params["form"], locale: conn.query_params["locale"]}

    case OFT.list(prefix(conn), filters) do
      {:ok, rows} -> Response.ok(conn, %{"templates" => Enum.map(rows, &render_template_meta/1)})
      other -> reply_template_error(conn, other)
    end
  end

  defp handle_template_get(conn, id) do
    case OFT.get(prefix(conn), id) do
      {:ok, row} -> Response.ok(conn, render_template_full(row))
      other -> reply_template_error(conn, other)
    end
  end

  defp handle_template_download(conn, id) do
    case OFT.get(prefix(conn), id) do
      {:ok, row} ->
        name = "#{row.form_id}-#{row.locale}-v#{row.version_no}.docx"

        conn
        |> Plug.Conn.put_resp_content_type(@docx_type, nil)
        |> Plug.Conn.put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
        |> Plug.Conn.put_resp_header("cache-control", "no-store")
        |> Plug.Conn.send_resp(200, row.content)

      other ->
        reply_template_error(conn, other)
    end
  end

  defp handle_template_preview(conn, id) do
    conn = fetch_query_params(conn)
    lang = conn.query_params["lang"]

    if lang in [nil, "ru", "kk"] do
      case OFT.get(prefix(conn), id) do
        {:ok, row} ->
          if row.locale in ["ru", "kk"] and lang != nil and lang != row.locale do
            Response.unprocessable(conn, "lang does not match the template locale")
          else
            lang = lang || if(row.locale in ["ru", "kk"], do: row.locale, else: "ru")
            send_template_preview(conn, row, lang)
          end

        other ->
          reply_template_error(conn, other)
      end
    else
      Response.unprocessable(conn, "invalid lang")
    end
  end

  defp send_template_preview(conn, row, lang) do
    case preview_bytes(row, lang) do
      {:ok, bytes} ->
        name = "#{row.form_id}-#{row.locale}-v#{row.version_no}-preview-#{lang}.docx"

        conn
        |> put_resp_content_type(@docx_type, nil)
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, bytes)

      {:error, refusals} when is_list(refusals) ->
        reply_template_error(conn, {:error, {:refused, refusals}})

      _ ->
        Response.internal_error(conn)
    end
  end

  # Stored bytes are re-verified by the filler. Unexpected failures expose no detail (INV-8).
  defp preview_bytes(row, lang) do
    FormTemplate.preview(row.form_id, row.content, lang)
  rescue
    _ -> {:error, :internal}
  end

  # Only `form`, `locale` and `file` are read, by name. The size is checked from the file's stat
  # before the file is read, with the refusal S1's own size check gives.
  defp handle_template_upload(conn) do
    body = body(conn)

    with {:file, %Plug.Upload{path: path}} <- {:file, Map.get(body, "file")},
         {:stat, {:ok, %{size: size}}} <- {:stat, File.stat(path)},
         :ok <- template_size_ok(size),
         {:read, {:ok, bytes}} <- {:read, File.read(path)} do
      attrs = %{form: Map.get(body, "form"), locale: Map.get(body, "locale"), bytes: bytes}

      case guarded(fn -> OFT.upload(prefix(conn), attrs, actor_id(conn)) end) do
        {:ok, row} -> Response.created(conn, render_template_full(row))
        other -> reply_template_error(conn, other)
      end
    else
      {:file, _} -> reply_template_error(conn, {:error, {:unprocessable, :invalid_bytes}})
      {:error, _} = refused -> reply_template_error(conn, refused)
      _ -> Response.internal_error(conn)
    end
  end

  defp template_size_ok(size) do
    if size > FormTemplate.limits().compressed do
      {:error, [refusal]} = FormTemplate.error(:too_large)
      {:error, {:refused, [refusal]}}
    else
      :ok
    end
  end

  defp handle_template_transition(conn, action, id) do
    attrs = %{reason_code: Map.get(body(conn), "reason_code")}
    prefix = prefix(conn)
    actor = actor_id(conn)

    result =
      guarded(fn ->
        case action do
          :activate -> OFT.activate(prefix, id, attrs, actor)
          :retire -> OFT.retire(prefix, id, attrs, actor)
          :rollback -> OFT.rollback(prefix, id, attrs, actor)
        end
      end)

    case result do
      {:ok, row} when action == :rollback -> Response.created(conn, render_template_full(row))
      {:ok, row} -> Response.ok(conn, render_template_full(row))
      other -> reply_template_error(conn, other)
    end
  end

  # Audit.insert_entry/3 raises on a database failure (INV-8): a detail-free 500, nothing of the
  # exception reaches the body.
  defp guarded(fun) do
    fun.()
  rescue
    _e in [Ecto.ConstraintError, Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :internal}
  end

  # Allowlist render: no tenant_id, no content (INV-2). The wire name of form_id is "form".
  defp render_template_meta(row) do
    @template_meta_keys
    |> Map.new(fn
      :form_id -> {"form", Map.get(row, :form_id)}
      key -> {Atom.to_string(key), Map.get(row, key)}
    end)
  end

  defp render_template_full(row),
    do: row |> render_template_meta() |> Map.put("summary", Map.get(row, :summary))

  defp refusal_map(refusal) do
    %{
      "code" => to_string_or_nil(Map.get(refusal, :code)),
      "rule" => to_string_or_nil(Map.get(refusal, :rule)),
      "place" => Map.get(refusal, :place),
      "name" => to_string_or_nil(Map.get(refusal, :name)),
      "category" => to_string_or_nil(Map.get(refusal, :category))
    }
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp reply_template_error(conn, {:error, :not_found}), do: Response.not_found(conn)

  defp reply_template_error(conn, {:error, {:refused, refusals}}) do
    Response.unprocessable_with(conn, "template refused", %{
      "refusals" => Enum.map(refusals, &refusal_map/1)
    })
  end

  defp reply_template_error(conn, {:error, {:unprocessable, :unknown_form}}),
    do: Response.unprocessable(conn, "unknown form")

  defp reply_template_error(conn, {:error, {:unprocessable, :invalid_locale}}),
    do: Response.unprocessable(conn, "invalid locale")

  defp reply_template_error(conn, {:error, {:unprocessable, :invalid_reason_code}}),
    do: Response.unprocessable(conn, "invalid reason_code")

  defp reply_template_error(conn, {:error, {:unprocessable, :invalid_bytes}}),
    do: Response.unprocessable(conn, ~s(a file part named "file" is required))

  defp reply_template_error(conn, {:error, {:unprocessable, _other}}),
    do: Response.unprocessable(conn, "invalid request")

  defp reply_template_error(conn, {:error, {:conflict, reason}}),
    do: Response.conflict(conn, OFT.conflict_reason(reason))

  defp reply_template_error(conn, _other), do: Response.internal_error(conn)

  # ── replies ─────────────────────────────────────────────────────────────────

  defp reply_error(conn, {:error, {:unprocessable, reason}}),
    do: Response.unprocessable(conn, unprocessable_detail(reason))

  defp reply_error(conn, {:error, :not_found}), do: Response.not_found(conn)

  defp reply_error(conn, {:error, :conflict}),
    do: Response.conflict(conn, "document hold state conflict")

  defp reply_error(conn, {:error, {:conflict, reason}}),
    do: Response.conflict(conn, PrintOverrides.conflict_reason(reason))

  defp reply_error(conn, {:error, {:invalid_layout, violations}}) do
    Response.send_problem(conn, %{
      Error.unprocessable("layout failed validation")
      | errors: Enum.map(violations, &violation_map/1)
    })
  end

  # Anything else (audit failure, bad schema name): the detail-free 500 (INV-8).
  defp reply_error(conn, _other), do: Response.internal_error(conn)

  # Fixed text per reason: no input is echoed.
  defp unprocessable_detail(:invalid_reason_code), do: "invalid reason_code"
  defp unprocessable_detail(:invalid_reason_note), do: "invalid reason_note"
  defp unprocessable_detail(:invalid_period), do: "invalid retention_period_days"
  defp unprocessable_detail(:invalid_retention_from), do: "invalid retention_from"
  defp unprocessable_detail(:invalid_retention_action), do: "invalid retention_action"

  defp unprocessable_detail(:period_action_mismatch),
    do: "retention_period_days and retention_action do not match"

  defp unprocessable_detail(:unknown_type_key), do: "unknown type_key"
  defp unprocessable_detail(:invalid_locale), do: "invalid locale"
  defp unprocessable_detail(:invalid_layout), do: "invalid layout"

  defp unprocessable_detail(_other), do: "invalid request"

  # ── context ─────────────────────────────────────────────────────────────────

  defp body(conn) do
    case conn.body_params do
      %{} = params -> Map.delete(params, "_json")
      _ -> %{}
    end
  end

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
  defp actor_id(conn), do: conn.assigns.auth_context.user_id
end
