defmodule Letflow.Documents.OfficialFormTemplates do
  @moduledoc """
  Per-tenant company templates (docx) of the official print forms, slice S4a of decision 0089 D5
  (T-1982): storage, versions, rollback and audit. The routes (`Letflow.Routers.Documents`) and the
  permission `:OfficialFormTemplatesManage` are S4b (T-2003), preview is S4c (T-2004, `FormTemplate.preview/4`). The print path (S3, T-1985) reads it through `active_for_print/3` and `print_docx/5`.

  A template is one stored docx for a `(form_id, locale)` pair with a status
  `draft -> active -> retired` (a draft may also be discarded: `draft -> retired`). `upload/4`
  runs `Letflow.Documents.FormTemplate.check/3` (S1) and stores only the bytes that check writes
  out, never the raw upload (0089 D4, one parse); a refused upload writes nothing. `activate/5`
  turns a draft into the one active row of its pair and retires the previous active row in the
  same transaction (`reason_code "superseded"`); `retire/4` retires a draft or an active row;
  `rollback/5` inserts a new version, already active, that copies the bytes of a template that was
  once active and records it in `rollback_of`. The source row is never changed. The bytes of a row
  never change at all and no row is deleted (database trigger).

  Activation and rollback run the S1 check again on the stored bytes, so a template that a later
  release made outdated cannot be activated; a refusal leaves everything as it was. The print-time
  fail-closed rule is `print_docx/5` (S3): the same check runs on every docx print.

  One administrator is enough (owner checklist item 10): activation does not need a second person.
  The audit row records `self_activated` (the actor created the template) instead (item 9).

  Every function takes the tenant schema name `prefix` first (INV-1, INV-6), reads only the atom
  keys documented per function from `attrs` (a `tenant_id`, `version_no`, `status` or `created_by`
  in `attrs` is ignored by construction), and answers an absent id, a malformed id and (by prefix)
  another tenant's row identically: `{:error, :not_found}` (INV-5).

  Each successful call writes exactly one audit row in the same transaction
  (`document.official_form_template_uploaded`, `_activated`, `_retired`, `_rolled_back`). The
  `after_state` keys are exactly `template_id`, `form`, `locale`, `version_no`, `sha256`,
  `actor_id`, `reason_code`, `rollback_of`, `superseded_id`, `self_activated`: never the bytes, the
  structure summary or any text of the template (0089 D5, decision 0056 D9). The implicit
  retirement of the superseded row writes no audit row of its own. A refusal writes none.
  Lock order: the template row (`FOR UPDATE`), the per-pair advisory lock, then the audit chain
  row inside `Letflow.Audit.insert_entry/3`. `retire/4` takes no pair lock: the supersede update of
  `activate/5` and `rollback/5` is conditional on `status = 'active'`, so the two never act on a
  row the other already retired, and no lock cycle exists. `Audit.insert_entry/3` raises on a
  database failure; the transaction rolls back and the raise propagates.
  """

  import Ecto.Query

  require Logger

  alias Letflow.Audit
  alias Letflow.Documents.FormPrint
  alias Letflow.Documents.FormTemplate
  alias Letflow.Documents.OfficialFormTemplate
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @locales ~w(default ru kk)
  @reason_code_re ~r/^[a-z][a-z0-9_]{0,63}$/

  @type refusal :: FormTemplate.refusal()
  @type error ::
          {:error, :not_found | :invalid_schema_name}
          | {:error,
             {:unprocessable,
              :unknown_form
              | :invalid_locale
              | :invalid_actor
              | :invalid_reason_code
              | :invalid_bytes}}
          | {:error, {:refused, [refusal()]}}
          | {:error, {:conflict, :not_a_draft | :not_retirable | :not_rollbackable}}

  @doc """
  Stores a new draft. `attrs`: `:form` (one of `FormPrint.forms/0`), `:locale` (`default`, `ru`,
  `kk`), `:bytes` (the uploaded docx). The caller is `created_by`. `opts` go to
  `FormTemplate.check/3`.
  """
  @spec upload(String.t(), map(), term(), keyword()) :: {:ok, %OfficialFormTemplate{}} | error()
  def upload(prefix, attrs, actor_id, opts \\ []) when is_binary(prefix) and is_map(attrs) do
    form = Map.get(attrs, :form)
    locale = Map.get(attrs, :locale)
    bytes = Map.get(attrs, :bytes)

    with {:ok, actor_id} <- validate_actor(actor_id),
         :ok <- validate_form(form),
         :ok <- validate_locale(locale),
         :ok <- validate_bytes(bytes),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, result} <- check(form, bytes, opts) do
      now = DateTime.utc_now()

      Repo.transaction(fn ->
        lock_pair(prefix, form, locale)

        row =
          Repo.insert!(
            %OfficialFormTemplate{
              id: Ecto.UUID.generate(),
              tenant_id: tenant_id,
              form_id: form,
              locale: locale,
              version_no: next_version(prefix, form, locale),
              status: "draft",
              content: result.bytes,
              byte_size: byte_size(result.bytes),
              sha256: result.sha256,
              summary: result.summary,
              created_by: actor_id,
              inserted_at: now,
              updated_at: now
            },
            prefix: prefix
          )

        write_event(:uploaded, prefix, row, actor_id, %{})
        row
      end)
    end
  end

  @doc "Activates a draft. `attrs`: `:reason_code` (format only). `opts` go to the S1 re-check."
  @spec activate(String.t(), term(), map(), term(), keyword()) ::
          {:ok, %OfficialFormTemplate{}} | error()
  def activate(prefix, id, attrs, actor_id, opts \\ []) when is_binary(prefix) do
    with {:ok, code} <- validate_reason(attrs),
         {:ok, actor_id} <- validate_actor(actor_id),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, id} <- cast_id(id) do
      Repo.transaction(fn ->
        case do_activate(prefix, id, code, actor_id, opts) do
          {:ok, row} -> row
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Retires a draft or an active template. `attrs`: `:reason_code` (format only)."
  @spec retire(String.t(), term(), map(), term()) :: {:ok, %OfficialFormTemplate{}} | error()
  def retire(prefix, id, attrs, actor_id) when is_binary(prefix) do
    with {:ok, code} <- validate_reason(attrs),
         {:ok, actor_id} <- validate_actor(actor_id),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, id} <- cast_id(id) do
      Repo.transaction(fn ->
        case do_retire(prefix, id, code, actor_id) do
          {:ok, row} -> row
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Rolls back to a retired template that was once active: inserts a new active version with its
  bytes. `attrs`: `:reason_code` (format only). `opts` go to the S1 re-check.
  """
  @spec rollback(String.t(), term(), map(), term(), keyword()) ::
          {:ok, %OfficialFormTemplate{}} | error()
  def rollback(prefix, id, attrs, actor_id, opts \\ []) when is_binary(prefix) do
    with {:ok, code} <- validate_reason(attrs),
         {:ok, actor_id} <- validate_actor(actor_id),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, id} <- cast_id(id) do
      Repo.transaction(fn ->
        case do_rollback(prefix, id, code, actor_id, opts) do
          {:ok, row} -> row
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "One template with its bytes."
  @spec get(String.t(), term()) :: {:ok, %OfficialFormTemplate{}} | {:error, :not_found}
  def get(prefix, id) when is_binary(prefix) do
    with {:ok, id} <- cast_id(id),
         %OfficialFormTemplate{} = row <- Repo.get(OfficialFormTemplate, id, prefix: prefix) do
      {:ok, row}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The active template that a print of `form` in `lang` (`ru` or `kk`) uses (0089 D5, S3, T-1985): the
  active row of that language, else the active `default` row, else `:none`. One query in the tenant
  schema `prefix` (INV-1); the partial unique index allows at most one active row per pair, so at
  most two rows come back. Drafts and retired rows are never returned.
  """
  @spec active_for_print(String.t(), String.t(), String.t()) ::
          {:ok, %{id: term(), locale: String.t(), version_no: integer(), content: binary()}}
          | :none
  def active_for_print(prefix, form, lang)
      when is_binary(prefix) and is_binary(form) and is_binary(lang) do
    rows =
      Repo.all(
        from(t in OfficialFormTemplate,
          where: t.form_id == ^form and t.status == "active" and t.locale in ^[lang, "default"],
          select: map(t, [:id, :locale, :version_no, :content])
        ),
        prefix: prefix
      )

    case Enum.find(rows, &(&1.locale == lang)) || Enum.find(rows, &(&1.locale == "default")) do
      nil -> :none
      row -> {:ok, row}
    end
  end

  @doc """
  The docx of `form` from the company template (0089 D5, S3, T-1985). `:standard` when no template
  is active (the caller prints the platform form). Otherwise the stored bytes go through
  `FormTemplate.fill/5`, which runs the whole upload check again, so a template that a later
  release made outdated (or that a newer signature flags) is refused: `{:error,
  :form_template_outdated}`. A scanner outage answers `{:error, :form_template_unavailable}`; so
  does a failure to write the package (a raise of the XML writer is not caught). There is never a
  fallback to the standard form. Each refusal writes one warning line with codes, ids and numbers
  only, never a template name, text or byte. A print is a read: no audit row. `opts`: `:scanner`,
  `:catalog` (test seams).
  """
  @spec print_docx(String.t(), String.t(), map(), String.t(), keyword()) ::
          :standard
          | {:ok, binary()}
          | {:error, :form_template_outdated | :form_template_unavailable}
  def print_docx(prefix, form, data, lang, opts \\ []) do
    case active_for_print(prefix, form, lang) do
      :none ->
        :standard

      {:ok, row} ->
        case FormTemplate.fill(
               form,
               row.content,
               data,
               lang,
               Keyword.take(opts, [:scanner, :catalog])
             ) do
          {:ok, bin} ->
            {:ok, bin}

          {:error, [_ | _] = refusals} ->
            codes = refusals |> Enum.map(& &1.code) |> Enum.uniq()
            log_refused(form, row, Enum.map_join(codes, ",", &Atom.to_string/1))

            if Enum.all?(codes, &(&1 == :scan_unavailable)),
              do: {:error, :form_template_unavailable},
              else: {:error, :form_template_outdated}

          {:error, _other} ->
            log_refused(form, row, "write_failed")
            {:error, :form_template_unavailable}
        end
    end
  end

  defp log_refused(form, row, codes) do
    Logger.warning(
      "official form template refused at print: form=#{form} locale=#{row.locale} " <>
        "version=#{row.version_no} template_id=#{row.id} codes=#{codes}"
    )
  end

  @doc """
  Metadata of the templates (every column except `:content`), newest version first per pair.
  `filters`: optional `:form`, `:locale` (equality; ignored when not strings). Rows per tenant are
  bounded by administrator uploads (forms x 3 locales x versions), so there is no cap.
  """
  @spec list(String.t(), map() | keyword()) :: {:ok, [map()]} | {:error, :invalid_schema_name}
  def list(prefix, filters \\ %{}) when is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      fields = OfficialFormTemplate.metadata_fields()

      query =
        from(t in OfficialFormTemplate,
          order_by: [asc: t.form_id, asc: t.locale, desc: t.version_no],
          select: map(t, ^fields)
        )

      query =
        Enum.reduce([form: :form_id, locale: :locale], query, fn {key, column}, q ->
          case Access.get(filters, key) do
            value when is_binary(value) -> where(q, [t], field(t, ^column) == ^value)
            _ -> q
          end
        end)

      {:ok, Repo.all(query, prefix: prefix)}
    end
  end

  @doc "The fixed 409 text of a context-level conflict reason."
  @spec conflict_reason(:not_a_draft | :not_retirable | :not_rollbackable) :: String.t()
  def conflict_reason(:not_a_draft), do: "template is not a draft"
  def conflict_reason(:not_retirable), do: "template is already retired"

  def conflict_reason(:not_rollbackable),
    do: "only a retired template that was once active can be rolled back to"

  # -- transitions --------------------------------------------------------------------------

  defp do_activate(prefix, id, code, actor_id, opts) do
    case lock_row(prefix, id) do
      nil ->
        {:error, :not_found}

      %OfficialFormTemplate{status: status} when status != "draft" ->
        {:error, {:conflict, :not_a_draft}}

      %OfficialFormTemplate{} = row ->
        lock_pair(prefix, row.form_id, row.locale)

        with {:ok, _result} <- check(row.form_id, row.content, opts) do
          now = DateTime.utc_now()
          superseded_id = supersede(prefix, row.form_id, row.locale, now)

          from(t in OfficialFormTemplate, where: t.id == ^id)
          |> Repo.update_all(
            [
              set: [
                status: "active",
                activated_by: actor_id,
                activated_at: now,
                reason_code: code,
                updated_at: now
              ]
            ],
            prefix: prefix
          )

          updated = Repo.get!(OfficialFormTemplate, id, prefix: prefix)

          write_event(:activated, prefix, updated, actor_id, %{
            superseded_id: superseded_id,
            self_activated: actor_id == row.created_by
          })

          {:ok, updated}
        end
    end
  end

  defp do_retire(prefix, id, code, actor_id) do
    case lock_row(prefix, id) do
      nil ->
        {:error, :not_found}

      %OfficialFormTemplate{status: "retired"} ->
        {:error, {:conflict, :not_retirable}}

      %OfficialFormTemplate{} ->
        now = DateTime.utc_now()

        from(t in OfficialFormTemplate, where: t.id == ^id)
        |> Repo.update_all(
          [set: [status: "retired", retired_at: now, reason_code: code, updated_at: now]],
          prefix: prefix
        )

        updated = Repo.get!(OfficialFormTemplate, id, prefix: prefix)
        write_event(:retired, prefix, updated, actor_id, %{})
        {:ok, updated}
    end
  end

  defp do_rollback(prefix, id, code, actor_id, opts) do
    case lock_row(prefix, id) do
      nil ->
        {:error, :not_found}

      %OfficialFormTemplate{status: status, activated_at: activated_at}
      when status != "retired" or is_nil(activated_at) ->
        {:error, {:conflict, :not_rollbackable}}

      %OfficialFormTemplate{} = source ->
        lock_pair(prefix, source.form_id, source.locale)

        with {:ok, _result} <- check(source.form_id, source.content, opts) do
          now = DateTime.utc_now()
          superseded_id = supersede(prefix, source.form_id, source.locale, now)

          row =
            Repo.insert!(
              %OfficialFormTemplate{
                id: Ecto.UUID.generate(),
                tenant_id: source.tenant_id,
                form_id: source.form_id,
                locale: source.locale,
                version_no: next_version(prefix, source.form_id, source.locale),
                status: "active",
                content: source.content,
                byte_size: source.byte_size,
                sha256: source.sha256,
                summary: source.summary,
                rollback_of: source.id,
                created_by: actor_id,
                activated_by: actor_id,
                activated_at: now,
                reason_code: code,
                inserted_at: now,
                updated_at: now
              },
              prefix: prefix
            )

          write_event(:rolled_back, prefix, row, actor_id, %{
            superseded_id: superseded_id,
            self_activated: actor_id == source.created_by
          })

          {:ok, row}
        end
    end
  end

  # Retires the current active row of the pair first, so the partial unique index never sees two.
  # Conditional on `status = 'active'`: a concurrent `retire/4` that got there first is not undone.
  defp supersede(prefix, form, locale, now) do
    {_n, rows} =
      from(t in OfficialFormTemplate,
        where: t.form_id == ^form and t.locale == ^locale and t.status == "active",
        select: t.id
      )
      |> Repo.update_all(
        [
          set: [
            status: "retired",
            retired_at: now,
            reason_code: "superseded",
            updated_at: now
          ]
        ],
        prefix: prefix
      )

    List.first(rows)
  end

  defp lock_row(prefix, id) do
    from(t in OfficialFormTemplate, where: t.id == ^id, lock: "FOR UPDATE")
    |> Repo.one(prefix: prefix)
  end

  # Advisory locks are database-wide, so the schema name is part of the key.
  defp lock_pair(prefix, form, locale) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      prefix <> ":" <> form <> ":" <> locale
    ])
  end

  defp next_version(prefix, form, locale) do
    from(t in OfficialFormTemplate,
      where: t.form_id == ^form and t.locale == ^locale,
      select: coalesce(max(t.version_no), 0) + 1
    )
    |> Repo.one!(prefix: prefix)
  end

  defp check(form, bytes, opts) do
    case FormTemplate.check(form, bytes, opts) do
      {:ok, result} -> {:ok, result}
      {:error, refusals} -> {:error, {:refused, refusals}}
    end
  end

  # -- audit --------------------------------------------------------------------------------

  defp write_event(kind, prefix, %OfficialFormTemplate{} = row, actor_id, extra) do
    entry = %{
      actor_id: actor_id,
      action: action(kind),
      resource_type: "official_form_template",
      resource_id: row.id,
      before_state: nil,
      after_state: %{
        "template_id" => row.id,
        "form" => row.form_id,
        "locale" => row.locale,
        "version_no" => row.version_no,
        "sha256" => row.sha256,
        "actor_id" => actor_id,
        "reason_code" => row.reason_code,
        "rollback_of" => row.rollback_of,
        "superseded_id" => Map.get(extra, :superseded_id),
        "self_activated" => Map.get(extra, :self_activated)
      }
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp action(:uploaded), do: "document.official_form_template_uploaded"
  defp action(:activated), do: "document.official_form_template_activated"
  defp action(:retired), do: "document.official_form_template_retired"
  defp action(:rolled_back), do: "document.official_form_template_rolled_back"

  # -- input --------------------------------------------------------------------------------

  defp validate_form(form) when is_binary(form) do
    if form in FormPrint.forms(), do: :ok, else: {:error, {:unprocessable, :unknown_form}}
  end

  defp validate_form(_), do: {:error, {:unprocessable, :unknown_form}}

  defp validate_locale(locale) when locale in @locales, do: :ok
  defp validate_locale(_), do: {:error, {:unprocessable, :invalid_locale}}

  defp validate_bytes(bytes) when is_binary(bytes), do: :ok
  defp validate_bytes(_), do: {:error, {:unprocessable, :invalid_bytes}}

  defp validate_reason(attrs) when is_map(attrs) do
    code = Map.get(attrs, :reason_code)

    if is_binary(code) and Regex.match?(@reason_code_re, code),
      do: {:ok, code},
      else: {:error, {:unprocessable, :invalid_reason_code}}
  end

  defp validate_reason(_), do: {:error, {:unprocessable, :invalid_reason_code}}

  defp validate_actor(actor) when is_binary(actor) do
    case Ecto.UUID.cast(actor) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:unprocessable, :invalid_actor}}
    end
  end

  defp validate_actor(_), do: {:error, {:unprocessable, :invalid_actor}}

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast_id(_), do: {:error, :not_found}
end
