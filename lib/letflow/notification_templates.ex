defmodule Letflow.NotificationTemplates do
  @moduledoc """
  Tenant notification templates (REQ-563, GH #3199): a tenant admin stores the subject and body
  of a registered template key for one locale, with `{name}` placeholders from the key's
  allow-list (`Letflow.NotificationTemplates.Registry`), and previews the rendering with sample
  values. Nothing is sent here: this is stored, validated, renderable data only.

  A plain transactional context, no process per tenant (the same shape as `Letflow.Labels`):
  Postgres arbitrates concurrent writers through the unique index on `(template_key, locale)` and
  an upsert. Every `Repo` call passes the tenant `prefix` (INV-1, INV-6); the tenant comes from
  the caller's auth context, never from request input.

  Secrets (INV-4): a placeholder is an allow-listed display name, never a secret. A text that
  contains a `sec://` reference, or any brace form outside the allow-list (`{password}`,
  `{tenant_id}`, plural/select markup), is refused on write. `render/3` is pure: it reads no
  `Letflow.Secrets`, no application config and no environment, and it substitutes in one pass,
  so a sample value that itself looks like a placeholder is output literally.

  Text rules: trimmed; subject 1..200 codepoints with no control character; body 1..5000
  codepoints with no control character other than newline (CR is refused).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.NotificationTemplates.Registry
  alias Letflow.NotificationTemplates.Template
  alias Letflow.Repo

  @max_subject 200
  @max_body 5000
  @max_value 500

  # The tenant locale pattern of `Letflow.Identity.Tenant` (`@locale_regex`, not exported).
  @locale_regex ~r/^[a-z]{2,3}(-[A-Z]{2})?\z/
  @placeholder_regex ~r/\{([a-z_]+)\}/

  @type text_reason ::
          :empty | :too_long | :control_character | :secret_reference | :placeholder | :markup

  @type error ::
          :not_found
          | :invalid_locale
          | {:invalid_subject, text_reason()}
          | {:invalid_body, text_reason()}
          | {:invalid_values, :not_object | :bad_value}

  @doc "Every stored template of the tenant, ordered by key and locale."
  @spec list(String.t(), String.t()) :: [Template.t()]
  def list(prefix, tenant_id) do
    from(t in Template,
      where: t.tenant_id == ^tenant_id,
      order_by: [asc: t.template_key, asc: t.locale]
    )
    |> Repo.all(prefix: prefix)
  end

  @doc """
  Creates or replaces the template of `(key, locale)`. Returns `:created` for a new pair and
  `:replaced` for an existing one. Order of refusals: key, locale, subject, body.
  """
  @spec put(String.t(), String.t(), String.t() | nil, term(), term(), term(), term()) ::
          {:ok, :created | :replaced, Template.t()} | {:error, error() | term()}
  def put(prefix, tenant_id, actor_id, key, locale, subject, body) do
    with {:ok, _entry} <- check_key(key),
         :ok <- check_locale(locale),
         {:ok, subject} <- validate_subject(key, subject),
         {:ok, body} <- validate_body(key, body) do
      now = DateTime.utc_now()

      row = %Template{
        tenant_id: tenant_id,
        template_key: key,
        locale: locale,
        subject: subject,
        body: body,
        updated_by: actor_id,
        inserted_at: now,
        updated_at: now
      }

      multi =
        Multi.new()
        |> Multi.run(:existing, fn _repo, _changes ->
          existing =
            from(t in Template,
              where: t.template_key == ^key and t.locale == ^locale,
              lock: "FOR UPDATE",
              select: t.id
            )
            |> Repo.one(prefix: prefix)

          {:ok, existing}
        end)
        |> Multi.insert(:template, row,
          prefix: prefix,
          on_conflict: {:replace, [:subject, :body, :updated_by, :updated_at]},
          conflict_target: [:template_key, :locale]
        )
        |> Audit.append_multi(
          :audit,
          %{
            actor_id: actor_id,
            action: "notification_templates.put",
            resource_type: "notification_template",
            resource_id: "#{key}:#{locale}",
            before_state: nil,
            after_state: %{"template_key" => key, "locale" => locale}
          },
          prefix
        )

      case Repo.transaction(multi) do
        {:ok, %{existing: existing, template: template}} ->
          {:ok, if(existing, do: :replaced, else: :created), template}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc "Removes one template: `{:ok, :deleted}`, or `{:error, :not_found}` for an unknown key or a missing row."
  @spec delete(String.t(), String.t() | nil, term(), term()) ::
          {:ok, :deleted} | {:error, :not_found | :invalid_locale | term()}
  def delete(prefix, actor_id, key, locale) do
    with {:ok, _entry} <- check_key(key),
         :ok <- check_locale(locale) do
      multi =
        Multi.new()
        |> Multi.run(:template, fn _repo, _changes ->
          query =
            from(t in Template, where: t.template_key == ^key and t.locale == ^locale)

          {count, _} = Repo.delete_all(query, prefix: prefix)
          if count > 0, do: {:ok, count}, else: {:error, :not_found}
        end)
        |> Audit.append_multi(
          :audit,
          %{
            actor_id: actor_id,
            action: "notification_templates.delete",
            resource_type: "notification_template",
            resource_id: "#{key}:#{locale}",
            before_state: %{"template_key" => key, "locale" => locale},
            after_state: nil
          },
          prefix
        )

      case Repo.transaction(multi) do
        {:ok, _} -> {:ok, :deleted}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  Renders a template with sample `values` (string-keyed map). Each of `subject_in` and `body_in`
  comes from the request when given (validated like `put/7`, so a preview cannot render text a
  PUT would refuse), else from the stored row of `locale`, else from the platform default.
  `source` is `:request` when any text came from the request, else `:stored` when a stored row
  supplied it, else `:default`. Writes nothing.
  """
  @spec preview(String.t(), term(), term(), term(), term(), term()) ::
          {:ok, %{subject: String.t(), body: String.t(), source: :request | :stored | :default}}
          | {:error, error() | term()}
  def preview(prefix, key, locale, subject_in, body_in, values) do
    with {:ok, _entry} <- check_key(key),
         :ok <- check_locale(locale),
         {:ok, subject_req} <- optional(subject_in, &validate_subject(key, &1)),
         {:ok, body_req} <- optional(body_in, &validate_body(key, &1)),
         {:ok, values} <- check_values(key, values) do
      stored =
        if is_nil(subject_req) or is_nil(body_req) do
          from(t in Template, where: t.template_key == ^key and t.locale == ^locale)
          |> Repo.one(prefix: prefix)
        end

      subject = subject_req || (stored && stored.subject) || Registry.default(key, :subject)
      body = body_req || (stored && stored.body) || Registry.default(key, :body)

      source =
        cond do
          subject_req || body_req -> :request
          stored -> :stored
          true -> :default
        end

      {:ok,
       %{
         subject: render(key, subject, values),
         body: render(key, body, values),
         source: source
       }}
    end
  end

  @doc """
  Pure single-pass substitution of allow-listed `{name}` placeholders. A name without a value
  renders as the empty string; a name outside the allow-list is left as written. Substituted
  values are not scanned again.
  """
  @spec render(String.t(), String.t(), map()) :: String.t()
  def render(key, text, values) do
    allowed = Registry.placeholders(key)

    Regex.replace(@placeholder_regex, text, fn whole, name ->
      if name in allowed, do: Map.get(values, name, ""), else: whole
    end)
  end

  @doc "Validates and trims a subject for `key`."
  @spec validate_subject(String.t(), term()) ::
          {:ok, String.t()} | {:error, {:invalid_subject, text_reason()}}
  def validate_subject(key, text) do
    case check_text(key, text, @max_subject, ~r/\p{Cc}/u) do
      {:ok, trimmed} -> {:ok, trimmed}
      {:error, reason} -> {:error, {:invalid_subject, reason}}
    end
  end

  @doc "Validates and trims a body for `key`; newline is the only control character allowed."
  @spec validate_body(String.t(), term()) ::
          {:ok, String.t()} | {:error, {:invalid_body, text_reason()}}
  def validate_body(key, text) do
    case check_text(key, text, @max_body, ~r/[^\P{Cc}\n]/u) do
      {:ok, trimmed} -> {:ok, trimmed}
      {:error, reason} -> {:error, {:invalid_body, reason}}
    end
  end

  defp optional(nil, _fun), do: {:ok, nil}
  defp optional(value, fun), do: fun.(value)

  defp check_key(key) do
    case Registry.fetch(key) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_found}
    end
  end

  defp check_locale(locale) when is_binary(locale) do
    if Regex.match?(@locale_regex, locale), do: :ok, else: {:error, :invalid_locale}
  end

  defp check_locale(_locale), do: {:error, :invalid_locale}

  defp check_values(_key, nil), do: {:ok, %{}}

  defp check_values(key, %{} = values) do
    allowed = Registry.placeholders(key)
    picked = Map.take(values, allowed)

    if Enum.all?(picked, fn {_name, v} ->
         is_binary(v) and length(String.codepoints(v)) <= @max_value
       end) do
      {:ok, picked}
    else
      {:error, {:invalid_values, :bad_value}}
    end
  end

  defp check_values(_key, _values), do: {:error, {:invalid_values, :not_object}}

  defp check_text(key, text, max, control) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> {:error, :empty}
      length(String.codepoints(trimmed)) > max -> {:error, :too_long}
      Regex.match?(control, trimmed) -> {:error, :control_character}
      String.contains?(String.downcase(trimmed), "sec://") -> {:error, :secret_reference}
      true -> check_braces(key, trimmed)
    end
  end

  defp check_text(_key, _text, _max, _control), do: {:error, :empty}

  defp check_braces(key, text) do
    allowed = Registry.placeholders(key)

    leftover =
      Regex.replace(@placeholder_regex, text, fn whole, name ->
        if name in allowed, do: "", else: whole
      end)

    cond do
      Regex.match?(@placeholder_regex, leftover) -> {:error, :placeholder}
      String.contains?(leftover, ["{", "}"]) -> {:error, :markup}
      true -> {:ok, text}
    end
  end
end
