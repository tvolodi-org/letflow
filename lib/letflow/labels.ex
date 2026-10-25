defmodule Letflow.Labels do
  @moduledoc """
  Tenant label overrides (REQ-551, GH #3180): a tenant admin replaces the text of an overridable
  message id for one locale, and every user of the tenant reads the merged catalog (platform
  default from `Letflow.Labels.Defaults`, override on top).

  Override values are **public UI wording**: they are shown to every user of the tenant, are not
  secrets, are not routed through `Letflow.Secrets`, may appear in logs and in audit events, and
  no code path masks them.

  A plain transactional context, no process per tenant (the same shape as `Letflow.Engine`):
  Postgres arbitrates concurrent writers through the unique index on `(message_id, locale)` and
  an upsert. Every `Repo` call passes the tenant `prefix` (INV-1, INV-6); the tenant comes from
  the caller's auth context, never from request input.

  Locale rule, one rule for read and write: a tag is mapped to its primary subtag (`"ru-RU"` is
  `"ru"`) and only `en`, `ru` and `kk` are labelled locales. A write accepts a locale only if it
  is labelled AND among the tenant's configured `locales` (`["en"]` when it configures none). A
  read serves the requested locale under the same test, else the tenant `default_locale` under
  it, else `"en"`.

  Value rules (text): trimmed, 1..500 characters, no control character, and the only markup is
  the `{name}` placeholder where `name` is in the platform default of that id and locale. Any
  other brace (plural, select, unknown name, lone brace) is refused. `<` and `>` are plain text:
  the backend never interprets HTML and the SPA renders the value as text.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Labels.Defaults
  alias Letflow.Labels.Override
  alias Letflow.Repo

  @max_length 500

  @type text_reason :: :empty | :too_long | :control_character | :placeholder | :markup

  @doc "Maps a language tag to \"en\", \"ru\" or \"kk\" by its primary subtag, else `:error`."
  @spec normalize_locale(term()) :: {:ok, String.t()} | :error
  def normalize_locale(tag) when is_binary(tag) do
    primary = tag |> String.downcase() |> String.split("-") |> hd()
    if primary in Defaults.locales(), do: {:ok, primary}, else: :error
  end

  def normalize_locale(_tag), do: :error

  @doc "The labelled primary subtags of the tenant's configured `locales` (`[\"en\"]` when none)."
  @spec tenant_locales(map() | nil) :: [String.t()]
  def tenant_locales(%{"locales" => [_ | _] = configured}) do
    configured |> Enum.flat_map(&locale_list/1) |> Enum.uniq()
  end

  def tenant_locales(_settings), do: ["en"]

  defp locale_list(tag) do
    case normalize_locale(tag) do
      {:ok, locale} -> [locale]
      :error -> []
    end
  end

  @doc "The locale a read serves: requested, else the tenant default, else \"en\"."
  @spec served_locale(map() | nil, term()) :: String.t()
  def served_locale(settings, requested) do
    allowed = tenant_locales(settings)

    with :error <- usable(requested, allowed),
         :error <- usable(default_locale(settings), allowed) do
      "en"
    else
      {:ok, locale} -> locale
    end
  end

  defp usable(tag, allowed) do
    case normalize_locale(tag) do
      {:ok, locale} -> if locale in allowed, do: {:ok, locale}, else: :error
      :error -> :error
    end
  end

  defp default_locale(%{"default_locale" => tag}), do: tag
  defp default_locale(_settings), do: nil

  @doc """
  The merged catalog for the tenant: the default texts of the served locale with the tenant's
  overrides on top. An override whose id left the default file is ignored.
  """
  @spec catalog(String.t(), String.t(), map() | nil, term()) :: %{
          locale: String.t(),
          messages: %{optional(String.t()) => String.t()}
        }
  def catalog(prefix, tenant_id, settings, requested) do
    locale = served_locale(settings, requested)
    defaults = locale |> Defaults.messages() |> Map.take(Defaults.ids())

    overrides =
      from(o in Override,
        where: o.locale == ^locale and o.tenant_id == ^tenant_id,
        select: {o.message_id, o.text}
      )
      |> Repo.all(prefix: prefix)
      |> Enum.filter(fn {id, _text} -> Map.has_key?(defaults, id) end)
      |> Map.new()

    %{locale: locale, messages: Map.merge(defaults, overrides)}
  end

  @doc """
  Creates or replaces one override. `opts[:defaults]` replaces the default catalog used for the
  placeholder check (a test fixture; production uses the file).
  """
  @spec put_override(
          String.t(),
          String.t(),
          map() | nil,
          String.t() | nil,
          term(),
          term(),
          term(),
          keyword()
        ) ::
          {:ok, %{message_id: String.t(), locale: String.t(), text: String.t()}}
          | {:error, :invalid_id | :invalid_locale | {:invalid_text, text_reason()} | term()}
  def put_override(prefix, tenant_id, settings, actor_id, message_id, locale, text, opts \\ []) do
    defaults = Keyword.get(opts, :defaults, Defaults.all())

    with :ok <- check_id(message_id),
         {:ok, locale} <- check_locale(settings, locale),
         {:ok, text} <- check_text(defaults, message_id, locale, text) do
      now = DateTime.utc_now()

      row = %Override{
        tenant_id: tenant_id,
        message_id: message_id,
        locale: locale,
        text: text,
        updated_by: actor_id,
        inserted_at: now,
        updated_at: now
      }

      multi =
        Multi.new()
        |> Multi.insert(:override, row,
          prefix: prefix,
          on_conflict: {:replace, [:text, :updated_by, :updated_at]},
          conflict_target: [:message_id, :locale]
        )
        |> Audit.append_multi(
          :audit,
          %{
            actor_id: actor_id,
            action: "labels.override_set",
            resource_type: "label_override",
            resource_id: "#{message_id}:#{locale}",
            before_state: nil,
            after_state: %{"message_id" => message_id, "locale" => locale, "text" => text}
          },
          prefix
        )

      case Repo.transaction(multi) do
        {:ok, _} -> {:ok, %{message_id: message_id, locale: locale, text: text}}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc "Removes one override: `{:ok, :deleted}`, or `{:error, :not_found}` when none exists."
  @spec delete_override(String.t(), map() | nil, String.t() | nil, term(), term()) ::
          {:ok, :deleted} | {:error, :invalid_id | :invalid_locale | :not_found | term()}
  def delete_override(prefix, settings, actor_id, message_id, locale) do
    with :ok <- check_id(message_id),
         {:ok, locale} <- check_locale(settings, locale) do
      multi =
        Multi.new()
        |> Multi.run(:override, fn _repo, _changes ->
          query = from(o in Override, where: o.message_id == ^message_id and o.locale == ^locale)
          {count, _} = Repo.delete_all(query, prefix: prefix)
          if count > 0, do: {:ok, count}, else: {:error, :not_found}
        end)
        |> Audit.append_multi(
          :audit,
          %{
            actor_id: actor_id,
            action: "labels.override_delete",
            resource_type: "label_override",
            resource_id: "#{message_id}:#{locale}",
            before_state: %{"message_id" => message_id, "locale" => locale},
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

  defp check_id(id), do: if(Defaults.overridable?(id), do: :ok, else: {:error, :invalid_id})

  defp check_locale(settings, tag) do
    with {:ok, locale} <- normalize_locale(tag),
         true <- locale in tenant_locales(settings) do
      {:ok, locale}
    else
      _ -> {:error, :invalid_locale}
    end
  end

  defp check_text(defaults, id, locale, text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> {:error, {:invalid_text, :empty}}
      length(String.codepoints(trimmed)) > @max_length -> {:error, {:invalid_text, :too_long}}
      Regex.match?(~r/[\p{Cc}]/u, trimmed) -> {:error, {:invalid_text, :control_character}}
      true -> check_braces(defaults, id, locale, trimmed)
    end
  end

  defp check_text(_defaults, _id, _locale, _text), do: {:error, {:invalid_text, :empty}}

  defp check_braces(defaults, id, locale, text) do
    allowed = Defaults.placeholders(defaults, id, locale)

    leftover =
      Regex.replace(Defaults.placeholder_regex(), text, fn whole, name ->
        if MapSet.member?(allowed, name), do: "", else: whole
      end)

    cond do
      Regex.match?(Defaults.placeholder_regex(), leftover) ->
        {:error, {:invalid_text, :placeholder}}

      String.contains?(leftover, ["{", "}"]) ->
        {:error, {:invalid_text, :markup}}

      true ->
        {:ok, text}
    end
  end
end
