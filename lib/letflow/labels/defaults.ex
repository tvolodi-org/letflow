defmodule Letflow.Labels.Defaults do
  @moduledoc """
  The platform default label texts (REQ-551, GH #3180), read at compile time from
  `priv/labels/entities_defaults.json` (`%{locale => %{message_id => text}}` for `en`, `ru`,
  `kk`). The key set of that file is the allowlist of overridable ids: an id missing from it
  cannot be overridden. A web drift test keeps the file equal to the SPA's catalog.

  `login.*` ids are never in the file; `overridable?/1` additionally refuses the prefixes
  `login.`, `security.` and `auth.` as a defensive second line.
  """

  @path Path.expand("../../../priv/labels/entities_defaults.json", __DIR__)
  @external_resource @path
  @messages @path |> File.read!() |> Jason.decode!()

  @locales ["en", "ru", "kk"]
  @refused_prefixes ["login.", "security.", "auth."]

  @type messages :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}

  @doc "The platform locales that have a default catalog."
  @spec locales() :: [String.t()]
  def locales, do: @locales

  @doc "The whole default catalog, `%{locale => %{id => text}}`."
  @spec all() :: messages()
  def all, do: @messages

  @doc "The default texts of one locale (`%{}` for a locale without a catalog)."
  @spec messages(String.t()) :: %{optional(String.t()) => String.t()}
  def messages(locale), do: Map.get(@messages, locale, %{})

  @doc "Every overridable message id (the key set of the `en` catalog), sorted."
  @spec ids() :: [String.t()]
  def ids,
    do: @messages |> messages_en() |> Map.keys() |> Enum.filter(&overridable?/1) |> Enum.sort()

  @doc "True when `id` may be overridden: in the default file and not under a refused prefix."
  @spec overridable?(term()) :: boolean()
  def overridable?(id) when is_binary(id) do
    not Enum.any?(@refused_prefixes, &String.starts_with?(id, &1)) and
      Map.has_key?(messages_en(@messages), id)
  end

  def overridable?(_id), do: false

  @doc """
  The `{name}` placeholder names in the default text of `id` for `locale`, looked up in
  `defaults_map` (pass `all/0`, or a fixture map in a test).
  """
  @spec placeholders(messages(), String.t(), String.t()) :: MapSet.t(String.t())
  def placeholders(defaults_map, id, locale) do
    text = defaults_map |> Map.get(locale, %{}) |> Map.get(id, "")

    placeholder_regex()
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> MapSet.new()
  end

  @doc "The regex of the one accepted placeholder form, `{name}`."
  @spec placeholder_regex() :: Regex.t()
  def placeholder_regex, do: ~r/\{([a-zA-Z0-9_]+)\}/

  defp messages_en(messages), do: Map.get(messages, "en", %{})
end
